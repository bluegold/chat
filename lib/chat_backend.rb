# frozen_string_literal: true

require 'yaml'
require 'ruby_llm'
require_relative 'chat_local_tools'
require_relative 'chat_memory_tools'
require_relative 'chat_code_execution_tools'

module ChatBackend
  module TextLayout
    def transcript_line_entries(messages, cols)
      Array(messages).flat_map { |message| format_message_line_entries(message, cols) }
    end

    def transcript_lines(messages, cols)
      transcript_line_entries(messages, cols).map { |entry| entry[:text] }
    end

    def format_message_line_entries(message, cols)
      role = message[:role]
      content_lines = wrap_text(message[:content].to_s, cols)
      content_lines = [''] if content_lines.empty?

      case role
      when :user
        [
          { role: :user, text: '' },
          *prefixed_content_lines(content_lines, '> ', role: :user),
          { role: :user, text: '' }
        ]
      when :assistant
        [
          { role: :assistant, text: '' },
          *content_lines.map { |line| { role: :assistant, text: line } },
          { role: :assistant, text: '' }
        ]
      when :system
        [
          { role: :system, text: 'System:' },
          *content_lines.map { |line| { role: :system, text: line } },
          { role: :system, text: '' }
        ]
      when :info
        content_lines.map { |line| { role: :info, text: line } }
      when :error
        [{ role: :error, text: 'Error:' }, *content_lines.map { |line| { role: :error, text: line } }, { role: :error, text: '' }]
      else
        [
          { role: :message, text: 'Message:' },
          *content_lines.map { |line| { role: :message, text: line } },
          { role: :message, text: '' }
        ]
      end
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

    def tool_call_text(tool_name, arguments = nil)
      details = tool_arguments_text(arguments)
      details.empty? ? "Using tool #{tool_name}" : "Using tool #{tool_name}(#{details})"
    end

    def tool_arguments_text(arguments)
      case arguments
      when nil
        ''
      when String
        arguments.strip
      when Hash
        arguments.map { |key, value| "#{key}: #{tool_value_text(value)}" }.join(', ')
      when Array
        arguments.map { |value| tool_value_text(value) }.join(', ')
      else
        arguments.to_s.strip
      end
    end

    def tool_value_text(value)
      case value
      when String
        value.include?("'") ? value.inspect : "'#{value}'"
      when TrueClass, FalseClass, Numeric
        value.to_s
      when Array
        "[#{value.map { |item| tool_value_text(item) }.join(', ')}]"
      when Hash
        "{#{value.map { |key, item| "#{key}: #{tool_value_text(item)}" }.join(', ')}}"
      else
        value.inspect
      end
    end

    def prefixed_content_lines(content_lines, prefix, role:)
      lines = Array(content_lines).dup
      first_line = lines.shift.to_s
      first_line = "#{prefix}#{first_line}"
      [{ role: role, text: first_line }, *lines.map { |line| { role: role, text: line } }]
    end

    def char_width(char)
      codepoint = char.ord
      return 0 if codepoint < 32 || (127..159).cover?(codepoint)
      return 2 if char.match?(
        /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u1100-\u115F\u2329\u232A\u2E80-\uA4CF\uAC00-\uD7A3\
\uF900-\uFAFF\uFE10-\uFE19\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/u
      )

      1
    end
  end

  class Transcript
    include TextLayout

    attr_reader :messages

    def initialize(messages = [])
      @messages = Array(messages).map do |message|
        {
          role: message[:role],
          content: message[:content].to_s
        }
      end
    end

    def user_message(content)
      append_message(:user, content)
    end

    def assistant_start
      return if last_role == :assistant

      append_message(:assistant, +'')
    end

    def assistant_chunk(content)
      text = content.to_s
      return if text.empty?

      assistant_start if last_role != :assistant
      @messages[-1][:content] << text
    end

    def system_message(content)
      append_message(:system, content)
    end

    def info_message(content)
      append_message(:info, content)
    end

    def error_message(content)
      append_message(:error, content)
    end

    def apply_output_message(msg)
      case msg[:type]
      when :stream_start, :assistant_start
        assistant_start
      when :stream_chunk
        assistant_chunk(msg[:content])
      when :system_message
        system_message(msg[:content])
      when :info_message
        info_message(msg[:content])
      when :tool_call
        info_message(tool_call_text(msg[:name], msg[:arguments]))
      when :error
        error_message(msg[:message])
      end
    end

    def lines(cols)
      transcript_lines(@messages, cols)
    end

    def line_entries(cols)
      transcript_line_entries(@messages, cols)
    end

    def window_line_entries(cols, scroll: 0, height: nil)
      entries = line_entries(cols)
      height = height.to_i
      return entries if height <= 0

      max_scroll = [entries.length - height, 0].max
      scroll = scroll.to_i.clamp(0, max_scroll)
      start_index = [entries.length - height - scroll, 0].max
      entries[start_index, height] || []
    end

    def tail_lines(cols, count)
      return [] if count.to_i <= 0

      lines(cols).last(count)
    end

    def window(cols, scroll: 0, height: nil)
      lines = self.lines(cols)
      height = height.to_i
      return lines if height <= 0

      max_scroll = [lines.length - height, 0].max
      scroll = scroll.to_i.clamp(0, max_scroll)
      start_index = [lines.length - height - scroll, 0].max
      lines[start_index, height] || []
    end

    private

    def append_message(role, content)
      @messages << { role: role, content: content.to_s }
    end

    def last_role
      @messages.empty? ? nil : @messages[-1][:role]
    end
  end

  AgentSpec = Data.define(:name, :display_name, :model, :system_prompt, :temperature, :tools) do
    def label
      display_name.to_s.strip.empty? ? name.to_s : display_name.to_s
    end

    def tool_names
      Array(tools).filter_map do |tool|
        if tool.respond_to?(:tool_name) && !tool.tool_name.to_s.strip.empty?
          tool.tool_name.to_s
        elsif tool.respond_to?(:name) && tool.class < RubyLLM::Tool
          tool.name.to_s
        else
          tool.to_s
        end
      end
    end
  end

  class AgentRegistry
    attr_reader :default_agent_name

    def initialize(agents:, default_agent_name:)
      @agents = agents.transform_keys(&:to_s)
      @default_agent_name = default_agent_name.to_s
    end

    def [](name)
      @agents[name.to_s]
    end

    def default_agent
      self[@default_agent_name]
    end

    def names
      @agents.keys.sort
    end

    def empty?
      @agents.empty?
    end

    def self.load(path: default_path, env: ENV)
      if File.exist?(path)
        load_from_file(path)
      else
        fallback_agent = AgentSpec.new(
          name: 'default',
          display_name: nil,
          model: env.fetch('OPENAI_MODEL', 'gpt-4o-mini'),
          system_prompt: load_legacy_system_prompt,
          temperature: nil,
          tools: []
        )
        new(agents: { fallback_agent.name => fallback_agent }, default_agent_name: fallback_agent.name)
      end
    rescue StandardError
      fallback_agent = AgentSpec.new(
        name: 'default',
        display_name: nil,
        model: env.fetch('OPENAI_MODEL', 'gpt-4o-mini'),
        system_prompt: load_legacy_system_prompt,
        temperature: nil,
        tools: []
      )
      new(agents: { fallback_agent.name => fallback_agent }, default_agent_name: fallback_agent.name)
    end

    def self.default_path(env = ENV)
      env.fetch('MYAGENT_CONFIG', File.expand_path('~/.config/myagent.yml'))
    end

    def self.load_from_file(path)
      raw = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true) || {}
      agents = build_agents(raw)
      default_name = normalize_agent_name(fetch_string(raw, 'default_agent') || fetch_string(raw, :default_agent))
      default_name ||= agents.keys.first || 'default'
      new(agents: agents, default_agent_name: default_name)
    end
    private_class_method :load_from_file

    def self.build_agents(raw)
      agent_entries(raw).each_with_object({}) do |entry, memo|
        spec = build_agent_spec(entry)
        memo[spec.name] = spec if spec
      end
    end
    private_class_method :build_agents

    def self.agent_entries(raw)
      entries = fetch_value(raw, 'agents') || fetch_value(raw, :agents)
      entries = fetch_value(raw, 'agent') || fetch_value(raw, :agent) if entries.nil?

      case entries
      when Hash
        entries.map { |name, entry| [name, entry] }
      else
        Array(entries)
      end
    end
    private_class_method :agent_entries

    def self.build_agent_spec(entry)
      if entry.is_a?(Array)
        name, attrs = entry
        return build_agent_spec_from_hash(name, attrs)
      end

      build_agent_spec_from_hash(nil, entry)
    end
    private_class_method :build_agent_spec

    def self.build_agent_spec_from_hash(name, entry)
      return unless entry.is_a?(Hash)

      name = normalize_agent_name(name || fetch_string(entry, 'name') || fetch_string(entry, :name))
      return unless name

      AgentSpec.new(
        name: name,
        display_name: fetch_string(entry, 'display_name') || fetch_string(entry, :display_name),
        model: fetch_string(entry, 'model') || fetch_string(entry, :model) || 'gpt-4o-mini',
        system_prompt: normalize_prompt_text(fetch_value(entry, 'system_prompt') || fetch_value(entry, :system_prompt)),
        temperature: fetch_value(entry, 'temperature') || fetch_value(entry, :temperature),
        tools: Array(fetch_value(entry, 'tools') || fetch_value(entry, :tools))
      )
    end
    private_class_method :build_agent_spec_from_hash

    def self.normalize_agent_name(value)
      name = value.to_s.strip
      name.empty? ? nil : name
    end
    private_class_method :normalize_agent_name

    def self.fetch_value(hash, key)
      hash[key] || hash[key.to_s] || hash[key.to_sym]
    end

    def self.fetch_string(hash, key)
      value = fetch_value(hash, key)
      value&.to_s
    end
    private_class_method :fetch_value, :fetch_string

    def self.normalize_prompt_text(value)
      text = value.to_s
      text.chomp
    end
    private_class_method :normalize_prompt_text

    def self.load_legacy_system_prompt
      system_prompt_file = File.join(Dir.pwd, '.system_prompt')
      return nil unless File.exist?(system_prompt_file)

      content = File.read(system_prompt_file)
      content.strip.empty? ? nil : content.chomp
    rescue StandardError
      nil
    end
    private_class_method :load_legacy_system_prompt
  end

  class HistoryStore
    attr_reader :path, :max_entries

    def initialize(path:, max_entries: 1000)
      @path = path
      @max_entries = max_entries
      @entries = []
      load
    end

    def each = @entries.each

    def to_a
      @entries.dup
    end

    def add(entry)
      text = entry.to_s
      return if text.empty?

      @entries << text
      @entries = @entries.last(@max_entries)
      save
      text
    end

    def empty?
      @entries.empty?
    end

    private

    def load
      return unless File.exist?(@path)

      load_serialized_entries || load_legacy_entries
      @entries = @entries.last(@max_entries)
    rescue StandardError
      @entries = []
    end

    def save
      File.write(@path, YAML.dump(@entries))
    rescue StandardError
      # History is best-effort only.
    end

    def load_serialized_entries
      content = File.read(@path)
      return false unless serialized_history?(content)

      entries = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
      return false unless entries.is_a?(Array)

      entries.each do |entry|
        next if entry.nil?

        @entries << entry.to_s
      end

      true
    rescue StandardError
      false
    end

    def load_legacy_entries
      File.readlines(@path, chomp: true).each do |line|
        next if line.empty?

        @entries << line
      end
    rescue StandardError
      @entries = []
    end

    def serialized_history?(content)
      stripped = content.to_s.lstrip
      stripped.start_with?('---', '!')
    end
  end

  SessionConfig = Data.define(
    :input_queue,
    :output_queue,
    :api_key,
    :agent,
    :response_sync,
    :llm
  ) do
    def llm_client
      llm || RubyLLM
    end

    def model
      agent&.model.to_s
    end

    def system_prompt
      agent&.system_prompt.to_s
    end

    def temperature
      agent&.temperature
    end

    def tool_names
      agent&.tool_names || []
    end
  end

  class Status
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

  ResponseSync = Status

  class SessionThread
    attr_reader :thread

    def initialize(config)
      @input_queue = config.input_queue
      @output_queue = config.output_queue
      @system_prompt = config.system_prompt
      @tool_names = config.tool_names
      @response_sync = config.response_sync
      @history = []
      @llm = config.llm_client

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
      apply_tools(chat)
      install_tool_callbacks(chat)

      @history.each do |message|
        chat.add_message(role: message[:role], content: message[:content])
      end

      chat
    end

    def apply_tools(chat)
      return chat unless @tool_names && !@tool_names.empty?

      @tool_names.each do |tool_name|
        next unless chat.respond_to?(:with_tool)

        tool = resolve_tool(tool_name)
        chat = chat.with_tool(tool) if tool
      end

      chat
    end

    def install_tool_callbacks(chat)
      return chat unless chat.respond_to?(:before_tool_call) && chat.respond_to?(:after_tool_result)

      current_tool_name = nil
      chat.before_tool_call do |tool_call|
        current_tool_name = tool_call.name.to_s
        @output_queue.push(type: :tool_call, name: current_tool_name, arguments: tool_call.arguments)
      end
      chat.after_tool_result do |result|
        @output_queue.push(type: :tool_result, name: current_tool_name.to_s, result: result)
      end
      chat
    end

    def resolve_tool(tool_name)
      return tool_name if tool_name.is_a?(Class)
      return tool_name if tool_name.respond_to?(:call)

      tool_class = ChatApp::LocalTools.tool_class(tool_name) if defined?(ChatApp::LocalTools)
      return tool_class if tool_class

      tool_class = ChatApp::MemoryTools.tool_class(tool_name) if defined?(ChatApp::MemoryTools)
      return tool_class if tool_class

      tool_class = ChatApp::CodeExecutionTools.tool_class(tool_name) if defined?(ChatApp::CodeExecutionTools)
      return tool_class if tool_class

      case tool_name.to_s
      when ''
        nil
      else
        Object.const_get(tool_name.to_s)
      end
    rescue NameError
      nil
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
  end
end
