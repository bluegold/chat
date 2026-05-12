# frozen_string_literal: true

require 'io/console'
require 'reline'
require_relative 'chat_backend'
require_relative 'chat_agent_controls'
require_relative 'chat_command_completion'
require_relative 'chat_tool_tracking'
require_relative 'chat_session_status'
require_relative 'chat_session_info'

Thread.report_on_exception = true

module ChatApp
  class RelineUI
    include ChatBackend::TextLayout
    include AgentControls
    include CommandCompletion
    include ToolTracking
    include SessionStatus
    include SessionInfo

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    def initialize(api_key, agent_registry:, agent_name:)
      @api_key = api_key
      @agent_registry = agent_registry
      @agent_name = agent_name.to_s
      @debug_enabled = env_truthy?(ENV.fetch('CHAT_DEBUG', nil)) || env_truthy?(ENV.fetch('CHAT_RELINE_DEBUG', nil))
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
    end

    def main_loop
      until @shutdown
        drain_output_queue

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
      input = Reline.readline(prompt, false)
      debug_log("read input: #{input.nil? ? 'nil' : input.inspect}")
      input
    rescue Interrupt
      nil
    end

    def submit_input(content)
      debug_log("submit input: #{content.inspect}")

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
      debug_log('waiting for response')
      loop do
        drain_output_queue
        break unless @status.pending? || @status.streaming?

        sleep 0.03
      end

      drain_output_queue
      debug_log('response completed')
    end

    def shutdown
      @shutdown = true
      restore_completion
      shutdown_session
    rescue StandardError => e
      debug_exception('shutdown', e)
    end

    def drain_output_queue
      loop do
        msg = @output_queue.pop(true)
        handle_output_message(msg)
      rescue ThreadError
        break
      rescue StandardError => e
        debug_exception('drain_output_queue', e)
        break
      end
    end

    def handle_output_message(msg)
      debug_log("output: #{msg[:type]}")
      @transcript.apply_output_message(msg)
      case msg[:type]
      when :tool_call
        start_tool_status(msg[:name])
        puts
        puts tool_call_text(msg[:name], msg[:arguments])
      when :tool_result, :stream_end, :error
        clear_tool_status
        print_completed_output(msg)
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
      debug_log("session started: #{agent.name}")
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
    rescue StandardError => e
      debug_exception('shutdown_session', e)
      nil
    end

    def prompt_text
      '> '
    end

    def env_truthy?(value)
      case value.to_s.strip.downcase
      when '1', 'true', 'yes', 'on'
        true
      else
        false
      end
    end

    def load_history_into_reline
      entries = @history_store.to_a
      Reline::HISTORY.clear
      Reline::HISTORY.concat(entries)
      debug_log("history loaded: #{Reline::HISTORY.size}")
    rescue StandardError => e
      debug_exception('load_history_into_reline', e)
    end

    def print_completed_output(msg)
      case msg[:type]
      when :stream_end
        assistant = @transcript.messages.reverse.find { |message| message[:role] == :assistant && !message[:content].to_s.empty? }
        return unless assistant

        puts
        assistant[:content].each_line(chomp: true) do |line|
          puts line
        end
        puts
      when :error
        puts
        puts "Error: #{msg[:message]}"
        puts
      end
    end

    def load_system_prompt
      @agent&.system_prompt
    end

    def install_completion
      @previous_completion_proc = Reline.completion_proc
      @previous_completion_append_character = Reline.completion_append_character
      Reline.completion_proc = method(:reline_completion_candidates)
      Reline.completion_append_character = nil
      debug_log('completion installed')
    rescue StandardError => e
      debug_exception('install_completion', e)
    end

    def restore_completion
      Reline.completion_proc = @previous_completion_proc
      Reline.completion_append_character = @previous_completion_append_character
      debug_log('completion restored')
    rescue StandardError => e
      debug_exception('restore_completion', e)
    end

    def reline_completion_candidates
      command_completion_candidates(
        buffer: Reline.line_buffer,
        cursor: Reline.point,
        agent_names: @agent_registry.names
      )
    rescue StandardError => e
      debug_exception('reline_completion_candidates', e)
      []
    end

    def debug_enabled?
      @debug_enabled
    end

    def debug_log(message)
      return unless debug_enabled?

      warn("[reline-debug] #{message}")
    rescue StandardError
      nil
    end

    def debug_exception(context, exception)
      return unless debug_enabled?

      debug_log("#{context}: #{exception.class}: #{exception.message}")
      Array(exception.backtrace).first(8).each do |line|
        warn("[reline-debug]   #{line}")
      end
    rescue StandardError
      nil
    end
  end
end
