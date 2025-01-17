# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Projects::RawController do
  include RepoHelpers

  let_it_be(:project) { create(:project, :public, :repository) }

  let(:inline) { nil }
  let(:params) { {} }

  describe 'GET #show' do
    def get_show
      get(:show,
          params: {
            namespace_id: project.namespace,
            project_id: project,
            id: file_path,
            inline: inline
          }.merge(params))
    end

    subject { get_show }

    shared_examples 'single Gitaly request' do
      it 'makes a single Gitaly request', :request_store, :clean_gitlab_redis_cache do
        # Warm up to populate repository cache
        get_show
        RequestStore.clear!

        expect { get_show }.to change { Gitlab::GitalyClient.get_request_count }.by(1)
      end
    end

    context 'regular filename' do
      let(:file_path) { 'master/CONTRIBUTING.md' }

      it 'delivers ASCII file' do
        allow(Gitlab::Workhorse).to receive(:send_git_blob).and_call_original

        subject

        expect(response).to have_gitlab_http_status(:ok)
        expect(response.header['Content-Type']).to eq('text/plain; charset=utf-8')
        expect(response.header[Gitlab::Workhorse::DETECT_HEADER]).to eq 'true'
        expect(response.header[Gitlab::Workhorse::SEND_DATA_HEADER]).to start_with('git-blob:')

        expect(Gitlab::Workhorse).to have_received(:send_git_blob) do |repository, blob|
          expected_blob = project.repository.blob_at('master', 'CONTRIBUTING.md')

          expect(repository).to eq(project.repository)
          expect(blob.id).to eq(expected_blob.id)
          expect(blob).to be_truncated
        end
      end

      it_behaves_like 'project cache control headers'
      it_behaves_like 'content disposition headers'
      include_examples 'single Gitaly request'
    end

    context 'image header' do
      let(:file_path) { 'master/files/images/6049019_460s.jpg' }

      it 'leaves image content disposition' do
        subject

        expect(response).to have_gitlab_http_status(:ok)
        expect(response.header[Gitlab::Workhorse::DETECT_HEADER]).to eq "true"
        expect(response.header[Gitlab::Workhorse::SEND_DATA_HEADER]).to start_with('git-blob:')
      end

      it_behaves_like 'project cache control headers'
      it_behaves_like 'content disposition headers'
      include_examples 'single Gitaly request'
    end

    context 'with LFS files' do
      let(:filename) { 'lfs_object.iso' }
      let(:file_path) { "be93687/files/lfs/#{filename}" }

      it_behaves_like 'a controller that can serve LFS files'
      it_behaves_like 'project cache control headers'
      include_examples 'single Gitaly request'
    end

    context 'when the endpoint receives requests above the limit' do
      let(:file_path) { 'master/README.md' }
      let(:path_without_ref) { 'README.md' }

      before do
        allow(::Gitlab::ApplicationRateLimiter).to(
          receive(:throttled?).with(:raw_blob, scope: [project, path_without_ref]).and_return(true)
        )
      end

      it 'prevents from accessing the raw file' do
        expect { get_show }.not_to change { Gitlab::GitalyClient.get_request_count }

        expect(response.body).to eq(_('You cannot access the raw file. Please wait a minute.'))
        expect(response).to have_gitlab_http_status(:too_many_requests)
      end

      context 'when receiving an external storage request' do
        let(:token) { 'letmein' }

        before do
          stub_application_setting(
            static_objects_external_storage_url: 'https://cdn.gitlab.com',
            static_objects_external_storage_auth_token: token
          )
        end

        it 'does not prevent from accessing the raw file' do
          expect(::Gitlab::ApplicationRateLimiter).not_to receive(:throttled?)

          request.headers['X-Gitlab-External-Storage-Token'] = token
          get_show

          expect(response).to have_gitlab_http_status(:ok)
        end
      end
    end

    context 'as a sessionless user' do
      let_it_be(:project) { create(:project, :private, :repository) }
      let_it_be(:user) { create(:user, static_object_token: 'very-secure-token') }
      let_it_be(:file_path) { 'master/README.md' }

      before do
        project.add_developer(user)
      end

      context 'when no token is provided' do
        it 'redirects to sign in page' do
          get_show

          expect(response).to have_gitlab_http_status(:found)
          expect(response.location).to end_with('/users/sign_in')
        end
      end

      context 'when a token param is present' do
        context 'when token is correct' do
          let(:params) { { token: user.static_object_token } }

          it 'calls the action normally' do
            get_show

            expect(response).to have_gitlab_http_status(:ok)
          end
        end

        context 'when token is incorrect' do
          let(:params) { { token: 'foobar' } }

          it 'redirects to sign in page' do
            get_show

            expect(response).to have_gitlab_http_status(:found)
            expect(response.location).to end_with('/users/sign_in')
          end
        end
      end

      context 'when a token header is present' do
        context 'when token is correct' do
          it 'calls the action normally' do
            request.headers['X-Gitlab-Static-Object-Token'] = user.static_object_token
            get_show

            expect(response).to have_gitlab_http_status(:ok)
          end
        end

        context 'when token is incorrect' do
          it 'redirects to sign in page' do
            request.headers['X-Gitlab-Static-Object-Token'] = 'foobar'
            get_show

            expect(response).to have_gitlab_http_status(:found)
            expect(response.location).to end_with('/users/sign_in')
          end
        end
      end
    end

    describe 'caching' do
      def request_file
        get(:show, params: { namespace_id: project.namespace, project_id: project, id: 'master/README.md' })
      end

      it 'sets appropriate caching headers' do
        sign_in create(:user)
        request_file

        expect(response.cache_control[:public]).to eq(true)
        expect(response.cache_control[:max_age]).to eq(60)
        expect(response.cache_control[:no_store]).to be_nil
      end

      context 'when a public project has private repo' do
        let(:project) { create(:project, :public, :repository, :repository_private) }
        let(:user) { create(:user, maintainer_projects: [project]) }

        it 'does not set public caching header' do
          sign_in user
          request_file

          expect(response.header['Cache-Control']).to include('max-age=60, private')
        end
      end

      context 'when If-None-Match header is set' do
        it 'returns a 304 status' do
          request_file

          request.headers['If-None-Match'] = response.headers['ETag']
          request_file

          expect(response).to have_gitlab_http_status(:not_modified)
        end
      end
    end
  end
end
