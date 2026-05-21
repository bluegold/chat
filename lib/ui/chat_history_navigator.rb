# frozen_string_literal: true

module ChatApp
  class HistoryNavigator
    attr_reader :index, :draft

    def initialize(history_store)
      @history_store = history_store
      reset
    end

    def recall(direction, current_buffer)
      entries = @history_store.to_a
      return current_buffer if entries.empty?

      case direction
      when :up
        if @index == -1
          @draft = current_buffer.dup
          @index = entries.length - 1
        elsif @index.positive?
          @index -= 1
        end
        entries[@index].dup
      when :down
        return current_buffer if @index == -1

        if @index < entries.length - 1
          @index += 1
          entries[@index].dup
        else
          @index = -1
          result = @draft.to_s
          @draft = nil
          result
        end
      else
        current_buffer
      end
    end

    def reset
      @index = -1
      @draft = nil
    end
  end
end
