# frozen_string_literal: true

module ChatApp
  module AgentControls
    private

    def agent_command?(text)
      text.start_with?('/agent')
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
