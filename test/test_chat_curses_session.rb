# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

stub_curses = lambda do |target|
  target.define_singleton_method(:fake_mouse_event) { @fake_mouse_event }
  target.define_singleton_method(:fake_mouse_event=) { |value| @fake_mouse_event = value }
  target.define_singleton_method(:getmouse) { fake_mouse_event }
  target.define_singleton_method(:cols) { 80 }
end

unless defined?(Curses)
  module Curses
  end
end

stub_curses.call(Curses)

module Curses
  BUTTON4_PRESSED = 1 unless const_defined?(:BUTTON4_PRESSED)
  BUTTON4_CLICKED = 1 unless const_defined?(:BUTTON4_CLICKED)
  BUTTON4_RELEASED = 1 unless const_defined?(:BUTTON4_RELEASED)
  BUTTON4_DOUBLE_CLICKED = 1 unless const_defined?(:BUTTON4_DOUBLE_CLICKED)
  BUTTON4_TRIPLE_CLICKED = 1 unless const_defined?(:BUTTON4_TRIPLE_CLICKED)
end

require_relative '../lib/ui/chat_curses_session'

class ChatBackendCursesSessionMouseTest < Minitest::Test
  FakeMouseEvent = Struct.new(:x, :y, :z, :bstate)

  class FakeBState
    # rubocop:disable Style/BitwisePredicate
    def initialize(bits)
      @bits = bits
    end

    def anybits?(mask)
      (@bits & mask) != 0
    end
    # rubocop:enable Style/BitwisePredicate

    def to_s
      @bits.to_s
    end
  end

  class FakeChat
    def with_instructions(_prompt)
      self
    end

    def add_message(*)
      nil
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
    end
  end

  def setup
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'Coder',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: nil,
      tools: []
    )

    @registry = ChatBackend::AgentRegistry.new(
      agents: { 'coder' => agent },
      default_agent_name: 'coder'
    )
  end

  def test_mouse_wheel_scrolls_transcript
    Curses.fake_mouse_event = FakeMouseEvent.new(
      10,
      5,
      0,
      FakeBState.new(Curses::BUTTON4_PRESSED)
    )

    session = ChatApp::CursesSession.new(
      'fake-key',
      agent_registry: @registry,
      agent_name: 'coder',
      debug_mouse_enabled: false,
      llm: FakeLLM
    )

    session.handle_key(:mouse)

    assert_equal 4, session.transcript_scroll
  ensure
    session&.shutdown
    Curses.fake_mouse_event = nil
  end
end

class ChatBackendCursesSessionApiDumpTest < Minitest::Test
  class FakeSessionController
    attr_reader :transcript, :agent, :instruction_source_paths

    def initialize
      @transcript = ChatBackend::Transcript.new
      @agent = ChatBackend::AgentSpec.new(
        name: 'coder',
        display_name: 'Coder',
        model: 'gpt-4o-mini',
        system_prompt: 'Be brief',
        temperature: 0.8,
        tools: []
      )
      @instruction_source_paths = []
    end

    def start_session(_agent_name); end
    def shutdown_session; end
    def select_agent(_agent_name); nil end
    def enable_api_dump!; end
    def disable_api_dump!; end
    def api_dump_enabled?; false end
    def api_dump_path; File.expand_path('~/.config/myagent/api_dump.log') end
    def status; ChatBackend::Status.new end
    def session_thread; nil end
    def input_queue; nil end
    def output_queue; nil end
    def model; 'gpt-4o-mini' end
    def system_prompt; 'Be brief' end
    def agent; nil end
    def status_code; 'ready' end
    def response_pending?; false end
    def send_message(_text); end
  end

  class FakeLLM
    class << self
      attr_accessor :openai_api_key, :default_model, :temperature

      def configure
        yield self if block_given?
      end

      def chat
        raise 'not used'
      end
    end
  end

  def setup
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'Coder',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: nil,
      tools: []
    )

    @registry = ChatBackend::AgentRegistry.new(
      agents: { 'coder' => agent },
      default_agent_name: 'coder'
    )
  end

  def with_fake_session_controller
    fake_controller = FakeSessionController.new

    ChatApp::SessionController.define_singleton_method(:new) do |*args, **kwargs|
      fake_controller
    end

    yield fake_controller
  ensure
    ChatApp::SessionController.singleton_class.send(:remove_method, :new)
  end

  def test_api_dump_on_and_off_are_recorded_as_transcript_messages
    with_fake_session_controller do |controller|
      session = ChatApp::CursesSession.new(
        'fake-key',
        agent_registry: @registry,
        agent_name: 'coder',
        debug_mouse_enabled: false,
        llm: FakeLLM
      )

      session.instance_variable_set(:@session_controller, controller)

      session.instance_variable_set(:@input_buffer, '/api_dump on')
      session.instance_variable_set(:@input_cursor, '/api_dump on'.length)
      session.handle_key(:enter)

      session.instance_variable_set(:@input_buffer, '/api_dump off')
      session.instance_variable_set(:@input_cursor, '/api_dump off'.length)
      session.handle_key(:enter)

      assert_equal [
        { role: :info, content: 'api dump enabled' },
        { role: :info, content: 'api dump disabled' }
      ], controller.transcript.messages.last(2)
    ensure
      session&.shutdown
    end
  end

  def test_agent_info_and_instructions_are_recorded_as_transcript_messages
    Dir.mktmpdir do |dir|
      agents_path = File.join(dir, 'AGENTS.md')
      File.write(agents_path, "cwd rule\n")

      with_fake_session_controller do |controller|
        controller.instance_variable_set(:@instruction_source_paths, [agents_path])

        session = ChatApp::CursesSession.new(
          'fake-key',
          agent_registry: @registry,
          agent_name: 'coder',
          debug_mouse_enabled: false,
          llm: FakeLLM
        )

        session.instance_variable_set(:@session_controller, controller)

        session.instance_variable_set(:@input_buffer, '/agent_info')
        session.instance_variable_set(:@input_cursor, '/agent_info'.length)
        session.handle_key(:enter)

        session.instance_variable_set(:@input_buffer, '/instructions')
        session.instance_variable_set(:@input_cursor, '/instructions'.length)
        session.handle_key(:enter)

        assert_equal 'info', controller.transcript.messages[-2][:role].to_s
        assert_includes controller.transcript.messages[-2][:content], 'system_prompt_present'
        assert_equal 'info', controller.transcript.messages[-1][:role].to_s
        assert_includes controller.transcript.messages[-1][:content], 'instruction_messages'
        assert_includes controller.transcript.messages[-1][:content], 'cwd rule'
      ensure
        session&.shutdown
      end
    end
  end
end
