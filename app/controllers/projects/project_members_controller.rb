class Projects::ProjectMembersController < Projects::ApplicationController
  include MembershipActions

  # Authorize
  before_action :authorize_admin_project_member!, except: [:index, :leave, :request_access]

  def index
    @groups = @project.project_group_links
    @project_members = @project.team.members(!can?(current_user, :admin_project, @project))
    @project_members_size = @project_members.size

    if params[:search].present?
      @project_members = @project_members.search(params[:search])
    end

    @project_members = @project_members.page(params[:page])

    @requesters = @project.requesters if can?(current_user, :admin_project, @project)

    @project_member = @project.project_members.new
  end

  def create
    @project.team.add_users(
      params[:user_ids].split(','),
      params[:access_level],
      expires_at: params[:expires_at],
      current_user: current_user
    )

    redirect_to namespace_project_project_members_path(@project.namespace, @project)
  end

  def update
    @project_member = @project.project_members.find(params[:id])

    return render_403 unless can?(current_user, :update_project_member, @project_member)

    @project_member.update_attributes(member_params)
  end

  def destroy
    @project_member = @project.members.find_by(id: params[:id]) ||
      @project.requesters.find_by(id: params[:id])

    Members::DestroyService.new(@project_member, current_user).execute

    respond_to do |format|
      format.html do
        redirect_to namespace_project_project_members_path(@project.namespace, @project)
      end
      format.js { head :ok }
    end
  end

  def resend_invite
    redirect_path = namespace_project_project_members_path(@project.namespace, @project)

    @project_member = @project.project_members.find(params[:id])

    if @project_member.invite?
      @project_member.resend_invite

      redirect_to redirect_path, notice: 'The invitation was successfully resent.'
    else
      redirect_to redirect_path, alert: 'The invitation has already been accepted.'
    end
  end

  def apply_import
    source_project = Project.find(params[:source_project_id])

    if can?(current_user, :read_project_member, source_project)
      status = @project.team.import(source_project, current_user)
      notice = status ? "Successfully imported" : "Import failed"
    else
      return render_404
    end

    redirect_to(namespace_project_project_members_path(project.namespace, project),
                notice: notice)
  end

  protected

  def member_params
    params.require(:project_member).permit(:user_id, :access_level, :expires_at)
  end

  # MembershipActions concern
  alias_method :membershipable, :project
end
