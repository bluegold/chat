#!/usr/bin/env ruby
# frozen_string_literal: true

require "ruby_llm"

ENV["OPENAI_API_KEY"] ||= ENV["ZAI_API_KEY"]

if ENV["OPENAI_API_KEY"].nil? || ENV["OPENAI_API_KEY"].empty?
  STDERR.puts "Error: OPENAI_API_KEY environment variable is not set"
  exit 1
end

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

chat = RubyLLM.chat
response = chat.ask("Hello, please say hi back")
puts "Assistant: #{response.content}"
