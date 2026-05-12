#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thread'

begin
  require 'curses'
rescue LoadError => e
  abort "Error: curses is required for tui_chat.rb (#{e.message})"
end

require_relative 'chat_backend'

Thread.report_on_exception = true

class CursesInput
  def initialize(adapter: Curses)
    @adapter = adapter
  end

  def read
    read_key(blocking: true)
  end

  def read_nonblock
    read_key(blocking: false)
  end

  private

  def read_key(blocking:)
    @adapter.stdscr.timeout = blocking ? -1 : 0 if @adapter.stdscr.respond_to?(:timeout=)

    key = @adapter.getch
    return nil if key.nil? || key == -1

    normalize_key(key)
  end

  def normalize_key(key)
    return key if key.is_a?(String)

    case key
    when @adapter::KEY_RESIZE
      :resize
    when @adapter::KEY_UP
      :up
    when @adapter::KEY_DOWN
      :down
    when @adapter::KEY_LEFT
      :left
    when @adapter::KEY_RIGHT
      :right
    when @adapter::KEY_HOME, @adapter::KEY_CTRL_A, 1
      :home
    when @adapter::KEY_END, 5
      :end
    when @adapter::KEY_PPAGE
      :page_up
    when @adapter::KEY_NPAGE
      :page_down
    when @adapter::KEY_MOUSE
      :mouse
    when @adapter::KEY_BACKSPACE, 8, 127
      :backspace
    when @adapter::KEY_DC
      :delete
    when @adapter::KEY_ENTER, 10, 13
      :enter
    when 3, 4
      :quit
    else
      return key if key.negative? || key > 255
      return read_utf8_char(key) if key >= 0x80

      key.chr(Encoding::UTF_8)
    end
  end

  def read_utf8_char(first_byte)
    bytes = [first_byte]

    expected =
      if (first_byte & 0xE0) == 0xC0
        2
      elsif (first_byte & 0xF0) == 0xE0
        3
      elsif (first_byte & 0xF8) == 0xF0
        4
      else
        1
      end

    (expected - 1).times do
      next_byte = @adapter.getch
      break unless next_byte.is_a?(Integer) && (next_byte & 0xC0) == 0x80

      bytes << next_byte
    end

    bytes.pack('C*').force_encoding(Encoding::UTF_8)
  end
end

module ChatApp
  class CursesUI
    include ChatBackend::TextLayout

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    def initialize(api_key, model: 'gpt-4o-mini')
      @api_key = api_key
      @model = model
      @system_prompt = load_system_prompt
      @input_queue = Queue.new
      @output_queue = Queue.new
      @status = ChatBackend::Status.new
      @session_thread = ChatBackend::SessionThread.new(@input_queue, @output_queue, api_key, model, @system_prompt, @status)
      @input = CursesInput.new
      @transcript = ChatBackend::Transcript.new
      @input_buffer = +''
      @input_cursor = 0
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      @input_history = @history_store.to_a
      @history_index = -1
      @history_draft = nil
      @transcript_scroll = 0
      @mouse_debug = nil
      @debug_mouse_enabled = env_truthy?(ENV['TUI_CHAT_DEBUG_MOUSE']) || env_truthy?(ENV['TUI_CHAT_DEBUG'])
      @running = true
      @screen_ready = false
    end

    def run
      setup_curses
      main_loop
    ensure
      shutdown
    end

    private

    def setup_curses
      Curses.init_screen
      @screen_ready = true
      Curses.raw
      Curses.noecho
      Curses.stdscr.keypad(true)
      mouse_events = Curses::ALL_MOUSE_EVENTS
      mouse_events |= Curses::REPORT_MOUSE_POSITION if Curses.const_defined?(:REPORT_MOUSE_POSITION)
      Curses.mousemask(mouse_events) if Curses.respond_to?(:mousemask)
      Curses.mouseinterval(0) if Curses.respond_to?(:mouseinterval)
      Curses.ESCDELAY = 10 if Curses.respond_to?(:ESCDELAY=)
      Curses.stdscr.timeout = 100 if Curses.stdscr.respond_to?(:timeout=)
      Curses.curs_set(1) if Curses.respond_to?(:curs_set)
    rescue StandardError => e
      close_screen
      raise e
    end

    def main_loop
      while @running
        drain_output_queue
        draw

        key = @input.read_nonblock
        handle_key(key) unless key.nil?
        sleep 0.01 if key.nil?
      end
    rescue Interrupt
      @running = false
    end

    def handle_key(key)
      case key
      when :resize
        nil
      when :backspace
        delete_before_cursor unless response_pending?
      when :delete
        delete_after_cursor unless response_pending?
      when :left
        move_input_cursor(-1) unless response_pending?
      when :right
        move_input_cursor(1) unless response_pending?
      when :home
        move_input_cursor_to(0) unless response_pending?
      when :end
        move_input_cursor_to(input_length) unless response_pending?
      when :up
        recall_history(:up)
      when :down
        recall_history(:down)
      when :page_up
        scroll_transcript(page_scroll_amount)
      when :page_down
        scroll_transcript(-page_scroll_amount)
      when :mouse
        handle_mouse_event
      when :enter
        submit_input
      when :quit
        @running = false
      else
        append_input(key)
      end
    end

    def append_input(key)
      return unless key.is_a?(String)
      return if response_pending?

      return unless key.match?(/\A[[:print:]]+\z/u)

      chars = @input_buffer.each_char.to_a
      chars.insert(@input_cursor, key)
      @input_buffer = chars.join
      @input_cursor += key.length
    end

    def submit_input
      scroll_to_bottom
      text = @input_buffer.dup
      return if text.strip.empty?
      return if response_pending?

      @transcript.user_message(text)
      stored = @history_store.add(text)
      @input_history << stored if stored
      @input_history = @input_history.last(@history_store.max_entries)
      @input_queue.push(type: :user_message, content: text)

      @input_buffer = +''
      @input_cursor = 0
      @history_index = -1
      @history_draft = nil
    end

    def recall_history(direction)
      return if @input_history.empty?

      case direction
      when :up
        if @history_index == -1
          @history_draft = @input_buffer.dup
          @history_index = @input_history.length - 1
        elsif @history_index.positive?
          @history_index -= 1
        end
        @input_buffer = @input_history[@history_index].dup
        @input_cursor = input_length
      when :down
        return if @history_index == -1

        if @history_index < @input_history.length - 1
          @history_index += 1
          @input_buffer = @input_history[@history_index].dup
          @input_cursor = input_length
        else
          @history_index = -1
          @input_buffer = @history_draft.to_s
          @history_draft = nil
          @input_cursor = input_length
        end
      end
    end

    def drain_output_queue
      loop do
        msg = @output_queue.pop(true)
        handle_output_message(msg)
      rescue ThreadError
        break
      end
    end

    def handle_output_message(msg)
      @transcript.apply_output_message(msg)
    end

    def draw
      rows = Curses.lines
      cols = Curses.cols
      return if rows <= 0 || cols <= 0

      Curses.stdscr.erase
      draw_header(cols)
      draw_transcript(rows, cols)
      draw_separator(rows, cols)
      draw_input(rows, cols)
      Curses.stdscr.refresh
    rescue StandardError
      # Keep the app alive even if the terminal is temporarily unhappy.
    end

    def draw_header(cols)
      status = response_pending? ? 'thinking...' : 'ready'
      title = "RubyLLM Chat"
      model = @model.to_s
      prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
      line = "#{title} | model: #{model} | #{status} | #{prompt_state}"
      Curses.stdscr.setpos(0, 0)
      Curses.stdscr.addstr(truncate_to_width(line, cols))
    end

    def draw_transcript(rows, cols)
      visible_height = [rows - 3, 0].max
      @transcript_visible_height = visible_height
      return if visible_height.zero?

      visible_lines = @transcript.window(cols, scroll: @transcript_scroll, height: visible_height)

      visible_lines.each_with_index do |line, idx|
        row = 1 + idx
        break if row >= rows - 2

        Curses.stdscr.setpos(row, 0)
        Curses.stdscr.addstr(truncate_to_width(line, cols))
      end

      if visible_lines.empty?
        Curses.stdscr.setpos(1, 0)
        Curses.stdscr.addstr(truncate_to_width('Type a message and press Enter.', cols))
      end
    end

    def draw_separator(rows, cols)
      return if rows < 2

      Curses.stdscr.setpos(rows - 2, 0)
      Curses.stdscr.addstr(truncate_to_width(status_line, cols).ljust(cols))
    end

    def draw_input(rows, cols)
      return if rows < 1

      prefix = '> '
      visible_text, cursor_x = input_viewport([cols - display_width(prefix), 0].max)
      line = "#{prefix}#{visible_text}"
      visible_line = truncate_to_width(line, cols)

      Curses.stdscr.setpos(rows - 1, 0)
      Curses.stdscr.addstr(visible_line)
      Curses.stdscr.clrtoeol if Curses.stdscr.respond_to?(:clrtoeol)
      Curses.stdscr.setpos(rows - 1, [display_width(prefix) + cursor_x, cols - 1].min)
    end

    def status_line
      status = response_pending? ? 'thinking...' : 'ready'
      prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
      scroll_value = @transcript_scroll.to_i
      scroll_state = scroll_value.positive? ? "scroll: #{scroll_value}" : 'scroll: bottom'
      mouse_state = @debug_mouse_enabled ? (@mouse_debug || 'mouse: -') : nil
      parts = ["model: #{@model}", status, prompt_state, scroll_state]
      parts << mouse_state if mouse_state
      parts.join(' | ')
    end

    def response_pending?
      @status.pending? || @status.streaming?
    end

    def input_length
      @input_buffer.each_char.count
    end

    def move_input_cursor(delta)
      move_input_cursor_to(@input_cursor + delta)
    end

    def move_input_cursor_to(position)
      @input_cursor = [[position, 0].max, input_length].min
    end

    def delete_before_cursor
      return if @input_cursor <= 0

      chars = @input_buffer.each_char.to_a
      chars.delete_at(@input_cursor - 1)
      @input_buffer = chars.join
      @input_cursor -= 1
    end

    def delete_after_cursor
      return if @input_cursor >= input_length

      chars = @input_buffer.each_char.to_a
      chars.delete_at(@input_cursor)
      @input_buffer = chars.join
    end

    def input_viewport(available_width)
      available_width = [available_width, 0].max
      chars = @input_buffer.each_char.to_a
      widths = chars.map { |char| display_width(char) }
      cursor_index = [[@input_cursor, 0].max, chars.length].min
      cursor_width = widths[0...cursor_index].sum
      total_width = widths.sum

      return [@input_buffer.dup, cursor_width] if total_width <= available_width

      start_width = [cursor_width - available_width + 1, 0].max
      start_index = 0
      consumed = 0

      while start_index < chars.length && consumed + widths[start_index] <= start_width
        consumed += widths[start_index]
        start_index += 1
      end

      visible = +''
      visible_width = 0
      cursor_x = 0

      chars[start_index..].to_a.each_with_index do |char, offset|
        char_width = widths[start_index + offset]
        break if visible_width + char_width > available_width

        visible << char
        visible_width += char_width
        cursor_x = visible_width if start_index + offset + 1 <= cursor_index
      end

      [visible, cursor_x]
    end

    def scroll_transcript(delta)
      @transcript_scroll = [@transcript_scroll + delta, 0].max
    end

    def scroll_to_bottom
      @transcript_scroll = 0
    end

    def page_scroll_amount
      height = @transcript_visible_height.to_i
      return 8 if height <= 0

      [height - 1, 8].max
    end

    def wheel_scroll_amount
      4
    end

    def handle_mouse_event
      verbose = $VERBOSE
      $VERBOSE = nil
      event = Curses.getmouse
      return unless event

      @mouse_debug = format_mouse_debug(event)
      delta = mouse_wheel_delta(event)
      scroll_transcript(delta * wheel_scroll_amount) if delta != 0
    rescue StandardError
      nil
    ensure
      $VERBOSE = verbose
    end

    def mouse_wheel_delta(event)
      bstate = event.bstate
      delta = 0
      delta += 1 if mouse_button?(bstate, :up)
      delta -= 1 if mouse_button?(bstate, :down)

      z = event.z
      delta += 1 if z.is_a?(Integer) && z.positive?
      delta -= 1 if z.is_a?(Integer) && z.negative?

      delta.clamp(-1, 1)
    end

    def mouse_button?(bstate, direction)
      mask =
        case direction
        when :up
          mouse_mask(:BUTTON4_PRESSED, :BUTTON4_CLICKED, :BUTTON4_RELEASED, :BUTTON4_DOUBLE_CLICKED, :BUTTON4_TRIPLE_CLICKED)
        when :down
          mouse_mask(
            :BUTTON5_PRESSED,
            :BUTTON5_CLICKED,
            :BUTTON5_RELEASED,
            :BUTTON5_DOUBLE_CLICKED,
            :BUTTON5_TRIPLE_CLICKED,
            1 << 20,
            1 << 21,
            1 << 22,
            1 << 23,
            1 << 24
          )
        else
          0
        end

      (bstate & mask) != 0
    end

    def format_mouse_debug(event)
      parts = [
        "mouse:",
        "x=#{event.x}",
        "y=#{event.y}",
        "z=#{event.z}",
        "b=#{event.bstate}"
      ]
      truncate_to_width(parts.join(' '), [Curses.cols - 1, 0].max)
    rescue StandardError
      'mouse: error'
    end

    def env_truthy?(value)
      case value.to_s.strip.downcase
      when '1', 'true', 'yes', 'on'
        true
      else
        false
      end
    end

    def mouse_mask(*names)
      names.sum do |name|
        if name.is_a?(Integer)
          name
        elsif Curses.const_defined?(name)
          Curses.const_get(name)
        else
          0
        end
      end
    end

    def load_system_prompt
      prompt_file = File.join(Dir.pwd, '.system_prompt')
      return nil unless File.exist?(prompt_file)

      prompt = File.read(prompt_file)
      prompt.strip.empty? ? nil : prompt
    rescue StandardError
      nil
    end

    def shutdown
      @running = false
      close_screen

      return unless @session_thread

      @input_queue.push(type: :shutdown)
      @session_thread.join(0.5)
      @session_thread.kill if @session_thread.alive?
    rescue StandardError
      # Nothing else to do on shutdown.
    end

    def close_screen
      return unless @screen_ready

      Curses.close_screen
      @screen_ready = false
    rescue StandardError
      @screen_ready = false
    end
  end
end
