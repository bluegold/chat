# frozen_string_literal: true

require_relative '../tools/chat_tool_hints'

module ChatApp
  class StatusLineFormatter
    include ToolHints

    def format(params)
      scroll_value = params[:scroll].to_i
      scroll_state = scroll_value.positive? ? "scroll: #{scroll_value}" : 'scroll: bottom'
      mouse_state = params[:debug_mouse_enabled] ? (params[:mouse_debug] || 'mouse: -') : nil

      parts = [
        "agent: #{params[:agent_name]}",
        "model: #{params[:model]}",
        "status: #{format_status_code(params[:status])}",
        scroll_state
      ]

      if (tools_value = format_tools(params))
        parts << tools_value
      end

      parts << params[:tool_status_message] if params[:tool_status_message]
      parts << params[:notice_message] if params[:notice_message]
      parts << mouse_state if mouse_state
      parts.join(' | ')
    end

    private

    def format_status_code(status)
      if status.streaming?
        'streaming'
      elsif status.pending?
        'pending'
      else
        'ready'
      end
    end

    def format_tools(params)
      agent = params[:agent]
      tool_classes = params[:tool_classes]
      total = tool_count(agent, tool_classes)
      return nil unless total.positive?

      status = params[:status]
      pending = status.pending? || status.streaming?
      hints = tool_hint_features_list(params[:current_input_text], pending, params[:tool_hint_features])
      selected = selected_tool_count(agent, tool_classes, hints)

      if selected == total
        "tools: #{total}"
      else
        "tools: #{selected}(#{total})"
      end
    end

    def tool_count(agent, tool_classes)
      if tool_classes
        Array(tool_classes).length
      else
        Array(agent&.tool_names).length
      end
    end

    def tool_hint_features_list(current_input_text, pending, cached_hints)
      hints = tool_hints_for(current_input_text.to_s)
      return hints unless hints.empty?

      return Array(cached_hints) if pending && cached_hints

      []
    end

    def selected_tool_count(agent, tool_classes, hints)
      if hints.empty?
        baseline_tool_count(agent, tool_classes)
      elsif agent.respond_to?(:tool_classes_for_input)
        agent.tool_classes_for_features([:baseline, *hints]).length
      else
        hinted_tool_count(agent, tool_classes, hints)
      end
    end

    def baseline_tool_count(agent, tool_classes)
      if agent.respond_to?(:tool_classes_for_feature)
        count = agent.tool_classes_for_feature(:baseline).length
        return count unless count.zero?
      end

      tool_count(agent, tool_classes)
    end

    def hinted_tool_count(agent, tool_classes, hints)
      return baseline_tool_count(agent, tool_classes) if hints.empty?
      return agent.tool_classes_for_features(hints).length if agent.respond_to?(:tool_classes_for_features)

      if tool_classes
        Array(tool_classes).count do |tool_class|
          hints.any? { |feature| tool_class.respond_to?(:supports_feature?) && tool_class.supports_feature?(feature) }
        end
      else
        tool_count(agent, tool_classes)
      end
    end
  end
end
