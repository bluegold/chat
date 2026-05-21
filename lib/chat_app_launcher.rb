#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'ui/chat_reline_ui'

module ChatAppLauncher
  module_function

  def run(argv: ARGV, env: ENV)
    ui = resolve_ui(argv, env)
    api_key = resolve_api_key(env)
    agent_registry = resolve_agent_registry(env)
    agent_name = resolve_agent_name(env, agent_registry)

    case ui
    when 'reline'
      ChatApp::RelineUI.new(api_key, agent_registry: agent_registry, agent_name: agent_name).run
    when 'curses'
      require_relative 'ui/chat_curses_ui'
      ChatApp::CursesUI.new(api_key, agent_registry: agent_registry, agent_name: agent_name).run
    else
      abort "Error: unknown UI #{ui.inspect} (use reline or curses)"
    end
  end

  def resolve_ui(argv, env)
    ui = env.fetch('CHAT_UI', 'reline')
    args = argv.dup

    until args.empty?
      arg = args.shift
      case arg
      when '--ui'
        ui = args.shift || abort('Error: --ui requires a value')
      when /\A--ui=(.+)\z/
        ui = Regexp.last_match(1)
      when '--help', '-h'
        print_usage
        exit 0
      else
        abort "Error: unknown argument #{arg}"
      end
    end

    ui
  end

  def resolve_api_key(env)
    api_key = env['OPENAI_API_KEY'] || env['ZAI_API_KEY']
    return api_key unless api_key.nil? || api_key.empty?

    abort 'Error: OPENAI_API_KEY environment variable is not set'
  end

  def resolve_agent_registry(env)
    ChatBackend::AgentRegistry.load(path: ChatBackend::AgentRegistry.default_path(env), env: env)
  end

  def resolve_agent_name(env, registry)
    agent_name = env.fetch('CHAT_AGENT', registry.default_agent_name)
    return agent_name if registry[agent_name]

    abort "Error: unknown agent #{agent_name.inspect} (available: #{registry.names.join(', ')})"
  end

  def print_usage
    puts <<~USAGE
      Usage: ruby chat.rb [--ui reline|curses]

      Environment:
        CHAT_UI=reline|curses
        CHAT_AGENT=<name>
        OPENAI_API_KEY or ZAI_API_KEY
        MYAGENT_CONFIG=~/.config/myagent.yml
        OPENAI_MODEL
    USAGE
  end
end

ChatAppLauncher.run if __FILE__ == $PROGRAM_NAME
