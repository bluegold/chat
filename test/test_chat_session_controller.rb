# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/chat_session_controller'

class ChatSessionControllerTest < Minitest::Test
  class FakeChat
    def with_instructions(_prompt)
      self
    end

    def add_message(role:, content:)
      # Do nothing
    end

    def before_tool_call(&block)
      @before_tool_call = block
      self
    end

    def after_tool_result(&block)
      @after_tool_result = block
      self
    end

    def ask(_content, &block)
      if @before_tool_call
        tc = Struct.new(:name, :arguments).new('test_tool', { arg1: 'val1' })
        @before_tool_call.call(tc)
      end
      @after_tool_result&.call('tool output')

      block&.call("Hello ")
      block&.call("agent")
      "Hello agent"
    end
  end

  class FakeLLM
    class << self
      attr_accessor :openai_api_key, :default_model, :temperature

      def configure
        yield self if block_given?
      end

      def chat
        FakeChat.new
      end

      def generate_response(*_args)
        # Do nothing
      end
    end
  end

  def setup
    @agent_spec_coder = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'Coder Agent',
      model: 'gpt-4o-mini',
      system_prompt: 'Be coder',
      temperature: 0.7,
      tools: []
    )
    @agent_spec_helper = ChatBackend::AgentSpec.new(
      name: 'helper',
      display_name: 'Helper Agent',
      model: 'gpt-4o-mini',
      system_prompt: 'Be helper',
      temperature: 0.7,
      tools: []
    )
    @registry = ChatBackend::AgentRegistry.new(
      agents: {
        'coder' => @agent_spec_coder,
        'helper' => @agent_spec_helper
      },
      default_agent_name: 'coder'
    )
  end

  def test_initialization
    controller = ChatApp::SessionController.new(
      api_key: 'fake_key',
      agent_registry: @registry,
      llm: FakeLLM
    )

    assert_nil controller.agent
    assert_nil controller.status
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_start_session_resolves_default_agent
    controller = ChatApp::SessionController.new(
      api_key: 'fake_key',
      agent_registry: @registry,
      llm: FakeLLM
    )
    controller.start_session('coder')

    assert_equal 'coder', controller.agent.name
    assert_equal 'gpt-4o-mini', controller.model
    assert_equal 'Be coder', controller.system_prompt
    assert_instance_of ChatBackend::Status, controller.status
    assert_instance_of ChatBackend::Transcript, controller.transcript
    assert_instance_of Queue, controller.input_queue
    assert_instance_of Queue, controller.output_queue
    assert_instance_of ChatBackend::SessionThread, controller.session_thread

    controller.shutdown_session
  end

  def test_select_agent_switches_session
    controller = ChatApp::SessionController.new(
      api_key: 'fake_key',
      agent_registry: @registry,
      llm: FakeLLM
    )
    controller.start_session('coder')
    first_thread = controller.session_thread

    switched = controller.select_agent('helper')

    assert_equal 'helper', switched.name
    assert_equal 'helper', controller.agent.name
    assert_equal 'Be helper', controller.system_prompt
    refute_equal first_thread, controller.session_thread

    controller.shutdown_session
  end

  def test_send_message_pushes_to_input_queue
    controller = ChatApp::SessionController.new(
      api_key: 'fake_key',
      agent_registry: @registry,
      llm: FakeLLM
    )
    controller.start_session('coder')
    controller.send_message('Hello world')

    assert_predicate controller, :response_pending?
    msg = controller.input_queue.pop

    assert_equal :user_message, msg[:type]
    assert_equal 'Hello world', msg[:content]

    controller.shutdown_session
  end

  def test_status_code_mapping
    controller = ChatApp::SessionController.new(
      api_key: 'fake_key',
      agent_registry: @registry,
      llm: FakeLLM
    )

    assert_equal 'ready', controller.status_code

    controller.start_session('coder')

    assert_equal 'ready', controller.status_code

    controller.status.expect_response

    assert_equal 'pending', controller.status_code

    controller.status.start_response

    assert_equal 'streaming', controller.status_code

    controller.shutdown_session
  end

  # rubocop:disable Metrics/AbcSize
  def test_session_archives_conversation_to_jsonl
    require 'tmpdir'
    Dir.mktmpdir do |tmpdir|
      controller = ChatApp::SessionController.new(
        api_key: 'fake_key',
        agent_registry: @registry,
        llm: FakeLLM,
        archive_base_dir: tmpdir
      )
      controller.start_session('coder')

      # send message through the controller (which runs it via the SessionThread loop)
      controller.send_message("Hello from user\nLine 2")

      # Wait for processing to complete or shutdown the session (which joins the thread)
      controller.shutdown_session

      # Verify the directory and files
      now = Time.now
      expected_dir = File.join(tmpdir, now.strftime('%Y/%m/%d'))

      assert File.directory?(expected_dir), "Archive directory should be created"

      # File name derived from first user message line, stripped of unsafe chars
      files = Dir.glob(File.join(expected_dir, "*.jsonl"))
      assert_equal 1, files.length, "One archive file should exist"
      expected_path = files.first
      expected_cwd = File.basename(Dir.pwd)
      assert_match(/#{expected_cwd}-Hello_from_user-\d{6}\.jsonl\z/, expected_path)

      # Parse JSONL lines
      lines = File.readlines(expected_path).map { |line| JSON.parse(line, symbolize_names: true) }

      # Should have 5 events: session_start, user, tool_call, tool_result, assistant
      assert_equal 5, lines.length

      # 1. session_start
      assert_equal 'session_start', lines[0][:event]
      assert_equal 'coder', lines[0][:agent]
      assert_equal Dir.pwd, lines[0][:cwd]
      refute_nil lines[0][:timestamp]

      # 2. user message
      assert_equal 'user', lines[1][:role]
      assert_equal "Hello from user\nLine 2", lines[1][:content]

      # 3. tool call
      assert_equal 'tool_call', lines[2][:role]
      assert_equal 'test_tool', lines[2][:name]
      assert_equal 'val1', lines[2][:arguments][:arg1]

      # 4. tool result
      assert_equal 'tool_result', lines[3][:role]
      assert_equal 'test_tool', lines[3][:name]
      assert_equal 'tool output', lines[3][:result]

      # 5. assistant message
      assert_equal 'assistant', lines[4][:role]
      assert_equal 'Hello agent', lines[4][:content]
    end
  end
  # rubocop:enable Metrics/AbcSize
  # rubocop:enable Minitest/MultipleAssertions
end
