# frozen_string_literal: true

module ChatBackend
  module TextLayout
    def transcript_line_entries(messages, cols)
      Array(messages).flat_map { |message| format_message_line_entries(message, cols) }
    end

    def transcript_lines(messages, cols)
      transcript_line_entries(messages, cols).map { |entry| entry[:text] }
    end

    def format_message_line_entries(message, cols)
      role = message[:role]
      content_lines = wrap_text(message[:content].to_s, cols)
      content_lines = [''] if content_lines.empty?

      case role
      when :user
        [
          { role: :user, text: '' },
          *prefixed_content_lines(content_lines, '> ', role: :user),
          { role: :user, text: '' }
        ]
      when :assistant
        [
          { role: :assistant, text: '' },
          *content_lines.map { |line| { role: :assistant, text: line } },
          { role: :assistant, text: '' }
        ]
      when :system
        [
          { role: :system, text: 'System:' },
          *content_lines.map { |line| { role: :system, text: line } },
          { role: :system, text: '' }
        ]
      when :info
        content_lines.map { |line| { role: :info, text: line } }
      when :error
        [{ role: :error, text: 'Error:' }, *content_lines.map { |line| { role: :error, text: line } }, { role: :error, text: '' }]
      else
        [
          { role: :message, text: 'Message:' },
          *content_lines.map { |line| { role: :message, text: line } },
          { role: :message, text: '' }
        ]
      end
    end

    def wrap_text(text, width)
      width = [width, 1].max
      lines = []
      current = +''
      current_width = 0

      text.to_s.each_char do |char|
        if char == "\n"
          lines << current
          current = +''
          current_width = 0
          next
        end

        char_width = display_width(char)
        if current_width.positive? && current_width + char_width > width
          lines << current
          current = +''
          current_width = 0
        end

        current << char
        current_width += char_width
      end

      lines << current unless current.empty?
      lines.empty? ? [''] : lines
    end

    def truncate_to_width(text, width)
      return '' if width <= 0

      result = +''
      current_width = 0

      text.to_s.each_char do |char|
        char_width = display_width(char)
        break if current_width + char_width > width

        result << char
        current_width += char_width
      end

      result
    end

    def display_width(text)
      text.to_s.each_char.sum { |char| char_width(char) }
    end

    def tool_call_text(tool_name, arguments = nil)
      details = tool_arguments_text(arguments)
      details.empty? ? "Using tool #{tool_name}" : "Using tool #{tool_name}(#{details})"
    end

    def tool_arguments_text(arguments)
      case arguments
      when nil
        ''
      when String
        arguments.strip
      when Hash
        arguments.map { |key, value| "#{key}: #{tool_value_text(value)}" }.join(', ')
      when Array
        arguments.map { |value| tool_value_text(value) }.join(', ')
      else
        arguments.to_s.strip
      end
    end

    def tool_value_text(value)
      case value
      when String
        value.include?("'") ? value.inspect : "'#{value}'"
      when TrueClass, FalseClass, Numeric
        value.to_s
      when Array
        "[#{value.map { |item| tool_value_text(item) }.join(', ')}]"
      when Hash
        "{#{value.map { |key, item| "#{key}: #{tool_value_text(item)}" }.join(', ')}}"
      else
        value.inspect
      end
    end

    def prefixed_content_lines(content_lines, prefix, role:)
      lines = Array(content_lines).dup
      first_line = lines.shift.to_s
      first_line = "#{prefix}#{first_line}"
      [{ role: role, text: first_line }, *lines.map { |line| { role: role, text: line } }]
    end

    def char_width(char)
      codepoint = char.ord
      return 0 if codepoint < 32 || (127..159).cover?(codepoint)
      return 2 if char.match?(
        /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u1100-\u115F\u2329\u232A\u2E80-\uA4CF\uAC00-\uD7A3\
\uF900-\uFAFF\uFE10-\uFE19\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/u
      )

      1
    end
  end
end
