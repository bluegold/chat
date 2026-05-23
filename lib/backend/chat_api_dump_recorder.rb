# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module ChatBackend
  module ApiDumpRecorder
    THREAD_KEY = :chat_api_dump_path
    SEQUENCE_KEY = :chat_api_dump_sequence
    BOUNDARY_LINE = '=' * 80
    SENSITIVE_HEADERS = %w[
      authorization
      proxy-authorization
      api-key
      x-api-key
    ].freeze

    module_function

    def activate(path)
      previous_path = Thread.current[THREAD_KEY]
      previous_sequence = Thread.current[SEQUENCE_KEY]
      Thread.current[THREAD_KEY] = path
      Thread.current[SEQUENCE_KEY] = 0
      yield
    ensure
      Thread.current[THREAD_KEY] = previous_path
      Thread.current[SEQUENCE_KEY] = previous_sequence
    end

    def current_path
      Thread.current[THREAD_KEY]
    end

    def current_sequence
      Thread.current[SEQUENCE_KEY]
    end

    def enabled?
      !current_path.to_s.strip.empty?
    end

    def write_start_marker(path, agent: nil, model: nil)
      write_block(path) do |file|
        write_boundary(file)
        file.puts 'api_dump_start'
        file.puts "timestamp: #{Time.now.iso8601}"
        file.puts "agent: #{agent}" if agent
        file.puts "model: #{model}" if model
        file.puts "path: #{path}"
        write_boundary(file)
        file.puts
      end
    end

    def next_sequence
      sequence = Thread.current[SEQUENCE_KEY].to_i + 1
      Thread.current[SEQUENCE_KEY] = sequence
      sequence
    end

    def record_request(sequence:, method:, url:, request_body:, request_headers:)
      write_block(current_path) do |file|
        write_boundary(file)
        file.puts "request ##{sequence}"
        file.puts "timestamp: #{Time.now.iso8601}"
        file.puts "method: #{method.to_s.upcase}"
        file.puts "url: #{url}"
        write_section(file, 'headers', redact_headers(request_headers || {}))
        write_section(file, 'body', request_body)
        file.puts
      end
    end

    def record_response_summary(sequence:, response: nil, assistant_text: nil, error: nil)
      summary = summarize_response(response, assistant_text:, error:)

      write_block(current_path) do |file|
        write_boundary(file)
        file.puts "response ##{sequence}"
        file.puts "timestamp: #{Time.now.iso8601}"
        write_section(file, 'summary', summary)
        file.puts
      end
    end

    def write_block(path)
      return if path.to_s.strip.empty?

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'a') do |file|
        yield(file)
      end
    rescue StandardError => e
      warn "Failed to write api dump: #{e.message}"
    end

    def write_boundary(file)
      file.puts BOUNDARY_LINE
    end

    def write_section(file, label, value)
      file.puts "#{label}:"
      format_lines(value).each do |line|
        file.puts "  #{line}"
      end
    end

    def format_lines(value)
      normalized = normalize_value(value)

      case normalized
      when nil
        ['(none)']
      when String
        return ['(empty)'] if normalized.empty?

        pretty_json_lines(normalized) || normalized.lines(chomp: true)
      when Array, Hash
        JSON.pretty_generate(normalized).lines(chomp: true)
      else
        text = normalized.to_s
        return ['(empty)'] if text.empty?

        text.lines(chomp: true)
      end
    end

    def pretty_json_lines(text)
      parsed = JSON.parse(text)
      JSON.pretty_generate(parsed).lines(chomp: true)
    rescue JSON::ParserError, TypeError
      nil
    end

    def redact_headers(headers)
      headers.each_with_object({}) do |(key, value), result|
        result[key.to_s] = if sensitive_header?(key)
                             '[REDACTED]'
                           else
                             normalize_value(value)
                           end
      end
    end

    def write_event(event)
      # Kept for backward compatibility if other callers still use it.
      path = current_path
      return if path.to_s.strip.empty?

      write_block(path) do |file|
        write_boundary(file)
        file.puts JSON.pretty_generate(event.merge(timestamp: Time.now.iso8601))
        write_boundary(file)
        file.puts
      end
    end

    def summarize_response(response, assistant_text:, error:)
      return {
        'kind' => 'error',
        'error' => error_payload(error)
      } if error

      message = response
      has_tool_calls = message.respond_to?(:tool_call?) && message.tool_call?
      content_text = assistant_text.nil? ? extract_response_content(message) : assistant_text.to_s

      summary = {
        'kind' => has_tool_calls ? 'tool_call' : 'text',
        'has_content' => !content_text.to_s.strip.empty?,
        'content_length' => content_text.to_s.length
      }

      if has_tool_calls
        tool_calls = message.respond_to?(:tool_calls) ? message.tool_calls : nil
        summary['tool_calls'] = summarize_tool_calls(tool_calls)
      end

      summary
    end

    def summarize_tool_calls(tool_calls)
      return [] unless tool_calls.respond_to?(:each_value)

      tool_calls.each_value.map do |tool_call|
        {
          'name' => tool_call.name.to_s,
          'arguments' => normalize_value(tool_call.arguments)
        }
      end
    end

    def extract_response_content(message)
      return '' unless message
      return message.content.to_s if message.respond_to?(:content)

      message.to_s
    end

    def sensitive_header?(key)
      SENSITIVE_HEADERS.include?(key.to_s.downcase)
    end

    def normalize_value(value)
      case value
      when nil, true, false, Numeric, String
        value
      when Symbol
        value.to_s
      when Array
        value.map { |item| normalize_value(item) }
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s] = normalize_value(item)
        end
      else
        if value.respond_to?(:to_hash)
          normalize_value(value.to_hash)
        elsif value.respond_to?(:to_h)
          normalize_value(value.to_h)
        elsif value.respond_to?(:to_str)
          value.to_str
        else
          value.to_s
        end
      end
    end

    def error_payload(error)
      return nil unless error

      {
        class: error.class.name,
        message: error.message
      }
    end
  end
end

module ChatBackend
  module RubyLLMApiDumpCapture
    def post(url, payload, &block)
      sequence = ChatBackend::ApiDumpRecorder.next_sequence
      request_headers = {}
      request_headers = payload.is_a?(Hash) ? payload[:headers] || payload['headers'] || {} : {}
      ChatBackend::ApiDumpRecorder.record_request(
        sequence: sequence,
        method: :post,
        url: url,
        request_body: payload.is_a?(Hash) ? payload[:body] || payload['body'] || payload : payload,
        request_headers: request_headers
      )
      super
    end

    def get(url, &block)
      sequence = ChatBackend::ApiDumpRecorder.next_sequence
      ChatBackend::ApiDumpRecorder.record_request(
        sequence: sequence,
        method: :get,
        url: url,
        request_body: nil,
        request_headers: {}
      )
      super
    end
  end
end

RubyLLM::Connection.prepend(ChatBackend::RubyLLMApiDumpCapture) unless RubyLLM::Connection < ChatBackend::RubyLLMApiDumpCapture
