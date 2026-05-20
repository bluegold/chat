# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/chat_backend'
require_relative '../lib/chat_command_parser'

class ChatBackendCommandParserTest < Minitest::Test
  def setup
    @default_agent = ChatBackend::AgentSpec.new(name: 'default_coder', display_name: nil, model: 'gpt-4o-mini',
                                                system_prompt: nil, temperature: nil, tools: [])
    @specific_agent = ChatBackend::AgentSpec.new(name: 'coder', display_name: nil, model: 'gpt-4o-mini', system_prompt: nil,
                                                 temperature: nil, tools: [])

    @registry = ChatBackend::AgentRegistry.new(
      agents: {
        @default_agent.name => @default_agent,
        @specific_agent.name => @specific_agent
      },
      default_agent_name: 'default_coder'
    )
    @parser = ChatApp::CommandParser.new(@registry)
  end

  def test_command_name
    assert_equal 'agent', @parser.command_name('/agent coder')
    assert_equal 'exit', @parser.command_name('/exit')
    assert_equal 'not', @parser.command_name('not a command')
  end

  def test_agent_command_predicate
    assert @parser.agent_command?('/agent coder')
    refute @parser.agent_command?('/exit')
  end

  def test_exit_command_predicate
    assert @parser.exit_command?('/exit')
    refute @parser.exit_command?('/agent coder')
  end

  def test_session_info_command_predicate
    assert @parser.session_info_command?('/session_info')
    refute @parser.session_info_command?('/exit')
  end

  def test_agent_name_from_command
    assert_equal 'coder', @parser.agent_name_from_command('/agent coder')
    assert_equal 'helper', @parser.agent_name_from_command('/agent   helper  ')
  end

  def test_resolve_agent
    assert_equal @specific_agent, @parser.resolve_agent('coder')
    assert_equal @default_agent, @parser.resolve_agent('default_coder')
    assert_equal @default_agent, @parser.resolve_agent('nonexistent_agent') # fallback to default
  end
end
