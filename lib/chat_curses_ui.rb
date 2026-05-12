#!/usr/bin/env ruby
# frozen_string_literal: true

require 'curses'
require_relative 'chat_backend'
require_relative 'chat_curses_input'
require_relative 'chat_curses_session'

module ChatApp
  class CursesUI
    include ChatBackend::TextLayout

    def initialize(api_key, model: 'gpt-4o-mini')
      @session = CursesSession.new(
        api_key,
        model: model,
        system_prompt: load_system_prompt,
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
      Curses.stdscr.refresh
    rescue StandardError
      # Keep the app alive even if the terminal is temporarily unhappy.
    end

    def draw_header(cols)
      status = @session.response_pending? ? 'thinking...' : 'ready'
      title = 'RubyLLM Chat'
      model = @session.model.to_s
      prompt_state = @session.system_prompt && !@session.system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
      line = "#{title} | model: #{model} | #{status} | #{prompt_state}"
      Curses.stdscr.setpos(0, 0)
      Curses.stdscr.addstr(truncate_to_width(line, cols))
    end

    def draw_transcript(rows, cols)
      visible_height = [rows - 3, 0].max
      @session.transcript_visible_height = visible_height
      return if visible_height.zero?

      visible_lines = @session.transcript.window(cols, scroll: @session.transcript_scroll, height: visible_height)

      visible_lines.each_with_index do |line, idx|
        row = 1 + idx
        break if row >= rows - 2

        Curses.stdscr.setpos(row, 0)
        Curses.stdscr.addstr(truncate_to_width(line, cols))
      end

      return unless visible_lines.empty?

      Curses.stdscr.setpos(1, 0)
      Curses.stdscr.addstr(truncate_to_width('Type a message and press Enter.', cols))
    end

    def draw_separator(rows, cols)
      return if rows < 2

      Curses.stdscr.setpos(rows - 2, 0)
      Curses.stdscr.addstr(truncate_to_width(@session.status_line, cols).ljust(cols))
    end

    def draw_input(rows, cols)
      return if rows < 1

      prefix = '> '
      visible_text, cursor_x = @session.input_viewport([cols - display_width(prefix), 0].max)
      line = "#{prefix}#{visible_text}"
      visible_line = truncate_to_width(line, cols)

      Curses.stdscr.setpos(rows - 1, 0)
      Curses.stdscr.addstr(visible_line)
      Curses.stdscr.clrtoeol if Curses.stdscr.respond_to?(:clrtoeol)
      Curses.stdscr.setpos(rows - 1, [display_width(prefix) + cursor_x, cols - 1].min)
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

    def load_system_prompt
      prompt_file = File.join(Dir.pwd, '.system_prompt')
      return nil unless File.exist?(prompt_file)

      prompt = File.read(prompt_file)
      prompt.strip.empty? ? nil : prompt
    rescue StandardError
      nil
    end
  end
end
