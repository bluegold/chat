# frozen_string_literal: true

require 'open3'
require 'timeout'
require 'yaml'
require 'ruby_llm'

module ChatApp
  module CodeExecutionTools
    DEFAULT_TIMEOUT_SECONDS = 30

    def self.register(klass)
      registered_tools[klass.tool_name] = klass
      klass
    end

    def self.tool_class(name)
      registered_tools[name.to_s]
    end

    def self.registered_tools
      @registered_tools ||= {}
    end

    def self.executor
      @executor ||= SandboxExecutor.new
    end

    def self.executor=(value)
      @executor = value
    end

    class ExecutionResult
      attr_reader :stdout, :stderr, :exit_status, :timed_out, :command

      def initialize(stdout:, stderr:, exit_status:, timed_out:, command:)
        @stdout = stdout.to_s
        @stderr = stderr.to_s
        @exit_status = exit_status
        @timed_out = timed_out
        @command = Array(command).map(&:to_s)
      end
    end

    class SandboxExecutor
      def run(language:, code:, root:, timeout_seconds:)
        root = expand_root(root)
        command = sandbox_command(language:, root:)
        timeout_seconds = normalized_timeout_seconds(timeout_seconds)
        stdout, stderr, exit_status, timed_out = run_command(command, code.to_s, timeout_seconds)
        ExecutionResult.new(
          stdout: stdout,
          stderr: stderr,
          exit_status: exit_status,
          timed_out: timed_out,
          command: command
        )
      end

      def sandbox_command(language:, root:)
        interpreter, interpreter_args = interpreter_for(language)

        [
          'bwrap',
          '--unshare-all',
          '--unshare-net',
          '--die-with-parent',
          '--clearenv',
          '--ro-bind', '/', '/',
          '--tmpfs', '/tmp',
          '--dir', '/tmp/work',
          '--ro-bind', root, '/tmp/work',
          '--dev', '/dev',
          '--proc', '/proc',
          '--setenv', 'HOME', '/tmp',
          '--setenv', 'TMPDIR', '/tmp',
          '--setenv', 'PATH', '/usr/bin:/bin',
          '--setenv', 'RUBYLIB', '/tmp/work:/tmp/work/lib',
          '--setenv', 'PYTHONPATH', '/tmp/work:/tmp/work/lib',
          '--chdir', '/tmp/work',
          *interpreter,
          *interpreter_args
        ]
      end

      private

      def normalized_timeout_seconds(timeout_seconds)
        timeout = timeout_seconds.to_i
        timeout.positive? ? timeout : DEFAULT_TIMEOUT_SECONDS
      end

      def expand_root(root)
        base = root.to_s.strip.empty? ? Dir.pwd : File.expand_path(root.to_s, Dir.pwd)
        raise ArgumentError, "root does not exist: #{base}" unless Dir.exist?(base)

        base
      end

      def interpreter_for(language)
        case language.to_s
        when 'ruby'
          ['ruby', ['-I', '/tmp/work', '-I', '/tmp/work/lib', '-']]
        when 'python'
          ['python3', ['-']]
        else
          raise ArgumentError, "unsupported language: #{language}"
        end
      end

      def run_command(command, input, timeout_seconds)
        stdout = +''
        stderr = +''
        exit_status = nil
        timed_out = false

        Open3.popen3(*command, pgroup: true) do |stdin, stdout_io, stderr_io, wait_thr|
          stdin.write(input)
          stdin.close

          stdout_thread = Thread.new { stdout_io.read.to_s }
          stderr_thread = Thread.new { stderr_io.read.to_s }

          begin
            Timeout.timeout(timeout_seconds) do
              exit_status = wait_thr.value.exitstatus
            end
          rescue Timeout::Error
            timed_out = true
            terminate_process_group(wait_thr.pid)
            begin
              exit_status = wait_thr.value.exitstatus
            rescue StandardError
              exit_status = nil
            end
          ensure
            stdout = stdout_thread.value
            stderr = stderr_thread.value
          end
        end

        [stdout, stderr, exit_status, timed_out]
      rescue Errno::ENOENT => e
        ['', e.message, nil, false]
      end

      def terminate_process_group(pid)
        return unless pid

        Process.kill('TERM', -pid)
        sleep 0.2
        Process.kill('KILL', -pid)
      rescue StandardError
        nil
      end
    end

    class BaseTool < RubyLLM::Tool
      class << self
        def tool_name(value = nil)
          if value.nil?
            @tool_name
          else
            @tool_name = value.to_s
          end
        end

        def executor
          CodeExecutionTools.executor
        end

        def executor=(value)
          CodeExecutionTools.executor = value
        end
      end

      def name
        self.class.tool_name || super
      end

      protected

      def execute_sandbox(language:, code:, root:, timeout_seconds:)
        result = self.class.executor.run(
          language: language,
          code: code,
          root: root,
          timeout_seconds: timeout_seconds
        )
        format_execution_result(language:, root:, timeout_seconds:, result:)
      rescue StandardError => e
        "Error executing #{language}: #{e.class}: #{e.message}"
      end

      def format_execution_result(language:, root:, timeout_seconds:, result:)
        YAML.dump(
          {
            'language' => language.to_s,
            'root' => root.to_s,
            'timeout_seconds' => timeout_seconds.to_i,
            'timed_out' => result.timed_out,
            'exit_status' => result.exit_status,
            'stdout' => result.stdout.to_s,
            'stderr' => result.stderr.to_s,
            'command' => result.command
          }
        )
      end
    end

    class RunRubyTool < BaseTool
      tool_name 'run_ruby'
      description 'Run Ruby code in a sandboxed bwrap environment.'
      param :code, desc: 'Ruby code to execute.'
      param :root, required: false, desc: 'Read-only project root.'
      param :timeout_seconds, type: 'integer', required: false, desc: 'Execution timeout in seconds.'

      def execute(code:, root: '.', timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
        execute_sandbox(language: 'ruby', code: code, root: root, timeout_seconds: timeout_seconds)
      end
    end

    class RunPythonTool < BaseTool
      tool_name 'run_python'
      description 'Run Python code in a sandboxed bwrap environment.'
      param :code, desc: 'Python code to execute.'
      param :root, required: false, desc: 'Read-only project root.'
      param :timeout_seconds, type: 'integer', required: false, desc: 'Execution timeout in seconds.'

      def execute(code:, root: '.', timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
        execute_sandbox(language: 'python', code: code, root: root, timeout_seconds: timeout_seconds)
      end
    end

    register RunRubyTool
    register RunPythonTool
  end
end
