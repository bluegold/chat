# frozen_string_literal: true

require 'thread'
require 'ruby_llm'

module ChatBackend
  class ResponseSync
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @expecting_response = false
      @responding = false
    end

    def expect_response
      @mutex.synchronize do
        @expecting_response = true
        @responding = false
      end
    end

    def start_response
      @mutex.synchronize do
        @responding = true
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

    def pending?
      @mutex.synchronize { @expecting_response }
    end

    def streaming?
      @mutex.synchronize { @responding }
    end
  end

  module TextLayout
    def transcript_lines(messages, cols)
      Array(messages).flat_map { |message| format_message_lines(message, cols) }
    end

    def format_message_lines(message, cols)
      label = case message[:role]
              when :user then 'You'
              when :assistant then 'Assistant'
              when :system then 'System'
              when :error then 'Error'
              else 'Message'
              end

      content_lines = wrap_text(message[:content].to_s, cols)
      content_lines = [''] if content_lines.empty?

      ["#{label}:", *content_lines, '']
    end

    def wrap_text(text, width)
      width = [width, 1].max
      lines = []
      current = +''
      current_width = 0

      text.to_s.each_char do |char|
        if char == "\n"
          lines << current
          current = +''
          current_width = 0
          next
        end

        char_width = display_width(char)
        if current_width.positive? && current_width + char_width > width
          lines << current
          current = +''
          current_width = 0
        end

        current << char
        current_width += char_width
      end

      lines << current unless current.empty?
      lines.empty? ? [''] : lines
    end

    def truncate_to_width(text, width)
      return '' if width <= 0

      result = +''
      current_width = 0

      text.to_s.each_char do |char|
        char_width = display_width(char)
        break if current_width + char_width > width

        result << char
        current_width += char_width
      end

      result
    end

    def display_width(text)
      text.to_s.each_char.sum { |char| char_width(char) }
    end

    def char_width(char)
      codepoint = char.ord
      return 0 if codepoint < 32 || (127..159).cover?(codepoint)
      return 2 if char.match?(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u1100-\u115F\u2329\u232A\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE10-\uFE19\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/u)

      1
    end
  end

  class SessionThread
    attr_reader :thread

    def initialize(input_queue, output_queue, api_key, model, system_prompt = nil, response_sync = nil, llm: RubyLLM)
      @input_queue = input_queue
      @output_queue = output_queue
      @system_prompt = system_prompt
      @response_sync = response_sync
      @history = []
      @llm = llm

      @llm.configure do |config|
        config.openai_api_key = api_key
        config.default_model = model
      end

      @thread = Thread.new { run }
    end

    def join(timeout = nil)
      @thread.join(timeout)
    end

    def alive?
      @thread.alive?
    end

    def kill
      @thread.kill
    end

    private

    def run
      loop do
        msg = @input_queue.pop
        break if msg[:type] == :shutdown

        case msg[:type]
        when :user_message
          handle_user_message(msg[:content])
        end
      rescue StandardError => e
        @output_queue.push(type: :error, message: format_error(e))
        @output_queue.push(type: :stream_end)
        @response_sync&.end_response
      end
    end

    def handle_user_message(content)
      chat = build_chat
      @history << { role: :user, content: content }

      @response_sync&.start_response
      @output_queue.push(type: :stream_start)

      full_response = +''
      assistant_started = false

      response = chat.ask(content) do |chunk|
        chunk_content = normalize_chunk(chunk)
        next if chunk_content.empty?

        full_response << chunk_content
        unless assistant_started
          assistant_started = true
          @output_queue.push(type: :assistant_start)
        end
        @output_queue.push(type: :stream_chunk, content: chunk_content)
      end

      assistant_text = full_response.empty? ? extract_response_content(response) : full_response
      if !assistant_started && !assistant_text.empty?
        @output_queue.push(type: :assistant_start)
        @output_queue.push(type: :stream_chunk, content: assistant_text)
      end

      @history << { role: :assistant, content: assistant_text } unless assistant_text.empty?
      @output_queue.push(type: :stream_end)
      @response_sync&.end_response
    rescue StandardError => e
      @output_queue.push(type: :error, message: format_error(e))
      @output_queue.push(type: :stream_end)
      @response_sync&.end_response
    end

    def build_chat
      chat = @llm.chat
      chat.with_instructions(@system_prompt) if @system_prompt && !@system_prompt.strip.empty?

      @history.each do |message|
        chat.add_message(role: message[:role], content: message[:content])
      end

      chat
    end

    def normalize_chunk(chunk)
      case chunk
      when String
        chunk
      else
        if chunk.respond_to?(:content)
          chunk.content.to_s
        elsif chunk.respond_to?(:text)
          chunk.text.to_s
        else
          chunk.to_s
        end
      end
    end

    def extract_response_content(response)
      return '' unless response
      return response.content.to_s if response.respond_to?(:content)

      response.to_s
    end

    def format_error(error)
      backtrace = Array(error.backtrace).first(5)
      [ "#{error.class}: #{error.message}", *backtrace ].join("\n")
    end
  end
end
