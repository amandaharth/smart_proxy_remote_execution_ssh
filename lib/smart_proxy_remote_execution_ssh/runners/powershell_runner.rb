module Proxy::RemoteExecution::Ssh::Runners
  class PowershellRunner < ScriptRunner

    def initialize(options, user_method, suspended_action: nil)
      super(options, user_method, suspended_action: suspended_action)
      @host = options.fetch(:hostname)
      @script = options.fetch(:script)
      @ssh_user = options.fetch(:ssh_user, 'administrator')
      @ssh_port = options.fetch(:ssh_port, 22)
      @host_public_key = options.fetch(:host_public_key, nil)
      @execution_timeout_interval = options.fetch(:execution_timeout_interval, nil)

      @client_private_key_file = settings.ssh_identity_key_file
      @local_working_dir = options.fetch(:local_working_dir, settings.local_working_dir)
      @remote_working_dir = options.fetch(:remote_working_dir, settings.remote_working_dir.shellescape)
      @socket_working_dir = options.fetch(:socket_working_dir, settings.socket_working_dir)
      @cleanup_working_dirs = options.fetch(:cleanup_working_dirs, settings.cleanup_working_dirs)
      @first_execution = options.fetch(:first_execution, false)
      @user_method = user_method
      @options = options
    end

    def preflight_checks
      script = cp_script_to_remote("echo true")
      ensure_remote_command(script,
        error: 'Failed to execute script on remote machine, exit code: %{exit_code}.'
      )
      # The path should already be escaped
      ensure_remote_command("rm #{script}.ps1")
    end

    def prepare_start
      @remote_script = cp_script_to_remote
      @output_path = File.join(File.dirname(@remote_script), 'output')
      @exit_code_path = File.join(File.dirname(@remote_script), 'exit_code')
      @pid_path = File.join(File.dirname(@remote_script), 'pid')
      su_method = @user_method.instance_of?(SuUserMethod)
      wrapper = <<~SCRIPT 
        powershell.exe #{@remote_script} 2>&1 | Tee-Object -Filepath #{@output_path}
        $exit_code = if ($? -eq $True) { 0 } else { 1 }
          
        echo $exit_code > #{@exit_code_path}
        exit $exit_code
      SCRIPT
      @remote_script_wrapper = upload_data(
        wrapper,
        File.join(File.dirname(@remote_script), 'script-wrapper'),
        555)
    end


    # Initiates run of the remote command and yields the data when
    # available. The yielding doesn't happen automatically, but as
    # part of calling the `refresh` method.
    def run_async(command)
      raise 'Async command already in progress' if @process_manager&.started?

      @user_method.reset
      cmd = @connection.command([tty_flag(false), command].flatten.compact)
      log_command(cmd)
      initialize_command(*cmd)

      true
    end

    def upload_data(data, path, permissions = 555)
      ensure_remote_directory File.dirname(path)
      # We use tee here to pipe stdin coming from ssh to a file at $path, while silencing its output
      # This is used to write to $path with elevated permissions, solutions using cat and output redirection
      # would not work, because the redirection would happen in the non-elevated shell.
      command = "$lines = @(); while (($line = read-host) -and $line -cnotmatch 'END_REMOTE_EXECUTION_SCRIPT') { $lines += $line}; $lines | Out-File -FilePath #{path}.ps1"

      @logger.debug("Sending data to #{path} on remote host:\n#{data}")
      ensure_remote_command(command,
        stdin: data << "\nEND_REMOTE_EXECUTION_SCRIPT",
        error: "Unable to upload file to #{path} on remote system, exit code: %{exit_code}"
      )

      path
    end

    def ensure_remote_directory(path)
      ensure_remote_command("New-Item -ItemType Directory -Path #{path} -Force",
        error: "Unable to create directory #{path} on remote system, exit code: %{exit_code}"
      )
    end

  end
end
