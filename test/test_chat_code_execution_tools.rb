# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'

require_relative '../lib/backend/chat_backend'
require_relative '../lib/tools/chat_code_execution_tools'

class ChatBackendCodeExecutionToolsTest < Minitest::Test
  def test_code_execution_tools_expose_multiple_features
    assert ChatApp::CodeExecutionTools::RunRubyTool.supports_feature?(:runtime)
    assert ChatApp::CodeExecutionTools::RunRubyTool.supports_feature?(:code_execution)
  end

  def test_code_execution_tools_distinguish_languages
    assert ChatApp::CodeExecutionTools::RunRubyTool.supports_feature?(:ruby)
    refute ChatApp::CodeExecutionTools::RunRubyTool.supports_feature?(:python)
  end

  def test_code_execution_tools_can_be_filtered_by_feature
    tool_names = ChatApp::CodeExecutionTools.tool_classes_for_feature(:runtime).map(&:tool_name)

    assert_equal %w[run_python run_ruby], tool_names.sort
  end

  class FakeExecutor
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def run(language:, code:, root:, timeout_seconds:)
      @calls << {
        language: language,
        code: code,
        root: root,
        timeout_seconds: timeout_seconds
      }
      @result
    end
  end

  def with_executor(result)
    previous = ChatApp::CodeExecutionTools.executor
    fake = FakeExecutor.new(result)
    ChatApp::CodeExecutionTools.executor = fake
    yield fake
  ensure
    ChatApp::CodeExecutionTools.executor = previous
  end

  def test_ruby_tool_formats_metadata_as_yaml
    result = ChatApp::CodeExecutionTools::ExecutionResult.new(
      stdout: "3\n",
      stderr: '',
      exit_status: 0,
      timed_out: false,
      command: %w[bwrap ruby -]
    )

    with_executor(result) do |fake|
      output = ChatApp::CodeExecutionTools::RunRubyTool.new.call(
        code: 'puts 1 + 2',
        root: '.',
        timeout_seconds: 30
      )
      data = YAML.safe_load(output, permitted_classes: [], aliases: false)

      assert_equal(
        {
          'language' => 'ruby',
          'timeout_seconds' => 30,
          'timed_out' => false,
          'command' => %w[bwrap ruby -]
        },
        data.slice('language', 'timeout_seconds', 'timed_out', 'command')
      )
      assert_equal(
        {
          language: 'ruby',
          code: 'puts 1 + 2',
          root: '.',
          timeout_seconds: 30
        },
        fake.calls.first
      )
    end
  end

  def test_ruby_tool_preserves_stdout_and_stderr
    result = ChatApp::CodeExecutionTools::ExecutionResult.new(
      stdout: "3\n",
      stderr: '',
      exit_status: 0,
      timed_out: false,
      command: %w[bwrap ruby -]
    )

    with_executor(result) do
      output = ChatApp::CodeExecutionTools::RunRubyTool.new.call(
        code: 'puts 1 + 2',
        root: '.',
        timeout_seconds: 30
      )
      data = YAML.safe_load(output, permitted_classes: [], aliases: false)

      assert_equal({ 'stdout' => "3\n", 'stderr' => '' }, data.slice('stdout', 'stderr'))
    end
  end

  def test_python_tool_uses_default_timeout
    result = ChatApp::CodeExecutionTools::ExecutionResult.new(
      stdout: '',
      stderr: "NameError: name 'x' is not defined\n",
      exit_status: 1,
      timed_out: false,
      command: %w[bwrap python3 -]
    )

    with_executor(result) do |fake|
      output = ChatApp::CodeExecutionTools::RunPythonTool.new.call(
        code: 'print(x)',
        root: '.'
      )
      data = YAML.safe_load(output, permitted_classes: [], aliases: false)

      assert_equal(
        {
          'language' => 'python',
          'timeout_seconds' => 30,
          'command' => %w[bwrap python3 -]
        },
        data.slice('language', 'timeout_seconds', 'command')
      )
      assert_equal(
        {
          language: 'python',
          code: 'print(x)',
          root: '.',
          timeout_seconds: 30
        },
        fake.calls.first
      )
    end
  end

  def test_python_tool_preserves_exit_status_and_stderr
    result = ChatApp::CodeExecutionTools::ExecutionResult.new(
      stdout: '',
      stderr: "NameError: name 'x' is not defined\n",
      exit_status: 1,
      timed_out: false,
      command: %w[bwrap python3 -]
    )

    with_executor(result) do
      output = ChatApp::CodeExecutionTools::RunPythonTool.new.call(
        code: 'print(x)',
        root: '.'
      )
      data = YAML.safe_load(output, permitted_classes: [], aliases: false)

      assert_equal(
        { 'exit_status' => 1, 'stderr' => "NameError: name 'x' is not defined\n" },
        data.slice('exit_status', 'stderr')
      )
    end
  end

  def test_sandbox_command_includes_ro_bind_and_unshare_flags
    Dir.mktmpdir do |dir|
      executor = ChatApp::CodeExecutionTools::SandboxExecutor.new
      command = executor.sandbox_command(language: 'ruby', root: dir)

      assert command.include?('--unshare-net') &&
             command.include?('--die-with-parent') &&
             command.include?('--ro-bind') &&
             command.include?(dir) &&
             command.include?('/tmp/work') &&
             command.include?('ruby') &&
             command.include?('-I')
    end
  end
end
