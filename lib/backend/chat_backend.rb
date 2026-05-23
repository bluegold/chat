# frozen_string_literal: true

require 'yaml'
require 'ruby_llm'
require_relative '../tools/chat_local_tools'
require_relative '../tools/chat_memory_tools'
require_relative '../tools/chat_code_execution_tools'
require_relative '../tools/chat_web_tools'
require_relative '../tools/chat_tool_hints'
require_relative 'chat_api_dump_recorder'

module ChatBackend
  # rubocop:disable Metrics/PerceivedComplexity
  def self.tool_class_for(tool_name)
    return tool_name if tool_name.is_a?(Class)
    return tool_name if tool_name.respond_to?(:call)

    tool_class = ChatApp::LocalTools.tool_class(tool_name) if defined?(ChatApp::LocalTools)
    return tool_class if tool_class

    tool_class = ChatApp::MemoryTools.tool_class(tool_name) if defined?(ChatApp::MemoryTools)
    return tool_class if tool_class

    tool_class = ChatApp::CodeExecutionTools.tool_class(tool_name) if defined?(ChatApp::CodeExecutionTools)
    return tool_class if tool_class

    tool_class = ChatApp::WebTools.tool_class(tool_name) if defined?(ChatApp::WebTools)
    return tool_class if tool_class

    case tool_name.to_s
    when ''
      nil
    else
      Object.const_get(tool_name.to_s)
    end
  rescue NameError
    nil
  end
  # rubocop:enable Metrics/PerceivedComplexity
end

require_relative 'chat_text_layout'
require_relative 'chat_transcript'
require_relative 'chat_agent_spec'
require_relative 'chat_agent_registry'
require_relative 'chat_history_store'
require_relative 'chat_session_config'
require_relative 'chat_status'
require_relative 'chat_session_thread'
