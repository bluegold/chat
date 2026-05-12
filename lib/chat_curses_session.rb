# frozen_string_literal: true

require_relative 'chat_backend'
require_relative 'chat_agent_controls'
require_relative 'chat_command_completion'
require_relative 'chat_curses_mouse'
require_relative 'chat_cursor_editing'
require_relative 'chat_scroll_controls'
require_relative 'chat_tool_tracking'
require_relative 'chat_session_status'
require_relative 'chat_session_info'

Thread.report_on_exception = true

module ChatApp
  class CursesSession
    include ChatBackend::TextLayout
    include AgentControls
    include CommandCompletion
    include CursesMouse
    include CursorEditing
    include ScrollControls
    include ToolTracking
    include SessionStatus
    include SessionInfo

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000
    attr_reader :status, :transcript, :session_thread, :input_queue, :output_queue, :history_store,
                :model, :system_prompt, :input_buffer, :input_cursor, :transcript_scroll,
                :mouse_debug, :agent, :agent_name, :agent_registry
    attr_accessor :transcript_visible_height

    def initialize(api_key, agent_registry:, agent_name:, debug_mouse_enabled:, llm: RubyLLM)
      @api_key = api_key
      @agent_registry = agent_registry
      @agent_name = agent_name.to_s
      @debug_mouse_enabled = debug_mouse_enabled
      @llm = llm
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      @input_history = @history_store.to_a
      @history_index = -1
      @history_draft = nil
      @input_buffer = +''
      @input_cursor = 0
      @transcript_scroll = 0
      @transcript_visible_height = 0
      @mouse_debug = nil
      @notice_message = nil
      @running = true

      start_session(@agent_name)
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
      when :tab
        complete_input(agent_names: @agent_registry.names)
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
      shutdown_session
    rescue StandardError
      # Nothing else to do on shutdown.
    end

    def select_agent(name)
      agent_name = name.to_s.strip
      return if agent_name.empty?

      agent = @agent_registry[agent_name]
      unless agent
        @notice_message = "unknown agent: #{agent_name}"
        return
      end

      return if @agent&.name == agent.name

      shutdown_session
      start_session(agent.name)
      @notice_message = "switched to #{agent.name}"
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
      case msg[:type]
      when :tool_call
        start_tool_status(msg[:name])
      when :stream_end, :error
        clear_tool_status
        @tool_hint_features = nil
      when :tool_result
        nil
      end
    end

    def append_input(key)
      return unless key.is_a?(String)
      return if response_pending?
      return unless key.match?(/\A[[:print:]\n\t]+\z/u)

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

      if agent_command?(text)
        select_agent(agent_name_from_command(text))
        @input_buffer = +''
        @input_cursor = 0
        @history_index = -1
        @history_draft = nil
        return
      end

      if exit_command?(text)
        @running = false
        @input_buffer = +''
        @input_cursor = 0
        @history_index = -1
        @history_draft = nil
        return
      end

      if session_info_command?(text)
        @transcript.info_message(session_info_text)
        @notice_message = nil
        @input_buffer = +''
        @input_cursor = 0
        @history_index = -1
        @history_draft = nil
        return
      end

      @transcript.user_message(text)
      @tool_hint_features = tool_hints_for(text)
      stored = @history_store.add(text)
      @input_history << stored if stored
      @input_history = @input_history.last(@history_store.max_entries)
      @input_queue.push(type: :user_message, content: text)
      @notice_message = nil

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

    def start_session(agent_name)
      @agent = @agent_registry[agent_name] || @agent_registry.default_agent
      raise ArgumentError, "unknown agent #{agent_name.inspect}" unless @agent

      @agent_name = @agent.name
      @model = @agent.model
      @system_prompt = @agent.system_prompt
      @status = ChatBackend::Status.new
      @transcript = ChatBackend::Transcript.new
      @input_queue = Queue.new
      @output_queue = Queue.new

      @session_thread = ChatBackend::SessionThread.new(
        ChatBackend::SessionConfig.new(
          input_queue: @input_queue,
          output_queue: @output_queue,
          api_key: @api_key,
          agent: @agent,
          response_sync: @status,
          llm: @llm
        )
      )
    end

    def shutdown_session
      return unless @session_thread

      @input_queue.push(type: :shutdown)
      @session_thread.join(0.5)
      @session_thread.kill if @session_thread.alive?
    rescue StandardError
      nil
    end
  end
end
