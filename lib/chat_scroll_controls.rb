# frozen_string_literal: true

module ChatApp
  module ScrollControls
    private

    def scroll_transcript(delta)
      @transcript_scroll = [@transcript_scroll + delta, 0].max
    end

    def scroll_to_bottom
      @transcript_scroll = 0
    end

    def page_scroll_amount
      height = @transcript_visible_height.to_i
      return 8 if height <= 0

      [height - 1, 8].max
    end

    def wheel_scroll_amount
      4
    end
  end
end
