# frozen_string_literal: true

module ChatApp
  module CursesMouse
    private

    def handle_mouse_event
      verbose = $VERBOSE
      $VERBOSE = nil
      event = Curses.getmouse
      return unless event

      @mouse_debug = format_mouse_debug(event)
      delta = mouse_wheel_delta(event)
      scroll_transcript(delta * wheel_scroll_amount) if delta != 0
    rescue StandardError
      nil
    ensure
      $VERBOSE = verbose
    end

    def mouse_wheel_delta(event)
      bstate = event.bstate
      delta = 0
      delta += 1 if mouse_button?(bstate, :up)
      delta -= 1 if mouse_button?(bstate, :down)

      z = event.z
      delta += 1 if z.is_a?(Integer) && z.positive?
      delta -= 1 if z.is_a?(Integer) && z.negative?

      delta.clamp(-1, 1)
    end

    def mouse_button?(bstate, direction)
      mask =
        case direction
        when :up
          mouse_mask(:BUTTON4_PRESSED, :BUTTON4_CLICKED, :BUTTON4_RELEASED, :BUTTON4_DOUBLE_CLICKED, :BUTTON4_TRIPLE_CLICKED)
        when :down
          mouse_mask(
            :BUTTON5_PRESSED,
            :BUTTON5_CLICKED,
            :BUTTON5_RELEASED,
            :BUTTON5_DOUBLE_CLICKED,
            :BUTTON5_TRIPLE_CLICKED,
            1 << 20,
            1 << 21,
            1 << 22,
            1 << 23,
            1 << 24
          )
        else
          0
        end

      bstate.anybits?(mask)
    end

    def format_mouse_debug(event)
      parts = [
        'mouse:',
        "x=#{event.x}",
        "y=#{event.y}",
        "z=#{event.z}",
        "b=#{event.bstate}"
      ]
      truncate_to_width(parts.join(' '), [Curses.cols - 1, 0].max)
    rescue StandardError
      'mouse: error'
    end

    def env_truthy?(value)
      case value.to_s.strip.downcase
      when '1', 'true', 'yes', 'on'
        true
      else
        false
      end
    end

    def mouse_mask(*names)
      names.sum do |name|
        if name.is_a?(Integer)
          name
        elsif Curses.const_defined?(name)
          Curses.const_get(name)
        else
          0
        end
      end
    end
  end
end
