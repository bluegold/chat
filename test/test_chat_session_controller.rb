# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/chat_session_controller'

class ChatSessionControllerTest < Minitest::Test
  class FakeLLM
    class << self
      attr_accessor :openai_api_key, :default_model, :temperature

      def configure
        yield self if block_given?
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
  # rubocop:enable Minitest/MultipleAssertions
end
