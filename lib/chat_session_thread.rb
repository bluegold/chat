# frozen_string_literal: true

require 'ruby_llm'

module ChatBackend
  class SessionThread
    attr_reader :thread

    def initialize(config)
      @input_queue = config.input_queue
      @output_queue = config.output_queue
      @agent = config.agent
      @system_prompt = config.system_prompt
      @tool_names = config.tool_names
      @response_sync = config.response_sync
      @history = []
      @llm = config.llm_client
      @archive_base_dir = config.archive_base_dir
      @summarizer_agent = config.summarizer_agent
      @archive_path = nil

      @llm.configure do |llm_config|
        llm_config.openai_api_key = config.api_key
        llm_config.default_model = config.model
        llm_config.temperature = config.temperature if config.temperature && llm_config.respond_to?(:temperature=)
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
      chat = build_chat(content)
      @history << { role: :user, content: content }

      ensure_archive_path(content)
      write_log_event(role: :user, content: content)

      @response_sync&.start_response
      @output_queue.push(type: :stream_start)

      assistant_text = generate_and_stream_response(chat, content)

      @history << { role: :assistant, content: assistant_text } unless assistant_text.empty?
      write_log_event(role: :assistant, content: assistant_text) unless assistant_text.empty?

      @output_queue.push(type: :stream_end)
      @response_sync&.end_response
    rescue StandardError => e
      @output_queue.push(type: :error, message: format_error(e))
      @output_queue.push(type: :stream_end)
      @response_sync&.end_response
    end

    def generate_and_stream_response(chat, content)
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
      assistant_text
    end

    def build_chat(content)
      chat = @llm.chat
      chat.with_instructions(@system_prompt) if @system_prompt && !@system_prompt.strip.empty?
      apply_tools(chat, content)
      install_tool_callbacks(chat)

      @history.each do |message|
        chat.add_message(role: message[:role], content: message[:content])
      end

      chat
    end

    def apply_tools(chat, content)
      tool_classes = if @agent.respond_to?(:tool_classes_for_input)
                       @agent.tool_classes_for_input(content)
                     else
                       @tool_names.map { |tool_name| resolve_tool(tool_name) }.compact
                     end
      return chat unless tool_classes && !tool_classes.empty?

      tool_classes.each do |tool_class|
        next unless chat.respond_to?(:with_tool)

        chat = chat.with_tool(tool_class)
      end

      chat
    end

    def install_tool_callbacks(chat)
      return chat unless chat.respond_to?(:before_tool_call) && chat.respond_to?(:after_tool_result)

      current_tool_name = nil
      chat.before_tool_call do |tool_call|
        current_tool_name = tool_call.name.to_s
        @output_queue.push(type: :tool_call, name: current_tool_name, arguments: tool_call.arguments)
        write_log_event(role: :tool_call, name: current_tool_name, arguments: tool_call.arguments)
      end
      chat.after_tool_result do |result|
        @output_queue.push(type: :tool_result, name: current_tool_name.to_s, result: result)
        write_log_event(role: :tool_result, name: current_tool_name.to_s, result: result)
      end
      chat
    end

    def resolve_tool(tool_name)
      ChatBackend.tool_class_for(tool_name)
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
      ["#{error.class}: #{error.message}", *backtrace].join("\n")
    end

    def generate_title(raw_text)
      return default_title(raw_text) unless @summarizer_agent

      begin
        original_model = @agent.model
        original_temp = @agent.temperature

        @llm.configure do |c|
          c.default_model = @summarizer_agent.model
          c.temperature = @summarizer_agent.temperature if @summarizer_agent.temperature && c.respond_to?(:temperature=)
        end

        chat = @llm.chat
        chat.with_instructions(@summarizer_agent.system_prompt)
        response = chat.ask(raw_text[0, 1000])

        title = extract_response_content(response).strip
        title = title.gsub(/[^\p{Alnum}\p{Han}\p{Hiragana}\p{Katakana}_-]/, '_').gsub(/_+$/, '')
        title = 'chat' if title.empty?

        @llm.configure do |c|
          c.default_model = original_model
          c.temperature = original_temp if original_temp && c.respond_to?(:temperature=)
        end
        title[0, 50]
      rescue StandardError => e
        warn "Title generation failed: #{e.message}"
        default_title(raw_text)
      end
    end

    def default_title(raw_text)
      first_line = raw_text.strip.split("\n").first || ''
      safe_subject = first_line.gsub(/[^\p{Alnum}\p{Han}\p{Hiragana}\p{Katakana}_-]/, '_')
      safe_subject = safe_subject[0, 30].gsub(/_+$/, '')
      safe_subject.empty? ? 'chat' : safe_subject
    end

    def ensure_archive_path(first_user_message)
      return if @archive_path || @archive_base_dir.nil?

      raw_text = first_user_message.to_s.strip.split("\n").first
      return if raw_text.nil? || raw_text.empty?

      safe_subject = generate_title(first_user_message.to_s)

      now = Time.now
      dir = File.join(@archive_base_dir, now.strftime('%Y/%m/%d'))

      cwd_name = File.basename(Dir.pwd)
      path = File.join(dir, "#{cwd_name}-#{safe_subject}-#{now.strftime('%H%M%S')}.jsonl")

      require 'fileutils'
      FileUtils.mkdir_p(dir)
      @archive_path = path

      write_log_event(
        event: 'session_start',
        agent: @agent&.name,
        model: @agent&.model,
        cwd: Dir.pwd,
        timestamp: now.iso8601
      )
    end

    def write_log_event(hash)
      return unless @archive_path

      require 'json'
      hash[:timestamp] ||= Time.now.iso8601
      File.write(@archive_path, "#{JSON.generate(hash)}\n", mode: 'a')
    rescue StandardError => e
      warn "Failed to write archive log: #{e.message}"
    end
  end
end
