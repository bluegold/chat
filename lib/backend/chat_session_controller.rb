# frozen_string_literal: true

require 'fileutils'
require_relative 'chat_backend'

module ChatApp
  class SessionController
    attr_reader :agent, :model, :system_prompt, :status, :transcript,
                :input_queue, :output_queue, :session_thread, :api_dump_path,
                :instruction_source_paths

    def initialize(api_key:, agent_registry:, llm: RubyLLM, archive_base_dir: nil)
      @api_key = api_key
      @agent_registry = agent_registry
      @llm = llm
      @archive_base_dir = archive_base_dir || File.expand_path('~/.config/myagent/archive')
      @session_thread = nil
      @agent = nil
      @model = nil
      @system_prompt = nil
      @status = nil
      @transcript = nil
      @input_queue = nil
      @output_queue = nil
      @api_dump_path = nil
      @api_dump_enabled = false
      @instruction_source_paths = []
    end

    def start_session(agent_name)
      shutdown_session if @session_thread

      @agent = @agent_registry[agent_name] || @agent_registry.default_agent
      raise ArgumentError, "unknown agent #{agent_name.inspect}" unless @agent

      @model = @agent.model
      @system_prompt = @agent.system_prompt
      @status = ChatBackend::Status.new
      @transcript = ChatBackend::Transcript.new
      @input_queue = Queue.new
      @output_queue = Queue.new
      @api_dump_path = build_api_dump_path
      @api_dump_enabled = false
      @instruction_source_paths = @agent_registry.instruction_source_paths(cwd: Dir.pwd)

      summarizer = @agent_registry['title_summarizer']

      config = ChatBackend::SessionConfig.new(
        input_queue: @input_queue,
        output_queue: @output_queue,
        api_key: @api_key,
        agent: @agent,
        response_sync: @status,
        llm: @llm,
        archive_base_dir: @archive_base_dir,
        summarizer_agent: summarizer,
        instruction_source_paths: @instruction_source_paths,
        api_dump_path: @api_dump_path,
        api_dump_enabled_proc: -> { @api_dump_enabled }
      )
      @session_thread = ChatBackend::SessionThread.new(config)
    end

    def shutdown_session
      return unless @session_thread

      @input_queue.push(type: :shutdown)
      @session_thread.join(0.5)
      @session_thread.kill if @session_thread.alive?
    ensure
      @session_thread = nil
    end

    def select_agent(agent_name)
      agent_name = agent_name.to_s.strip
      return if agent_name.empty?

      new_agent = @agent_registry[agent_name]
      return nil unless new_agent
      return @agent if @agent&.name == new_agent.name

      shutdown_session
      start_session(new_agent.name)
      new_agent
    end

    def response_pending?
      @status&.pending? || @status&.streaming?
    end

    def status_code
      return 'ready' unless @status

      return 'streaming' if @status.streaming?
      return 'pending' if @status.pending?

      'ready'
    end

    def send_message(text)
      return if response_pending?

      @status.expect_response
      @input_queue.push(type: :user_message, content: text)
    end

    def enable_api_dump!
      FileUtils.mkdir_p(File.dirname(@api_dump_path))
      ChatBackend::ApiDumpRecorder.write_start_marker(
        @api_dump_path,
        agent: @agent&.name,
        model: @model
      )
      @api_dump_enabled = true
    end

    def disable_api_dump!
      @api_dump_enabled = false
    end

    def api_dump_enabled?
      @api_dump_enabled
    end

    def session_title
      @session_thread&.session_title
    end

    def build_api_dump_path
      File.expand_path('~/.config/myagent/api_dump.log')
    end
    private :build_api_dump_path
  end
end
