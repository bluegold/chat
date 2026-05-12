# frozen_string_literal: true

module ChatApp
  module CursesInputRender
    private

    def input_render_state(buffer:, cursor:, cols:, max_height: nil)
      cols = [cols.to_i, 1].max
      max_height = [max_height.to_i, 1].max
      buffer = buffer.to_s
      cursor = cursor.to_i.clamp(0, buffer.each_char.count)
      prompt = '> '
      lines = buffer.split("\n", -1)
      rendered_lines = lines.map { |line| visible_input_line(line) }
      rendered_lines = [''] if rendered_lines.empty?
      rendered_lines[0] = "#{prompt}#{rendered_lines[0]}"
      cursor_row, cursor_col = cursor_position(buffer, cursor)
      cursor_col += display_width(prompt) if cursor_row.zero?
      start_line = [rendered_lines.length - max_height, 0].max
      visible_lines = rendered_lines[start_line, max_height] || ['']
      visible_cursor_row = cursor_row - start_line
      visible_cursor_row = 0 if visible_cursor_row.negative?
      visible_cursor_row = [visible_cursor_row, visible_lines.length - 1].min
      visible_cursor_col = [cursor_col, cols - 1].min

      {
        lines: visible_lines,
        cursor_row: visible_cursor_row,
        cursor_col: visible_cursor_col,
        height: visible_lines.length
      }
    end

    def visible_input_line(line)
      line.each_char.map { |char| visible_input_char(char) }.join
    end

    def visible_input_char(char)
      case char
      when "\t"
        '⇥'
      else
        char
      end
    end

    def cursor_position(buffer, cursor)
      chars = buffer.each_char.to_a
      cursor = cursor.clamp(0, chars.length)
      prefix = chars.take(cursor).join
      return [0, 0] if prefix.empty?

      lines = prefix.split("\n", -1)
      line_index = lines.length - 1
      line_prefix = lines.last.to_s
      [line_index, display_width(visible_input_line(line_prefix))]
    end
  end
end
