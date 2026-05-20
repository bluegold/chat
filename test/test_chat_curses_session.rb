# frozen_string_literal: true

require 'minitest/autorun'

if defined?(Curses)
  class << Curses
    attr_accessor :fake_mouse_event

    def getmouse
      fake_mouse_event
    end

    def cols
      80
    end
  end
else
  module Curses
    class << self
      attr_accessor :fake_mouse_event

      def getmouse
        fake_mouse_event
      end

      def cols
        80
      end
    end
  end
end

module Curses
  BUTTON4_PRESSED = 1 unless const_defined?(:BUTTON4_PRESSED)
  BUTTON4_CLICKED = 1 unless const_defined?(:BUTTON4_CLICKED)
  BUTTON4_RELEASED = 1 unless const_defined?(:BUTTON4_RELEASED)
  BUTTON4_DOUBLE_CLICKED = 1 unless const_defined?(:BUTTON4_DOUBLE_CLICKED)
  BUTTON4_TRIPLE_CLICKED = 1 unless const_defined?(:BUTTON4_TRIPLE_CLICKED)
end

require_relative '../lib/chat_curses_session'

class ChatBackendCursesSessionMouseTest < Minitest::Test
  FakeMouseEvent = Struct.new(:x, :y, :z, :bstate)

  class FakeBState
    def initialize(bits)
      @bits = bits
    end

    def anybits?(mask)
      (@bits & mask) != 0
    end

    def to_s
      @bits.to_s
    end
  end

  class FakeChat
    def with_instructions(_prompt)
      self
    end

    def add_message(role:, content:)
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
