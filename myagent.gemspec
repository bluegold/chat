# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "myagent"
  spec.version       = "0.1.0"
  spec.authors       = ["The Chat TUI contributors"]
  spec.email         = []

  spec.summary       = "Ruby-based CLI/TUI chat interface for LLM agents"
  spec.description   = "Chat TUI is a terminal-based chat application for interacting " \
                        "with LLMs. It provides both CLI (Reline) and full-screen TUI " \
                        "(curses) modes, multi-provider support via ruby_llm, per-agent " \
                        "configuration, tool systems, and session management."
  spec.homepage      = "https://github.com/bluegold/chat"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata = {
    "homepage_uri"          => spec.homepage,
    "source_code_uri"       => "#{spec.homepage}/tree/main",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob("{lib,exe}/**/*") +
               %w[chat.rb README.md LICENSE myagent.yml.sample]

  spec.bindir        = "exe"
  spec.executables   = ["myagent"]
  spec.require_paths = ["lib"]

  spec.add_dependency "curses"
  spec.add_dependency "reline"
  spec.add_dependency "ruby_llm"
end
