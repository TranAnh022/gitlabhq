# frozen_string_literal: true

module Backup
  class Manager
    ARCHIVES_TO_BACKUP = %w[uploads builds artifacts pages lfs terraform_state registry].freeze
    FOLDERS_TO_BACKUP = %w[repositories db].freeze
    FILE_NAME_SUFFIX = '_gitlab_backup.tar'

    attr_reader :progress

    def initialize(progress)
      @progress = progress
    end

    def write_info
      # Make sure there is a connection
      ActiveRecord::Base.connection.reconnect!

      Dir.chdir(backup_path) do
        File.open("#{backup_path}/backup_information.yml", "w+") do |file|
          file << backup_information.to_yaml.gsub(/^---\n/, '')
        end
      end
    end

    def pack
      Dir.chdir(backup_path) do
        # create archive
        progress.print "Creating backup archive: #{tar_file} ... "
        # Set file permissions on open to prevent chmod races.
        tar_system_options = { out: [tar_file, 'w', Gitlab.config.backup.archive_permissions] }
        if Kernel.system('tar', '-cf', '-', *backup_contents, tar_system_options)
          progress.puts "done".color(:green)
        else
          puts "creating archive #{tar_file} failed".color(:red)
          raise Backup::Error, 'Backup failed'
        end
      end
    end

    def upload
      progress.print "Uploading backup archive to remote storage #{remote_directory} ... "

      connection_settings = Gitlab.config.backup.upload.connection
      if connection_settings.blank?
        progress.puts "skipped".color(:yellow)
        return
      end

      directory = connect_to_remote_directory
      upload = directory.files.create(create_attributes)

      if upload
        progress.puts "done".color(:green)
        upload
      else
        puts "uploading backup to #{remote_directory} failed".color(:red)
        raise Backup::Error, 'Backup failed'
      end
    end

    def cleanup
      progress.print "Deleting tmp directories ... "

      backup_contents.each do |dir|
        next unless File.exist?(File.join(backup_path, dir))

        if FileUtils.rm_rf(File.join(backup_path, dir))
          progress.puts "done".color(:green)
        else
          puts "deleting tmp directory '#{dir}' failed".color(:red)
          raise Backup::Error, 'Backup failed'
        end
      end
    end

    def remove_tmp
      # delete tmp inside backups
      progress.print "Deleting backups/tmp ... "

      if FileUtils.rm_rf(File.join(backup_path, "tmp"))
        progress.puts "done".color(:green)
      else
        puts "deleting backups/tmp failed".color(:red)
      end
    end

    def remove_old
      # delete backups
      progress.print "Deleting old backups ... "
      keep_time = Gitlab.config.backup.keep_time.to_i

      if keep_time > 0
        removed = 0

        Dir.chdir(backup_path) do
          backup_file_list.each do |file|
            # For backward compatibility, there are 3 names the backups can have:
            # - 1495527122_gitlab_backup.tar
            # - 1495527068_2017_05_23_gitlab_backup.tar
            # - 1495527097_2017_05_23_9.3.0-pre_gitlab_backup.tar
            matched = backup_file?(file)
            next unless matched

            timestamp = matched[1].to_i

            if Time.at(timestamp) < (Time.now - keep_time)
              begin
                FileUtils.rm(file)
                removed += 1
              rescue StandardError => e
                progress.puts "Deleting #{file} failed: #{e.message}".color(:red)
              end
            end
          end
        end

        progress.puts "done. (#{removed} removed)".color(:green)
      else
        progress.puts "skipping".color(:yellow)
      end
    end

    def verify_backup_version
      Dir.chdir(backup_path) do
        # restoring mismatching backups can lead to unexpected problems
        if settings[:gitlab_version] != Gitlab::VERSION
          progress.puts(<<~HEREDOC.color(:red))
            GitLab version mismatch:
              Your current GitLab version (#{Gitlab::VERSION}) differs from the GitLab version in the backup!
              Please switch to the following version and try again:
              version: #{settings[:gitlab_version]}
          HEREDOC
          progress.puts
          progress.puts "Hint: git checkout v#{settings[:gitlab_version]}"
          exit 1
        end
      end
    end

    def unpack
      if ENV['BACKUP'].blank? && non_tarred_backup?
        progress.puts "Non tarred backup found in #{backup_path}, using that"

        return false
      end

      Dir.chdir(backup_path) do
        # check for existing backups in the backup dir
        if backup_file_list.empty?
          progress.puts "No backups found in #{backup_path}"
          progress.puts "Please make sure that file name ends with #{FILE_NAME_SUFFIX}"
          exit 1
        elsif backup_file_list.many? && ENV["BACKUP"].nil?
          progress.puts 'Found more than one backup:'
          # print list of available backups
          progress.puts " " + available_timestamps.join("\n ")
          progress.puts 'Please specify which one you want to restore:'
          progress.puts 'rake gitlab:backup:restore BACKUP=timestamp_of_backup'
          exit 1
        end

        tar_file = if ENV['BACKUP'].present?
                     File.basename(ENV['BACKUP']) + FILE_NAME_SUFFIX
                   else
                     backup_file_list.first
                   end

        unless File.exist?(tar_file)
          progress.puts "The backup file #{tar_file} does not exist!"
          exit 1
        end

        progress.print 'Unpacking backup ... '

        if Kernel.system(*%W(tar -xf #{tar_file}))
          progress.puts 'done'.color(:green)
        else
          progress.puts 'unpacking backup failed'.color(:red)
          exit 1
        end
      end
    end

    def tar_version
      tar_version, _ = Gitlab::Popen.popen(%w(tar --version))
      tar_version.dup.force_encoding('locale').split("\n").first
    end

    def skipped?(item)
      settings[:skipped] && settings[:skipped].include?(item) || disabled_features.include?(item)
    end

    private

    def backup_file?(file)
      file.match(/^(\d{10})(?:_\d{4}_\d{2}_\d{2}(_\d+\.\d+\.\d+((-|\.)(pre|rc\d))?(-ee)?)?)?_gitlab_backup\.tar$/)
    end

    def non_tarred_backup?
      File.exist?(File.join(backup_path, 'backup_information.yml'))
    end

    def backup_path
      Gitlab.config.backup.path
    end

    def backup_file_list
      @backup_file_list ||= Dir.glob("*#{FILE_NAME_SUFFIX}")
    end

    def available_timestamps
      @backup_file_list.map {|item| item.gsub("#{FILE_NAME_SUFFIX}", "")}
    end

    def object_storage_config
      @object_storage_config ||= begin
        ObjectStorage::Config.new(Gitlab.config.backup.upload)
      end
    end

    def connect_to_remote_directory
      connection = ::Fog::Storage.new(object_storage_config.credentials)

      # We only attempt to create the directory for local backups. For AWS
      # and other cloud providers, we cannot guarantee the user will have
      # permission to create the bucket.
      if connection.service == ::Fog::Storage::Local
        connection.directories.create(key: remote_directory)
      else
        connection.directories.new(key: remote_directory)
      end
    end

    def remote_directory
      Gitlab.config.backup.upload.remote_directory
    end

    def remote_target
      if ENV['DIRECTORY']
        File.join(ENV['DIRECTORY'], tar_file)
      else
        tar_file
      end
    end

    def backup_contents
      folders_to_backup + archives_to_backup + ["backup_information.yml"]
    end

    def archives_to_backup
      ARCHIVES_TO_BACKUP.map { |name| (name + ".tar.gz") unless skipped?(name) }.compact
    end

    def folders_to_backup
      FOLDERS_TO_BACKUP.select { |name| !skipped?(name) && Dir.exist?(File.join(backup_path, name)) }
    end

    def disabled_features
      features = []
      features << 'registry' unless Gitlab.config.registry.enabled
      features
    end

    def settings
      @settings ||= YAML.load_file("backup_information.yml")
    end

    def tar_file
      @tar_file ||= if ENV['BACKUP'].present?
                      File.basename(ENV['BACKUP']) + FILE_NAME_SUFFIX
                    else
                      "#{backup_information[:backup_created_at].strftime('%s_%Y_%m_%d_')}#{backup_information[:gitlab_version]}#{FILE_NAME_SUFFIX}"
                    end
    end

    def backup_information
      @backup_information ||= {
        db_version: ActiveRecord::Migrator.current_version.to_s,
        backup_created_at: Time.now,
        gitlab_version: Gitlab::VERSION,
        tar_version: tar_version,
        installation_type: Gitlab::INSTALLATION_TYPE,
        skipped: ENV["SKIP"]
      }
    end

    def create_attributes
      attrs = {
        key: remote_target,
        body: File.open(File.join(backup_path, tar_file)),
        multipart_chunk_size: Gitlab.config.backup.upload.multipart_chunk_size,
        storage_class: Gitlab.config.backup.upload.storage_class
      }.merge(encryption_attributes)

      # Google bucket-only policies prevent setting an ACL. In any case, by default,
      # all objects are set to the default ACL, which is project-private:
      # https://cloud.google.com/storage/docs/json_api/v1/defaultObjectAccessControls
      attrs[:public] = false unless google_provider?

      attrs
    end

    def encryption_attributes
      return object_storage_config.fog_attributes if object_storage_config.aws_server_side_encryption_enabled?

      # Use customer-managed keys. Also, this preserves
      # backward-compatibility for existing usages of `SSE-S3` that
      # don't set `backup.upload.storage_options.server_side_encryption`
      # to `'AES256'`.
      {
        encryption_key: Gitlab.config.backup.upload.encryption_key,
        encryption: Gitlab.config.backup.upload.encryption
      }
    end

    def google_provider?
      Gitlab.config.backup.upload.connection&.provider&.downcase == 'google'
    end
  end
end

Backup::Manager.prepend_mod
