# frozen_string_literal: true

require_relative 'chat_backend'
require_relative 'chat_curses_mouse'

Thread.report_on_exception = true

module ChatApp
  class CursesSession
    include ChatBackend::TextLayout
    include CursesMouse

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    attr_reader :status, :transcript, :session_thread, :input_queue, :output_queue, :history_store,
                :model, :system_prompt, :input_buffer, :input_cursor, :transcript_scroll,
                :mouse_debug
    attr_accessor :transcript_visible_height

    def initialize(api_key, model:, system_prompt:, debug_mouse_enabled:, llm: RubyLLM)
      @model = model
      @system_prompt = system_prompt
      @status = ChatBackend::Status.new
      @transcript = ChatBackend::Transcript.new
      @input_queue = Queue.new
      @output_queue = Queue.new
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      @input_history = @history_store.to_a
      @history_index = -1
      @history_draft = nil
      @input_buffer = +''
      @input_cursor = 0
      @transcript_scroll = 0
      @transcript_visible_height = 0
      @mouse_debug = nil
      @debug_mouse_enabled = debug_mouse_enabled
      @running = true

      @session_thread = ChatBackend::SessionThread.new(
        ChatBackend::SessionConfig.new(
          input_queue: @input_queue,
          output_queue: @output_queue,
          api_key: api_key,
          model: model,
          system_prompt: @system_prompt,
          response_sync: @status,
          llm: llm
        )
      )
    end

    def running?
      @running
    end

    def handle_key(key)
      case key
      when :resize
        nil
      when :backspace, :delete, :left, :right, :home, :end
        handle_edit_key(key)
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

    def drain_output_queue
      loop do
        msg = @output_queue.pop(true)
        handle_output_message(msg)
      rescue ThreadError
        break
      end
    end

    def shutdown
      @running = false
      @input_queue.push(type: :shutdown)
      @session_thread.join(0.5)
      @session_thread.kill if @session_thread.alive?
    rescue StandardError
      # Nothing else to do on shutdown.
    end

    def response_pending?
      @status.pending? || @status.streaming?
    end

    def input_viewport(available_width)
      available_width = [available_width, 0].max
      chars = @input_buffer.each_char.to_a
      widths = chars.map { |char| display_width(char) }
      cursor_index = @input_cursor.clamp(0, chars.length)
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

    private

    def handle_edit_key(key)
      return if response_pending?

      case key
      when :backspace
        delete_before_cursor
      when :delete
        delete_after_cursor
      when :left
        move_input_cursor(-1)
      when :right
        move_input_cursor(1)
      when :home
        move_input_cursor_to(0)
      when :end
        move_input_cursor_to(input_length)
      end
    end

    def handle_output_message(msg)
      @transcript.apply_output_message(msg)
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
      when :down
        return if @history_index == -1

        if @history_index < @input_history.length - 1
          @history_index += 1
          @input_buffer = @input_history[@history_index].dup
        else
          @history_index = -1
          @input_buffer = @history_draft.to_s
          @history_draft = nil
        end
      end

      @input_cursor = input_length
    end

    def input_length
      @input_buffer.each_char.count
    end

    def move_input_cursor(delta)
      move_input_cursor_to(@input_cursor + delta)
    end

    def move_input_cursor_to(position)
      @input_cursor = position.clamp(0, input_length)
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
  end
end
