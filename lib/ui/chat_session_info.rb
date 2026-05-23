# frozen_string_literal: true

require 'yaml'

module ChatApp
  module SessionInfo
    def session_info_text
      YAML.dump(session_info_data)
    end

    def instructions_info_text
      YAML.dump(instructions_info_data)
    end

    def agent_info_text
      YAML.dump(agent_info_data)
    end

    def api_dump_state_text
      YAML.dump(api_dump_state_data)
    end

    def session_info_data
      {
        'title' => current_session_title,
        'agent' => current_agent&.name,
        'summary' => session_summary_data,
        'status' => {
          'code' => status_code,
          'pending' => response_pending?,
          'streaming' => status_streaming?
        }
      }
    end

    def instructions_info_data
      {
        'agent' => agent_summary_data,
        'system_prompt' => current_agent&.system_prompt.to_s,
        'instruction_messages' => instruction_messages
      }
    end

    def agent_info_data
      agent_summary_data.merge(
        'system_prompt_present' => !current_agent&.system_prompt.to_s.strip.empty?,
        'system_prompt_length' => current_agent&.system_prompt.to_s.length
      )
    end

    def api_dump_state_data
      {
        'api_dump' => {
          'enabled' => api_dump_enabled?,
          'path' => api_dump_path.to_s
        }
      }
    end

    def tool_count
      Array(current_agent&.tool_names).length
    end

    def agent_summary_data
      {
        'name' => current_agent&.name,
        'display_name' => current_agent&.display_name,
        'model' => current_agent&.model,
        'temperature' => current_agent&.temperature,
        'tool_count' => tool_count,
        'tools' => current_agent&.tool_names || []
      }
    end

    def session_summary_data
      {
        'turn_count' => user_message_count,
        'tool_call_count' => tool_call_count
      }
    end

    def current_session_title
      return @session_controller.session_title if defined?(@session_controller) && @session_controller.respond_to?(:session_title)

      nil
    rescue StandardError
      nil
    end

    def transcript_messages
      return [] unless defined?(@session_controller)
      return Array(@session_controller.transcript&.messages) if @session_controller.respond_to?(:transcript)

      []
    rescue StandardError
      []
    end

    def user_message_count
      transcript_messages.count { |message| message[:role] == :user }
    end

    def tool_call_count
      transcript_messages.count do |message|
        message[:role] == :info && message[:content].to_s.start_with?('Using tool ')
      end
    end

    def instruction_messages
      instruction_source_paths.filter_map do |path|
        next unless File.file?(path)

        content = File.read(path)
        next if content.strip.empty?

        {
          'role' => 'system',
          'path' => path,
          'content' => <<~TEXT.rstrip
            [AGENTS.md: #{path}]
            #{content.rstrip}
          TEXT
        }
      rescue StandardError
        nil
      end
    end

    def instruction_source_paths
      return [] unless defined?(@session_controller)
      return @session_controller.instruction_source_paths if @session_controller.respond_to?(:instruction_source_paths)

      []
    rescue StandardError
      []
    end

    def api_dump_enabled?
      return false unless defined?(@session_controller)
      return @session_controller.api_dump_enabled? if @session_controller.respond_to?(:api_dump_enabled?)

      false
    end

    def api_dump_path
      return '' unless defined?(@session_controller)
      return @session_controller.api_dump_path if @session_controller.respond_to?(:api_dump_path)

      ''
    end

    def status_streaming?
      return false unless defined?(@status)
      return @status.streaming? if @status.respond_to?(:streaming?)

      false
    rescue StandardError
      false
    end

    def current_agent
      return agent if respond_to?(:agent)
      return @session_controller.agent if defined?(@session_controller) && @session_controller.respond_to?(:agent)

      nil
    end
  end
end
