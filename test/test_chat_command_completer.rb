# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ui/chat_command_completer'

class ChatBackendCommandCompletionTest < Minitest::Test
  def setup
    @completer = ChatApp::CommandCompleter.new(%w[coder helper])
  end

  def test_command_completion_expands_short_command_prefix
    result = @completer.complete('/a', 2)

    assert_equal '/agent ', result[:buffer]
    assert_equal 7, result[:cursor]
  end

  def test_command_completion_expands_agent_name
    result = @completer.complete('/agent h', 8)

    assert_equal '/agent helper ', result[:buffer]
    assert_equal 14, result[:cursor]
  end

  def test_command_completion_expands_session_info_command
    result = @completer.complete('/se', 3)

    assert_equal '/session_info', result[:buffer]
    assert_equal 13, result[:cursor]
  end
end
