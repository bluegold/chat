# frozen_string_literal: true

require_relative 'chat_tool_hints'

module ChatApp
  module SessionStatus
    include ToolHints

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
      tools_value = tool_count_label
      parts = [
        "agent: #{@agent_name}",
        "model: #{@model}",
        "status: #{status_code}",
        scroll_state
      ]
      parts << tools_value if tools_value
      parts << tool_status_message if respond_to?(:tool_status_message, true) && tool_status_message
      parts << @notice_message if @notice_message
      parts << mouse_state if mouse_state
      parts.join(' | ')
    end

    def tool_count_label
      total = tool_count
      hints = tool_hint_features
      selected = selected_tool_count(hints)
      return "tools: #{total}" if selected == total

      "tools: #{selected}(#{total})"
    end

    def tool_count
      if respond_to?(:tool_classes, true)
        Array(tool_classes).length
      else
        Array(@agent&.tool_names).length
      end
    end

    def tool_hint_features
      text = current_input_text.to_s
      hints = tool_hints_for(text)
      return hints unless hints.empty?

      return Array(@tool_hint_features) if response_pending? && @tool_hint_features

      []
    end

    def hinted_tool_count(hints)
      return baseline_tool_count if hints.empty?
      return @agent.tool_classes_for_features(hints).length if @agent.respond_to?(:tool_classes_for_features)

      if respond_to?(:tool_classes, true)
        Array(tool_classes).count do |tool_class|
          hints.any? { |feature| tool_class.respond_to?(:supports_feature?) && tool_class.supports_feature?(feature) }
        end
      else
        tool_count
      end
    end

    def baseline_tool_count
      if @agent.respond_to?(:tool_classes_for_feature)
        count = @agent.tool_classes_for_feature(:baseline).length
        return count unless count.zero?
      end

      tool_count
    end

    def selected_tool_count(hints)
      if hints.empty?
        baseline_tool_count
      elsif @agent.respond_to?(:tool_classes_for_input)
        @agent.tool_classes_for_features([:baseline, *hints]).length
      else
        hinted_tool_count(hints)
      end
    end

    def current_input_text
      if respond_to?(:input_buffer, true)
        input_buffer.to_s
      elsif respond_to?(:current_input_line, true)
        current_input_line.to_s
      else
        ''
      end
    end
  end
end
