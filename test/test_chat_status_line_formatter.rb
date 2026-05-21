# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/backend/chat_backend'
require_relative '../lib/ui/chat_status_line_formatter'

class ChatBackendStatusLineTest < Minitest::Test
  def test_status_line_includes_tool_count
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[search_files read_file]
    )

    formatter = ChatApp::StatusLineFormatter.new
    status_line = formatter.format(
      agent_name: 'coder',
      model: 'gpt-4o-mini',
      status: ChatBackend::Status.new,
      scroll: 0,
      agent: agent,
      debug_mouse_enabled: false,
      notice_message: nil
    )

    assert_includes status_line, 'tools: 1(2)'
  end

  def test_status_line_shows_filtered_tool_count_when_hint_matches
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[
        search_files search_text read_file list_dir
        memory_search memory_add memory_list memory_read memory_forget
        run_ruby run_python
      ]
    )

    status = ChatBackend::Status.new
    status.expect_response
    status.start_response

    formatter = ChatApp::StatusLineFormatter.new
    status_line = formatter.format(
      agent_name: 'coder',
      model: 'gpt-4o-mini',
      status: status,
      scroll: 0,
      agent: agent,
      debug_mouse_enabled: false,
      notice_message: nil,
      current_input_text: '',
      tool_hint_features: [:filesystem]
    )

    assert_includes status_line, 'tools: 5(11)'
  end

  def test_status_line_includes_tool_status_message
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[search_files read_file]
    )

    formatter = ChatApp::StatusLineFormatter.new
    status_line = formatter.format(
      agent_name: 'coder',
      model: 'gpt-4o-mini',
      status: ChatBackend::Status.new,
      scroll: 0,
      agent: agent,
      debug_mouse_enabled: false,
      notice_message: nil,
      tool_status_message: 'tool: search_files'
    )

    assert_includes status_line, 'tool: search_files'
  end
end
