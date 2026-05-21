# frozen_string_literal: true

require_relative 'chat_backend'

module ChatApp
  class SessionController
    attr_reader :agent, :model, :system_prompt, :status, :transcript,
                :input_queue, :output_queue, :session_thread

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

      summarizer = @agent_registry['title_summarizer']

      config = ChatBackend::SessionConfig.new(
        input_queue: @input_queue,
        output_queue: @output_queue,
        api_key: @api_key,
        agent: @agent,
        response_sync: @status,
        llm: @llm,
        archive_base_dir: @archive_base_dir,
        summarizer_agent: summarizer
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
  end
end
