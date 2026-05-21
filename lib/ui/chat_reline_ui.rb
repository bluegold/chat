# frozen_string_literal: true

require 'io/console'
require 'reline'
require 'forwardable'
require_relative '../backend/chat_backend'
require_relative 'chat_command_parser'
require_relative 'chat_command_completer'
require_relative '../tools/chat_tool_tracking'
require_relative 'chat_status_line_formatter'
require_relative '../tools/chat_tool_hints'
require_relative 'chat_session_info'
require_relative '../backend/chat_session_controller'

Thread.report_on_exception = true

module ChatApp
  class RelineUI
    extend Forwardable

    include ChatBackend::TextLayout
    include ToolTracking
    include SessionInfo
    include ToolHints

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    def_delegators :@session_controller, :status, :transcript, :session_thread,
                   :input_queue, :output_queue, :model, :system_prompt, :agent,
                   :status_code, :response_pending?

    def initialize(api_key, agent_registry:, agent_name:)
      @api_key = api_key
      @agent_registry = agent_registry
      @agent_name = agent_name.to_s
      @command_parser = CommandParser.new(@agent_registry)
      @command_completer = CommandCompleter.new(@agent_registry.names)
      @debug_enabled = env_truthy?(ENV.fetch('CHAT_DEBUG', nil)) || env_truthy?(ENV.fetch('CHAT_RELINE_DEBUG', nil))
      @shutdown = false
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      @session_controller = SessionController.new(api_key: @api_key, agent_registry: @agent_registry)
      load_history_into_reline
      @session_controller.start_session(@agent_name)
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
        break if input.nil? || @command_parser.exit_command?(input)
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

      if @command_parser.agent_command?(content)
        agent_name = @command_parser.agent_name_from_command(content)
        select_agent(agent_name)
        return
      end

      if @command_parser.session_info_command?(content)
        transcript.info_message(session_info_text)
        @notice_message = nil
        return
      end

      @history_store.add(content)
      Reline::HISTORY.push(content)
      transcript.user_message(content)
      @tool_hint_features = tool_hints_for(content)
      @session_controller.send_message(content)
    end

    def wait_for_response
      debug_log('waiting for response')
      loop do
        drain_output_queue
        break unless status&.pending? || status&.streaming?

        sleep 0.03
      end

      drain_output_queue
      debug_log('response completed')
    end

    def shutdown
      @shutdown = true
      restore_completion
      @session_controller.shutdown_session
    rescue StandardError => e
      debug_exception('shutdown', e)
    end

    def drain_output_queue
      loop do
        msg = output_queue.pop(true)
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
      transcript.apply_output_message(msg)
      case msg[:type]
      when :tool_call
        start_tool_status(msg[:name])
        puts
        puts tool_call_text(msg[:name], msg[:arguments])
      when :stream_end, :error
        clear_tool_status
        @tool_hint_features = nil
        print_completed_output(msg)
      when :tool_result
        print_completed_output(msg)
      end
    end

    def select_agent(agent_name)
      agent_name = agent_name.to_s.strip
      return if agent_name.empty?

      new_agent = @session_controller.select_agent(agent_name)
      unless new_agent
        @notice_message = "unknown agent: #{agent_name}"
        return
      end

      @agent_name = new_agent.name
      @notice_message = "switched to #{new_agent.name}"
    end

    def prompt_text
      '> '
    end

    def current_input_text
      Reline.line_buffer.to_s
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
        assistant = transcript.messages.rfind { |message| message[:role] == :assistant && !message[:content].to_s.empty? }
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
      agent&.system_prompt
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
      @command_completer.candidates(
        Reline.line_buffer,
        Reline.point
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
