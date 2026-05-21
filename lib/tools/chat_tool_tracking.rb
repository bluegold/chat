# frozen_string_literal: true

module ChatApp
  module ToolTracking
    def tool_status_message
      @tool_status_message
    end

    def start_tool_status(tool_name)
      @tool_status_message = "tool: #{tool_name}"
    end

    def clear_tool_status
      @tool_status_message = nil
    end

    def tool_call_text(tool_name, arguments = nil)
      details = tool_arguments_text(arguments)
      details.empty? ? "Tool: #{tool_name}" : "Tool: #{tool_name} #{details}"
    end

    def tool_result_text(tool_name, result)
      summary = tool_result_summary(result)
      summary.empty? ? "Tool result: #{tool_name}" : "Tool result: #{tool_name} #{summary}"
    end

    def tool_arguments_text(arguments)
      return '' if arguments.nil?

      text = arguments.is_a?(String) ? arguments : arguments.to_s
      text = text.strip
      return '' if text.empty?

      "args: #{truncate_tool_text(text)}"
    end

    def tool_result_summary(result)
      text = result.is_a?(String) ? result : result.to_s
      text = text.strip
      return '' if text.empty?

      truncate_tool_text(text)
    end

    def truncate_tool_text(text, limit = 240)
      text = text.to_s.gsub(/\s+/, ' ').strip
      text.length > limit ? "#{text[0...limit]}…" : text
    end
  end
end
