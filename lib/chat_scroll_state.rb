# frozen_string_literal: true

module ChatApp
  class ScrollState
    attr_accessor :scroll, :visible_height

    def initialize(visible_height: 0)
      @scroll = 0
      @visible_height = visible_height
    end

    def scroll_by(delta)
      @scroll = [@scroll + delta, 0].max
    end

    def scroll_to_bottom
      @scroll = 0
    end

    def page_scroll_amount
      height = @visible_height.to_i
      return 8 if height <= 0

      [height - 1, 8].max
    end

    def wheel_scroll_amount
      4
    end
  end
end
