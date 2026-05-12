# frozen_string_literal: true

module ChatApp
  module SessionStatus
    def response_pending?
      @status.pending? || @status.streaming?
    end

    def status_code
      return 'streaming' if @status.streaming?
      return 'pending' if @status.pending?

      'ready'
    end

    def status_line
      scroll_value = @transcript_scroll.to_i
      scroll_state = scroll_value.positive? ? "scroll: #{scroll_value}" : 'scroll: bottom'
      mouse_state = @debug_mouse_enabled ? (@mouse_debug || 'mouse: -') : nil
      tools_value = respond_to?(:tool_count, true) ? tool_count : Array(@agent&.tool_names).length
      parts = [
        "agent: #{@agent_name}",
        "model: #{@model}",
        "tools: #{tools_value}",
        "status: #{status_code}",
        scroll_state
      ]
      parts << tool_status_message if respond_to?(:tool_status_message, true) && tool_status_message
      parts << @notice_message if @notice_message
      parts << mouse_state if mouse_state
      parts.join(' | ')
    end
  end
end
