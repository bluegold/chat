# frozen_string_literal: true

module ChatApp
  class CommandParser
    def initialize(agent_registry)
      @agent_registry = agent_registry
    end

    def command_name(text)
      text.to_s.split(/\s+/, 2).first.to_s.delete_prefix('/')
    end

    def agent_command?(text)
      command_name(text) == 'agent'
    end

    def session_info_command?(text)
      command_name(text) == 'session_info'
    end

    def agent_info_command?(text)
      command_name(text) == 'agent_info'
    end

    def api_dump_command?(text)
      command_name(text) == 'api_dump'
    end

    def api_dump_action(text)
      return nil unless api_dump_command?(text)

      _cmd, action = text.to_s.split(/\s+/, 2)
      case action.to_s.strip
      when 'on'
        :on
      when 'off'
        :off
      else
        nil
      end
    end

    def instructions_command?(text)
      command_name(text) == 'instructions'
    end

    def exit_command?(text)
      command_name(text) == 'exit'
    end

    def agent_name_from_command(text)
      _cmd, name = text.split(/\s+/, 2)
      name.to_s.strip
    end

    def resolve_agent(agent_name)
      agent = @agent_registry[agent_name] || @agent_registry.default_agent
      raise ArgumentError, "unknown agent #{agent_name.inspect}" unless agent

      agent
    end
  end
end
