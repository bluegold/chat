# frozen_string_literal: true

require 'yaml'
require_relative 'chat_agent_spec'

module ChatBackend
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
end
