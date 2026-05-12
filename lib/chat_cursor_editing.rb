# frozen_string_literal: true

module ChatApp
  module CursorEditing
    private

    def input_length
      @input_buffer.each_char.count
    end

    def move_input_cursor(delta)
      move_input_cursor_to(@input_cursor + delta)
    end

    def move_input_cursor_to(position)
      @input_cursor = position.clamp(0, input_length)
    end

    def delete_before_cursor
      return if @input_cursor <= 0

      chars = @input_buffer.each_char.to_a
      chars.delete_at(@input_cursor - 1)
      @input_buffer = chars.join
      @input_cursor -= 1
    end

    def delete_after_cursor
      return if @input_cursor >= input_length

      chars = @input_buffer.each_char.to_a
      chars.delete_at(@input_cursor)
      @input_buffer = chars.join
    end
  end
end
