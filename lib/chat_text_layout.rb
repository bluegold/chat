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
        [{ role: :user, text: '' }, *prefixed_content_lines(content_lines, '> ', role: :user), { role: :user, text: '' }]
      when :assistant
        [{ role: :assistant, text: '' }, *content_lines.map do |line|
          { role: :assistant, text: line }
        end, { role: :assistant, text: '' }]
      when :system
        [{ role: :system, text: 'System:' }, *content_lines.map do |line|
          { role: :system, text: line }
        end, { role: :system, text: '' }]
      when :info
        content_lines.map { |line| { role: :info, text: line } }
      when :error
        [{ role: :error, text: 'Error:' }, *content_lines.map { |line| { role: :error, text: line } }, { role: :error, text: '' }]
      else
        [{ role: :message, text: 'Message:' }, *content_lines.map do |line|
          { role: :message, text: line }
        end, { role: :message, text: '' }]
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

    def input_viewport(buffer, cursor, available_width)
      available_width = [available_width, 0].max
      chars = buffer.to_s.each_char.to_a
      widths = chars.map { |char| display_width(char) }
      cursor_index = cursor.clamp(0, chars.length)
      cursor_width = widths[0...cursor_index].sum
      total_width = widths.sum

      return [buffer.dup, cursor_width] if total_width <= available_width

      start_width = [cursor_width - available_width + 1, 0].max
      start_index = 0
      consumed = 0

      while start_index < chars.length && consumed + widths[start_index] <= start_width
        consumed += widths[start_index]
        start_index += 1
      end

      visible = +''
      visible_width = 0
      cursor_x = 0

      chars[start_index..].to_a.each_with_index do |char, offset|
        char_width = widths[start_index + offset]
        break if visible_width + char_width > available_width

        visible << char
        visible_width += char_width
        cursor_x = visible_width if start_index + offset + 1 <= cursor_index
      end

      [visible, cursor_x]
    end
  end
end
