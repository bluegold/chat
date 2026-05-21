# frozen_string_literal: true

require 'forwardable'
require_relative '../backend/chat_backend'
require_relative 'chat_command_parser'
require_relative 'chat_command_completer'
require_relative 'chat_curses_mouse'
require_relative 'chat_cursor_editing'
require_relative 'chat_scroll_state'
require_relative '../tools/chat_tool_tracking'
require_relative '../tools/chat_tool_hints'
require_relative 'chat_status_line_formatter'
require_relative 'chat_session_info'
require_relative '../backend/chat_session_controller'
require_relative 'chat_history_navigator'

Thread.report_on_exception = true

module ChatApp
  class CursesSession
    extend Forwardable

    include ChatBackend::TextLayout
    include CursesMouse
    include CursorEditing
    include ToolTracking
    include ToolHints
    include SessionInfo

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000
    attr_reader :history_store, :input_buffer, :input_cursor,
                :mouse_debug, :agent_name, :agent_registry, :scroll_state

    def_delegators :@session_controller, :status, :transcript, :session_thread,
                   :input_queue, :output_queue, :model, :system_prompt, :agent,
                   :status_code, :response_pending?

    def_delegator :@scroll_state, :visible_height, :transcript_visible_height
    def_delegator :@scroll_state, :visible_height=, :transcript_visible_height=
    def_delegator :@scroll_state, :scroll, :transcript_scroll

    def initialize(api_key, agent_registry:, agent_name:, debug_mouse_enabled:, llm: RubyLLM)
      @api_key = api_key
      @agent_registry = agent_registry
      @agent_name = agent_name.to_s
      @debug_mouse_enabled = debug_mouse_enabled
      @llm = llm
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      @history_navigator = HistoryNavigator.new(@history_store)
      @input_buffer = +''
      @input_cursor = 0
      @scroll_state = ScrollState.new
      @command_parser = CommandParser.new(@agent_registry)
      @command_completer = CommandCompleter.new(@agent_registry.names)
      @status_line_formatter = StatusLineFormatter.new
      @session_controller = SessionController.new(api_key: @api_key, agent_registry: @agent_registry, llm: @llm)
      @mouse_debug = nil
      @notice_message = nil
      @running = true

      @session_controller.start_session(@agent_name)
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
        @scroll_state.scroll_by(@scroll_state.page_scroll_amount)
      when :page_down
        @scroll_state.scroll_by(-@scroll_state.page_scroll_amount)
      when :mouse
        handle_mouse_event
      when :tab
        if (res = @command_completer.complete(@input_buffer, @input_cursor))
          @input_buffer = res[:buffer]
          @input_cursor = res[:cursor]
          @notice_message = res[:notice]
        end
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
        msg = output_queue.pop(true)
        handle_output_message(msg)
      rescue ThreadError
        break
      end
    end

    def shutdown
      @running = false
      @session_controller.shutdown_session
    rescue StandardError
      # Nothing else to do on shutdown.
    end

    def select_agent(name)
      agent_name = name.to_s.strip
      return if agent_name.empty?

      new_agent = @session_controller.select_agent(agent_name)
      unless new_agent
        @notice_message = "unknown agent: #{agent_name}"
        return
      end

      @agent_name = new_agent.name
      @notice_message = "switched to #{new_agent.name}"
    end

    def input_viewport(available_width)
      super(@input_buffer, @input_cursor, available_width)
    end

    def scroll_transcript(delta)
      @scroll_state.scroll_by(delta)
    end

    def scroll_to_bottom
      @scroll_state.scroll_to_bottom
    end

    def page_scroll_amount
      @scroll_state.page_scroll_amount
    end

    def wheel_scroll_amount
      @scroll_state.wheel_scroll_amount
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

    def status_line
      @status_line_formatter.format(
        agent_name: @agent_name,
        model: model,
        status: status,
        scroll: @scroll_state.scroll,
        notice_message: @notice_message,
        debug_mouse_enabled: @debug_mouse_enabled,
        mouse_debug: @mouse_debug,
        agent: agent,
        tool_classes: respond_to?(:tool_classes, true) ? tool_classes : nil,
        current_input_text: @input_buffer,
        tool_hint_features: @tool_hint_features,
        tool_status_message: respond_to?(:tool_status_message, true) ? tool_status_message : nil
      )
    end

    def submit_input
      @scroll_state.scroll_to_bottom
      text = @input_buffer.dup
      return if text.strip.empty?
      return if response_pending?

      if @command_parser.agent_command?(text)
        select_agent(@command_parser.agent_name_from_command(text))
        reset_input!
        return
      end

      if @command_parser.exit_command?(text)
        @running = false
        reset_input!
        return
      end

      if @command_parser.session_info_command?(text)
        transcript.info_message(session_info_text)
        @notice_message = nil
        reset_input!
        return
      end

      transcript.user_message(text)
      @tool_hint_features = tool_hints_for(text)
      @history_store.add(text)
      @session_controller.send_message(text)
      @notice_message = nil

      reset_input!
    end

    def recall_history(direction)
      @input_buffer = @history_navigator.recall(direction, @input_buffer)
      @input_cursor = input_length
    end

    def reset_input!
      @input_buffer = +''
      @input_cursor = 0
      @history_navigator.reset
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
      transcript.apply_output_message(msg)
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
  end
end
