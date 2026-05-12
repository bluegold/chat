# frozen_string_literal: true

require 'io/console'
require 'reline'
require_relative 'chat_backend'

Thread.report_on_exception = true

module ChatApp
  class RelineUI
    include ChatBackend::TextLayout

    HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
    MAX_HISTORY = 1000

    def initialize(api_key, model = 'gpt-4o-mini')
      @api_key = api_key
      @model = model
      @input_queue = Queue.new
      @output_queue = Queue.new
      @shutdown = false
      @system_prompt = load_system_prompt
      @status = ChatBackend::Status.new
      @transcript = ChatBackend::Transcript.new
      @history_store = ChatBackend::HistoryStore.new(path: HISTORY_FILE, max_entries: MAX_HISTORY)
      load_history_into_reline

      session_config = ChatBackend::SessionConfig.new(
        input_queue: @input_queue,
        output_queue: @output_queue,
        api_key: api_key,
        model: model,
        system_prompt: @system_prompt,
        response_sync: @status,
        llm: RubyLLM
      )
      @session_thread = ChatBackend::SessionThread.new(session_config)
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
        break if input.nil? || input == '/exit'
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
      @input_queue.push(type: :shutdown)
      @session_thread&.join
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
    end

    def render
      rows, cols = terminal_size
      lines = build_screen_lines(rows, cols)

      print "\e[2J\e[H"
      lines.each do |line|
        puts truncate_to_width(line, cols)
      end
    rescue StandardError
      # Rendering should fail closed, not crash the chat loop.
    end

    def render_input_zone(prompt)
      rows, cols = terminal_size
      return if rows <= 0 || cols <= 0

      status_line = "  #{prompt}"
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
      transcript = @transcript.window(cols, height: [content_height - 1, 0].max)
      visible_lines = [header, *transcript]
      separator = '-' * [cols, 0].max
      [*visible_lines, separator]
    end

    def header_line(cols)
      status = response_pending? ? 'thinking...' : 'ready'
      prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
      truncate_to_width("RubyLLM Chat | model: #{@model} | #{status} | #{prompt_state}", cols)
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
      system_prompt_file = File.join(Dir.pwd, '.system_prompt')
      return nil unless File.exist?(system_prompt_file)

      content = File.read(system_prompt_file)
      content.strip.empty? ? nil : content
    rescue StandardError
      nil
    end
  end
end
