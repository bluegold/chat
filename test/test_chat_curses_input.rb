# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../lib/backend/chat_backend'
require_relative '../lib/ui/chat_curses_input'
require_relative '../lib/ui/chat_curses_input_render'

class ChatBackendCursesInputRenderTest < Minitest::Test
  def test_input_render_state_shows_prompt_on_empty_buffer
    object = Object.new
    object.extend(ChatBackend::TextLayout)
    object.extend(ChatApp::CursesInputRender)

    state = object.send(
      :input_render_state,
      buffer: '',
      cursor: 0,
      cols: 20,
      max_height: 4
    )

    assert_equal ['> '], state[:lines]
    assert_equal 0, state[:cursor_row]
    assert_equal 2, state[:cursor_col]
  end

  def test_input_render_state_displays_multiline_content_as_rows
    object = Object.new
    object.extend(ChatBackend::TextLayout)
    object.extend(ChatApp::CursesInputRender)

    state = object.send(
      :input_render_state,
      buffer: "one\ntwo",
      cursor: 7,
      cols: 20,
      max_height: 4
    )

    assert_equal ['> one', 'two'], state[:lines]
    assert_equal 1, state[:cursor_row]
    assert_equal 3, state[:cursor_col]
  end
end

class ChatBackendCursesInputTest < Minitest::Test
  class FakeStdScr
    attr_accessor :timeout
  end

  class FakeAdapter
    KEY_RESIZE = 1000
    KEY_UP = 1001
    KEY_DOWN = 1002
    KEY_LEFT = 1003
    KEY_RIGHT = 1004
    KEY_HOME = 1005
    KEY_END = 1006
    KEY_PPAGE = 1007
    KEY_NPAGE = 1008
    KEY_MOUSE = 1009
    KEY_BACKSPACE = 1010
    KEY_DC = 1011
    KEY_ENTER = 1012
    KEY_CTRL_A = 1013

    class << self
      attr_reader :queue, :stdscr

      def reset(queue)
        @queue = queue.dup
        @pushed_back = []
        @stdscr = FakeStdScr.new
      end

      def getch
        return @pushed_back.shift unless @pushed_back.nil? || @pushed_back.empty?

        @queue.shift
      end

      def ungetch(char)
        @pushed_back ||= []
        @pushed_back.unshift(char)
      end
    end
  end

  def test_read_nonblock_returns_pasted_newlines_as_text
    FakeAdapter.reset(
      [
        27, '[', '2', '0', '0', '~',
        'a', 'b', 10, 'c',
        27, '[', '2', '0', '1', '~',
        'x'
      ]
    )

    input = ChatApp::CursesInput.new(adapter: FakeAdapter)
    collected = []

    loop do
      key = input.read_nonblock
      break if key.nil?

      collected << key
    end

    assert_equal %w[a b] + ["\n"] + %w[c x], collected
  end
end
