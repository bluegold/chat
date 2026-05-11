#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thread'
require 'ruby_llm'
require 'reline'

Thread.report_on_exception = true

# Sync mechanism to wait for response completion
class ResponseSync
  def initialize
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @expecting_response = false
    @responding = false
    @displaying = false
  end

  def expect_response
    @mutex.synchronize do
      @expecting_response = true
      @responding = false
      @displaying = false
    end
  end

  def start_response
    @mutex.synchronize do
      @responding = true
      @displaying = true
      @condition.broadcast
    end
  end

  def end_response
    @mutex.synchronize do
      @responding = false
      @expecting_response = false
      @condition.broadcast
    end
  end

  def end_display
    @mutex.synchronize do
      @displaying = false
      @condition.broadcast
    end
  end

  def wait_for_completion
    @mutex.synchronize do
      @condition.wait(@mutex) until !@expecting_response || (@responding == false && @expecting_response == false)
    end
  end

  def wait_for_display_complete
    @mutex.synchronize do
      @condition.wait(@mutex) until @displaying == false
    end
  end
end

class ChatCLI
  HISTORY_FILE = File.expand_path('.chat_history', Dir.home)

  def initialize(api_key, model = 'gpt-4o-mini')
    @api_key = api_key
    @model = model
    @input_queue = Queue.new
    @output_queue = Queue.new
    @shutdown = false
    @system_prompt = load_system_prompt
    @response_sync = ResponseSync.new
    @has_sent_message = false

    load_history

    @session_thread = SessionThread.new(@input_queue, @output_queue, api_key, model, @system_prompt, @response_sync)
    @output_thread = OutputThread.new(@output_queue, @response_sync)
  end

  def run
    main_loop
    shutdown
  end

  private

  def main_loop
    until @shutdown
      input = read_input
      break if input.nil? || input == '/exit'

      next if input.empty?

      add_to_history(input)
      @response_sync.expect_response  # Mark that we're expecting a response
      send_to_session(input)
      
      # Wait for response and display to complete
      @response_sync.wait_for_completion
      @response_sync.wait_for_display_complete
    end
  end

  def send_to_session(content)
    @output_queue.push(type: :system_message, content: "You: #{content}")
    @input_queue.push(type: :user_message, content: content)
  end

  def shutdown
    @shutdown = true
    save_history
    @input_queue.push(type: :shutdown)
    @session_thread.join
    @output_queue.push(type: :shutdown)
    @output_thread.join
    puts 'Goodbye!'
  end

  def read_input
    Reline.readline('> ', false)
  end

  def load_history
    return unless File.exist?(HISTORY_FILE)

    File.readlines(HISTORY_FILE, chomp: true).each do |line|
      Reline::HISTORY.push(line) unless line.empty?
    end
  end

  def add_to_history(input)
    Reline::HISTORY.push(input)
  end

  def save_history
    history = Reline::HISTORY.to_a.last(1000) # Keep last 1000 entries
    File.write(HISTORY_FILE, history.join("\n"))
  end

  def load_system_prompt
    system_prompt_file = File.join(Dir.pwd, '.system_prompt')
    if File.exist?(system_prompt_file)
      File.read(system_prompt_file)
    else
      nil
    end
  end
end

class SessionThread
  def initialize(input_queue, output_queue, api_key, model, system_prompt = nil, response_sync = nil)
    @input_queue = input_queue
    @output_queue = output_queue
    @api_key = api_key
    @model = model
    @system_prompt = system_prompt
    @response_sync = response_sync
    @history = []
    @streaming = true

    RubyLLM.configure do |config|
      config.openai_api_key = api_key
      config.default_model = model
    end

    @thread = Thread.new { run }
  end

  def join
    @thread.join
  end

  private

  def run
    loop do
      msg = @input_queue.pop
      break if msg[:type] == :shutdown

      begin
        case msg[:type]
        when :user_message
          handle_user_message(msg[:content])
        end
      rescue => e
        @output_queue.push(type: :error, message: "#{e.class}: #{e.message}\n  #{e.backtrace.first(5).join("\n  ")}")
      end
    end
  end

  def handle_user_message(content)
    chat = RubyLLM.chat
    
    # Set system prompt if available
    chat.with_instructions(@system_prompt) if @system_prompt
    
    # Add previous messages to chat context
    @history.each do |msg|
      if msg[:role] == 'user'
        chat.say(msg[:content])
      elsif msg[:role] == 'assistant'
        chat.add_message(role: :assistant, content: msg[:content])
      end
    end
    
    # Start streaming response
    @response_sync.start_response if @response_sync
    @output_queue.push(type: :stream_start)
    full_response = ''
    
    # Streaming response with block
    chat.ask(content) do |chunk|
      chunk_content = case
                     when chunk.is_a?(String)
                       chunk
                     when chunk.respond_to?(:content)
                       chunk.content
                     when chunk.respond_to?(:text)
                       chunk.text
                     else
                       chunk.to_s rescue ''
                     end
      # Skip nil/empty content
      next if chunk_content.nil? || chunk_content.empty?
      full_response += chunk_content
      @output_queue.push(type: :stream_chunk, content: chunk_content)
    end
    
    @output_queue.push(type: :stream_end)
    @response_sync.end_response if @response_sync
    @history << { role: 'user', content: content }
    @history << { role: 'assistant', content: full_response }
  end
end

class OutputThread
  def initialize(output_queue, response_sync = nil)
    @output_queue = output_queue
    @response_sync = response_sync
    @current_response = ''
    @in_stream = false
    @thread = Thread.new { run }
  end

  def join
    @thread.join
  end

  private

  def run
    loop do
      msg = @output_queue.pop
      break if msg[:type] == :shutdown

      begin
        case msg[:type]
        when :chat_response
          print_chat(msg[:content])
        when :stream_start
          start_stream
        when :stream_chunk
          print_stream_chunk(msg[:content])
        when :stream_end
          end_stream
        when :system_message
          print_system(msg[:content])
        when :error
          print_error(msg[:content])
        end
      rescue => e
        STDERR.puts "Output error: #{e.class}: #{e.message}\n  #{e.backtrace.first(5).join("\n  ")}"
      end
    end
  end

  def start_stream
    @in_stream = true
    @current_response = ''
    print "\e[32mAssistant\e[0m: "
    $stdout.flush
  end

  def print_stream_chunk(content)
    return if content.nil? || content.empty?
    print content
    $stdout.flush
    @current_response += content
  end

  def end_stream
    puts
    @in_stream = false
    @response_sync.end_display if @response_sync
  end

  def print_chat(content)
    puts "\e[32mAssistant\e[0m: #{content}"
  end

  def print_system(content)
    puts "\e[33mSystem\e[0m: #{content}"
  end

  def print_error(content)
    puts "\e[31mError\e[0m: #{content}"
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
