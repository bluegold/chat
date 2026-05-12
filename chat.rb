#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thread'
require 'io/console'
require 'reline'
require_relative 'chat_backend'

Thread.report_on_exception = true

class ChatCLI
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
    @response_sync = ChatBackend::ResponseSync.new
    @transcript = []

    load_history

    @session_thread = ChatBackend::SessionThread.new(@input_queue, @output_queue, api_key, model, @system_prompt, @response_sync)
  end

  def run
    setup_terminal
    main_loop
  ensure
    shutdown
  end

  private

  def setup_terminal
    STDOUT.sync = true
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
    add_to_history(content)
    @transcript << { role: :user, content: content }
    @response_sync.expect_response
    @input_queue.push(type: :user_message, content: content)
  end

  def wait_for_response
    loop do
      drain_output_queue
      render
      render_input_zone(@response_sync.pending? || @response_sync.streaming? ? 'thinking...' : prompt_text)
      break unless @response_sync.pending? || @response_sync.streaming?

      sleep 0.03
    end

    drain_output_queue
    render
    render_input_zone(prompt_text)
  end

  def shutdown
    @shutdown = true
    save_history
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
    case msg[:type]
    when :stream_start
      @transcript << { role: :assistant, content: +' ' }
      @transcript[-1][:content].clear
    when :stream_chunk
      append_assistant_chunk(msg[:content])
    when :stream_end
      @response_sync.end_response
    when :system_message
      @transcript << { role: :system, content: msg[:content].to_s }
    when :error
      @transcript << { role: :error, content: msg[:message].to_s }
      @response_sync.end_response
    end
  end

  def append_assistant_chunk(content)
    text = content.to_s
    return if text.empty?

    if @transcript.empty? || @transcript[-1][:role] != :assistant
      @transcript << { role: :assistant, content: +'' }
    end

    @transcript[-1][:content] << text
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
    transcript_lines = transcript_lines(@transcript, cols)
    visible_lines = [header, *transcript_lines].last([content_height - 1, 0].max)
    separator = '-' * [cols, 0].max
    [*visible_lines, separator]
  end

  def header_line(cols)
    status = @response_sync.pending? || @response_sync.streaming? ? 'thinking...' : 'ready'
    prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
    truncate_to_width("RubyLLM Chat | model: #{@model} | #{status} | #{prompt_state}", cols)
  end

  def terminal_size
    if IO.respond_to?(:console) && (console = IO.console)
      rows, cols = console.winsize
      rows = 24 if rows.nil? || rows <= 0
      cols = 80 if cols.nil? || cols <= 0
      [rows, cols]
    else
      rows = ENV.fetch('LINES', 24).to_i
      cols = ENV.fetch('COLUMNS', 80).to_i
      rows = 24 if rows <= 0
      cols = 80 if cols <= 0
      [rows, cols]
    end
  rescue StandardError
    [24, 80]
  end

  def load_history
    return unless File.exist?(HISTORY_FILE)

    File.readlines(HISTORY_FILE, chomp: true).each do |line|
      next if line.empty?

      Reline::HISTORY.push(line)
    end
  rescue StandardError
    # History is best-effort only.
  end

  def add_to_history(input)
    Reline::HISTORY.push(input)
  end

  def save_history
    history = Reline::HISTORY.to_a.last(MAX_HISTORY)
    File.write(HISTORY_FILE, history.join("\n"))
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

if __FILE__ == $PROGRAM_NAME
  api_key = ENV['OPENAI_API_KEY'] || ENV['ZAI_API_KEY']
  if api_key.nil? || api_key.empty?
    STDERR.puts 'Error: OPENAI_API_KEY environment variable is not set'
    exit 1
  end

  model = ENV.fetch('OPENAI_MODEL', 'gpt-4o-mini')
  cli = ChatCLI.new(api_key, model)
  cli.run
end
