# frozen_string_literal: true

require 'ruby_llm'

module ChatBackend
  SessionConfig = Data.define(
    :input_queue,
    :output_queue,
    :api_key,
    :agent,
    :response_sync,
    :llm,
    :archive_base_dir,
    :summarizer_agent
  ) do
    # rubocop:disable Metrics/ParameterLists
    def initialize(
      input_queue:, output_queue:, api_key:, agent:, response_sync:,
      llm: nil, archive_base_dir: nil, summarizer_agent: nil
    )
      super
    end
    # rubocop:enable Metrics/ParameterLists

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

    def tool_classes
      agent&.tool_classes || []
    end

    def tool_classes_for_input(text)
      agent&.tool_classes_for_input(text) || []
    end
  end
end
