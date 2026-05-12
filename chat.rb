#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/chat_app_launcher'

if __FILE__ == $PROGRAM_NAME
  ChatAppLauncher.run(argv: ARGV, env: ENV)
end
