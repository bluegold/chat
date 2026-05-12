# frozen_string_literal: true

begin
  require 'curses'
rescue LoadError => e
  abort "Error: curses is required for tui_chat.rb (#{e.message})"
end

module ChatApp
  class CursesInput
    def initialize(adapter: Curses)
      @adapter = adapter
      @paste_mode = false
    end

    def read
      read_key(blocking: true)
    end

    def read_nonblock
      read_key(blocking: false)
    end

    private

    def read_key(blocking:)
      @adapter.stdscr.timeout = blocking ? -1 : 0 if @adapter.stdscr.respond_to?(:timeout=)

      key = @adapter.getch
      return nil if key.nil? || key == -1

      normalized = normalize_key(key)
      return handle_paste_mode(normalized) if @paste_mode

      if normalized == "\e" && bracketed_paste_start?
        @paste_mode = true
        return read_key(blocking: false)
      end

      normalized
    end

    def normalize_key(key)
      return key if key.is_a?(String)

      special = special_key_map[key]
      return special if special
      return key if key.negative? || key > 255
      return read_utf8_char(key) if key >= 0x80

      key.chr(Encoding::UTF_8)
    end

    def special_key_map
      @special_key_map ||= begin
        map = {
          @adapter::KEY_RESIZE => :resize,
          @adapter::KEY_UP => :up,
          @adapter::KEY_DOWN => :down,
          @adapter::KEY_LEFT => :left,
          @adapter::KEY_RIGHT => :right,
          @adapter::KEY_HOME => :home,
          @adapter::KEY_END => :end,
          @adapter::KEY_PPAGE => :page_up,
          @adapter::KEY_NPAGE => :page_down,
          @adapter::KEY_MOUSE => :mouse,
          @adapter::KEY_BACKSPACE => :backspace,
          @adapter::KEY_DC => :delete,
          @adapter::KEY_ENTER => :enter,
          9 => :tab,
          3 => :quit,
          4 => :quit,
          8 => :backspace,
          10 => :enter,
          13 => :enter,
          127 => :backspace,
          1 => :home,
          5 => :end
        }
        map[@adapter::KEY_CTRL_A] = :home if @adapter.const_defined?(:KEY_CTRL_A)
        map
      end
    end

    def read_utf8_char(first_byte)
      bytes = [first_byte]

      expected =
        if (first_byte & 0xE0) == 0xC0
          2
        elsif (first_byte & 0xF0) == 0xE0
          3
        elsif (first_byte & 0xF8) == 0xF0
          4
        else
          1
        end

      (expected - 1).times do
        next_byte = @adapter.getch
        break unless next_byte.is_a?(Integer) && (next_byte & 0xC0) == 0x80

        bytes << next_byte
      end

      bytes.pack('C*').force_encoding(Encoding::UTF_8)
    end

    def handle_paste_mode(key)
      if key == "\e"
        if bracketed_paste_end?
          @paste_mode = false
          return read_key(blocking: false)
        end

        return "\e"
      end

      case key
      when :enter
        "\n"
      when :tab
        "\t"
      when String
        key
      else
        key.respond_to?(:to_s) ? key.to_s : nil
      end
    end

    def bracketed_paste_start?
      consume_sequence('[200~')
    end

    def bracketed_paste_end?
      consume_sequence('[201~')
    end

    def consume_sequence(expected)
      consumed = +''

      expected.each_char do |expected_char|
        raw = @adapter.getch
        return restore_sequence(consumed) if raw.nil? || raw == -1

        normalized = normalize_key(raw)
        consumed << normalized if normalized.is_a?(String)
        return restore_sequence(consumed) if normalized != expected_char
      end

      true
    end

    def restore_sequence(consumed)
      return unless @adapter.respond_to?(:ungetch)

      consumed.each_char.reverse_each do |char|
        @adapter.ungetch(char)
      end
      nil
    end
  end
end
