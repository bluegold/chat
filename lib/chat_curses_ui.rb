#!/usr/bin/env ruby
# frozen_string_literal: true

require 'curses'
require_relative 'chat_backend'
require_relative 'chat_curses_input'
require_relative 'chat_curses_session'

module ChatApp
  class CursesUI
    include ChatBackend::TextLayout

    def initialize(api_key, agent_registry:, agent_name:)
      @session = CursesSession.new(
        api_key,
        agent_registry: agent_registry,
        agent_name: agent_name,
        debug_mouse_enabled: env_truthy?(ENV.fetch('TUI_CHAT_DEBUG_MOUSE', nil)) || env_truthy?(ENV.fetch('TUI_CHAT_DEBUG', nil))
      )
      @input = CursesInput.new
      @running = true
      @screen_ready = false
    end

    def run
      setup_curses
      main_loop
    ensure
      shutdown
    end

    private

    def setup_curses
      Curses.init_screen
      @screen_ready = true
      Curses.raw
      Curses.noecho
      Curses.stdscr.keypad(true)
      setup_colors
      mouse_events = Curses::ALL_MOUSE_EVENTS
      mouse_events |= Curses::REPORT_MOUSE_POSITION if Curses.const_defined?(:REPORT_MOUSE_POSITION)
      Curses.mousemask(mouse_events) if Curses.respond_to?(:mousemask)
      Curses.mouseinterval(0) if Curses.respond_to?(:mouseinterval)
      Curses.ESCDELAY = 10 if Curses.respond_to?(:ESCDELAY=)
      Curses.stdscr.timeout = 100 if Curses.stdscr.respond_to?(:timeout=)
      Curses.curs_set(1) if Curses.respond_to?(:curs_set)
    rescue StandardError => e
      close_screen
      raise e
    end

    def main_loop
      while @running && @session.running?
        @session.drain_output_queue
        draw

        key = @input.read_nonblock
        @session.handle_key(key) unless key.nil?
        sleep 0.01 if key.nil?
      end
    rescue Interrupt
      @running = false
    end

    def draw
      rows = Curses.lines
      cols = Curses.cols
      return if rows <= 0 || cols <= 0

      Curses.stdscr.erase
      draw_header(cols)
      draw_transcript(rows, cols)
      draw_separator(rows, cols)
      draw_input(rows, cols)
      draw_bottom_margin(rows, cols)
      Curses.stdscr.refresh
    rescue StandardError => e
      render_draw_error(e)
    end

    def draw_header(cols)
      title = 'RubyLLM Chat'
      agent = @session.agent&.label.to_s
      model = @session.model.to_s
      line = "#{title} | agent: #{agent} | model: #{model} | status: #{@session.status_code}"
      Curses.stdscr.setpos(0, 0)
      apply_row_color(5) do
        Curses.stdscr.addstr(truncate_to_width(line, cols).ljust(cols))
      end
    end

    def draw_transcript(rows, cols)
      visible_height = [rows - 4, 0].max
      @session.transcript_visible_height = visible_height
      return if visible_height.zero?

      visible_lines = @session.transcript.window(cols, scroll: @session.transcript_scroll, height: visible_height)

      visible_lines.each_with_index do |line, idx|
        row = 1 + idx
        break if row >= rows - 3

        Curses.stdscr.setpos(row, 0)
        Curses.stdscr.addstr(truncate_to_width(line, cols))
      end

      return unless visible_lines.empty?

      Curses.stdscr.setpos(1, 0)
      Curses.stdscr.addstr(truncate_to_width('Type a message and press Enter.', cols))
    end

    def draw_separator(rows, cols)
      return if rows < 2

      Curses.stdscr.setpos(rows - 3, 0)
      apply_row_color(6) do
        Curses.stdscr.addstr(padded_status_line(@session.status_line, cols))
      end
    end

    def draw_input(rows, cols)
      return if rows < 1

      prefix = '> '
      content_width = [cols - display_width(prefix), 0].max
      visible_text, cursor_x = @session.input_viewport(content_width)
      line = "#{prefix}#{visible_text}"
      visible_line = truncate_to_width(line, cols)

      Curses.stdscr.setpos(rows - 2, 0)
      apply_row_color(7) do
        Curses.stdscr.addstr(visible_line.ljust(cols))
      end
      Curses.stdscr.setpos(rows - 2, [display_width(prefix) + cursor_x, cols - 1].min)
    end

    def draw_bottom_margin(rows, cols)
      return if rows < 1

      Curses.stdscr.setpos(rows - 1, 0)
      apply_row_color(7) do
        Curses.stdscr.addstr(' ' * cols)
      end
    end

    def shutdown
      @running = false
      close_screen
      @session.shutdown
    rescue StandardError
      # Nothing else to do on shutdown.
    end

    def close_screen
      return unless @screen_ready

      Curses.close_screen
      @screen_ready = false
    rescue StandardError
      @screen_ready = false
    end

    def env_truthy?(value)
      case value.to_s.strip.downcase
      when '1', 'true', 'yes', 'on'
        true
      else
        false
      end
    end

    def setup_colors
      return unless Curses.respond_to?(:start_color)
      return unless Curses.has_colors?

      Curses.start_color
      Curses.use_default_colors if Curses.respond_to?(:use_default_colors)
      Curses.init_pair(5, Curses::COLOR_WHITE, Curses::COLOR_BLUE)
      if Curses.respond_to?(:can_change_color?) && Curses.can_change_color?
        define_gray_background(8, 120)
        define_gray_background(9, 80)
        Curses.init_pair(6, Curses::COLOR_WHITE, 8)
        Curses.init_pair(7, Curses::COLOR_WHITE, 9)
      else
        Curses.init_pair(6, Curses::COLOR_WHITE, Curses::COLOR_BLACK)
        Curses.init_pair(7, Curses::COLOR_WHITE, Curses::COLOR_BLACK)
      end
    rescue StandardError
      nil
    end

    def apply_row_color(pair_id, &block)
      if Curses.respond_to?(:color_pair) && Curses.has_colors?
        Curses.stdscr.attron(Curses.color_pair(pair_id), &block)
      else
        block.call
      end
    rescue StandardError
      block.call
    end

    def padded_status_line(text, cols)
      inner = truncate_to_width(text, [cols - 2, 0].max)
      " #{inner.ljust([cols - 2, 0].max)} "
    end

    def define_gray_background(color_number, intensity)
      intensity = intensity.clamp(0, 1000)
      Curses.init_color(color_number, intensity, intensity, intensity)
    rescue StandardError
      nil
    end

    def render_draw_error(error)
      rows = Curses.lines
      cols = Curses.cols
      message = "draw error: #{error.class}: #{error.message}"

      if rows.positive? && cols.positive?
        Curses.stdscr.erase
        Curses.stdscr.setpos(0, 0)
        Curses.stdscr.addstr(truncate_to_width(message, cols))
        Curses.stdscr.refresh
      end

      warn(message) if env_truthy?(ENV.fetch('TUI_CHAT_DEBUG', nil))
    rescue StandardError
      warn(message)
    end
  end
end
