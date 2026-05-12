# frozen_string_literal: true

require 'io/console'
require 'reline'
require_relative 'chat_backend'
require_relative 'chat_agent_controls'
require_relative 'chat_command_completion'
require_relative 'chat_tool_tracking'
require_relative 'chat_session_info'

Thread.report_on_exception = true

module ChatApp
  class RelineUI
    include ChatBackend::TextLayout
    include AgentControls
    include CommandCompletion
    include ToolTracking
    include SessionInfo

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    def initialize(api_key, agent_registry:, agent_name:)
      @api_key = api_key
      @agent_registry = agent_registry
      @agent_name = agent_name.to_s
      @input_queue = Queue.new
      @output_queue = Queue.new
      @shutdown = false
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      load_history_into_reline
      start_session(@agent_name)
      install_completion
    end

    def run
      setup_terminal
      main_loop
    ensure
      shutdown
    end

    private

    def setup_terminal
      $stdout.sync = true
      print "\e[?25h"
    end

    def main_loop
      until @shutdown
        drain_output_queue
        render
        render_input_zone(prompt_text)

        input = read_input(prompt_text)
        break if input.nil? || exit_command?(input)
        next if input.strip.empty?

        submit_input(input)
        wait_for_response
      end
    rescue Interrupt
      @shutdown = true
    end

    def read_input(prompt)
      Reline.readline(prompt, false)
    rescue Interrupt
      nil
    end

    def submit_input(content)
      if agent_command?(content)
        agent_name = agent_name_from_command(content)
        select_agent(agent_name)
        return
      end

      if session_info_command?(content)
        @transcript.info_message(session_info_text)
        @notice_message = nil
        return
      end

      @history_store.add(content)
      Reline::HISTORY.push(content)
      @transcript.user_message(content)
      @status.expect_response
      @input_queue.push(type: :user_message, content: content)
    end

    def wait_for_response
      loop do
        drain_output_queue
        render
        render_input_zone(@status.pending? || @status.streaming? ? 'thinking...' : prompt_text)
        break unless @status.pending? || @status.streaming?

        sleep 0.03
      end

      drain_output_queue
      render
      render_input_zone(prompt_text)
    end

    def shutdown
      @shutdown = true
      restore_completion
      shutdown_session
      print "\e[?25h"
      puts
    rescue StandardError
      # Shutdown should not raise into the shell.
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
      case msg[:type]
      when :tool_call
        start_tool_status(msg[:name])
      when :tool_result, :stream_end, :error
        clear_tool_status
      end
    end

    def start_session(agent_name)
      agent = resolve_agent(agent_name)
      @agent = agent
      @model = agent.model
      @system_prompt = agent.system_prompt
      @status = ChatBackend::Status.new
      @transcript = ChatBackend::Transcript.new
      @input_queue = Queue.new
      @output_queue = Queue.new

      session_config = ChatBackend::SessionConfig.new(
        input_queue: @input_queue,
        output_queue: @output_queue,
        api_key: @api_key,
        agent: agent,
        response_sync: @status,
        llm: RubyLLM
      )
      @session_thread = ChatBackend::SessionThread.new(session_config)
    end

    def select_agent(agent_name)
      agent_name = agent_name.to_s.strip
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

    def shutdown_session
      return unless @session_thread

      @input_queue.push(type: :shutdown)
      @session_thread.join
    rescue StandardError
      nil
    end

    def render
      rows, cols = terminal_size
      lines = build_screen_lines(rows, cols)

      print "\e[2J\e[H"
      lines.each do |entry|
        print render_entry(entry, cols)
        print "\n"
      end
    rescue StandardError
      # Rendering should fail closed, not crash the chat loop.
    end

    def render_input_zone(prompt)
      rows, cols = terminal_size
      return if rows <= 0 || cols <= 0

      status_line = prompt
      print "\e[#{rows - 1};1H"
      print "\e[K"
      print truncate_to_width(status_line, cols)
      $stdout.flush
    rescue StandardError
      # Input-zone rendering is best-effort.
    end

    def prompt_text
      '> '
    end

    def build_screen_lines(rows, cols)
      content_height = [rows - 2, 1].max
      header = header_line(cols)
      transcript = @transcript.window_line_entries(cols, height: [content_height - 1, 0].max)
      visible_lines = [{ role: :header, text: header }, *transcript]
      separator = '-' * [cols, 0].max
      [*visible_lines, { role: :separator, text: separator }]
    end

    def render_entry(entry, cols)
      text = truncate_to_width(entry[:text], cols)

      case entry[:role]
      when :info
        "\e[2m#{text}\e[0m"
      else
        text
      end
    end

    def header_line(cols)
      agent_state = "agent: #{@agent&.label || @agent_name}"
      parts = ["RubyLLM Chat", agent_state, "model: #{@model}", "tools: #{tool_count}", "status: #{status_code}"]
      parts << @notice_message if @notice_message
      truncate_to_width(parts.join(' | '), cols)
    end

    def response_pending?
      @status.pending? || @status.streaming?
    end

    def terminal_size
      if IO.respond_to?(:console) && (console = IO.console)
        rows, cols = console.winsize
        rows = 24 if rows.nil? || rows <= 0
        cols = 80 if cols.nil? || cols <= 0
      else
        rows = ENV.fetch('LINES', 24).to_i
        cols = ENV.fetch('COLUMNS', 80).to_i
        rows = 24 if rows <= 0
        cols = 80 if cols <= 0
      end
      [rows, cols]
    rescue StandardError
      [24, 80]
    end

    def load_history_into_reline
      @history_store.each do |line|
        Reline::HISTORY.push(line)
      end
    rescue StandardError
      # History is best-effort only.
    end

    def load_system_prompt
      @agent&.system_prompt
    end

    def install_completion
      @previous_completion_proc = Reline.completion_proc
      @previous_completion_append_character = Reline.completion_append_character
      Reline.completion_proc = method(:reline_completion_candidates)
      Reline.completion_append_character = nil
    rescue StandardError
      # Completion is a best-effort enhancement.
    end

    def restore_completion
      Reline.completion_proc = @previous_completion_proc
      Reline.completion_append_character = @previous_completion_append_character
    rescue StandardError
      # Resetting completion should not break shutdown.
    end

    def reline_completion_candidates
      command_completion_candidates(
        buffer: Reline.line_buffer,
        cursor: Reline.point,
        agent_names: @agent_registry.names
      )
    rescue StandardError
      []
    end
  end
end
