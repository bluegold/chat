#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'chat_reline_ui'

module ChatAppLauncher
  module_function

  def run(argv: ARGV, env: ENV)
    ui = resolve_ui(argv, env)
    api_key = resolve_api_key(env)
    model = env.fetch('OPENAI_MODEL', 'gpt-4o-mini')

    case ui
    when 'reline'
      ChatApp::RelineUI.new(api_key, model).run
    when 'curses'
      require_relative 'chat_curses_ui'
      ChatApp::CursesUI.new(api_key, model: model).run
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

  def print_usage
    puts <<~USAGE
      Usage: ruby chat.rb [--ui reline|curses]

      Environment:
        CHAT_UI=reline|curses
        OPENAI_API_KEY or ZAI_API_KEY
        OPENAI_MODEL
    USAGE
  end
end

if __FILE__ == $PROGRAM_NAME
  ChatAppLauncher.run
end
