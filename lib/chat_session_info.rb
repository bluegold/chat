# frozen_string_literal: true

require 'yaml'

module ChatApp
  module SessionInfo
    def session_info_text
      YAML.dump(session_info_data)
    end

    def session_info_data
      {
        'agent' => {
          'name' => @agent&.name,
          'display_name' => @agent&.display_name,
          'model' => @agent&.model,
          'temperature' => @agent&.temperature,
          'tool_count' => tool_count,
          'tools' => @agent&.tool_names || []
        },
        'system_prompt' => @agent&.system_prompt.to_s,
        'status' => {
          'code' => status_code,
          'pending' => response_pending?,
          'streaming' => @status.streaming?
        }
      }
    end

    def tool_count
      Array(@agent&.tool_names).length
    end
  end
end
