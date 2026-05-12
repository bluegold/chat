#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thread'

begin
  require 'curses'
rescue LoadError => e
  abort "Error: curses is required for tui_chat.rb (#{e.message})"
end

require 'ruby_llm'

Thread.report_on_exception = true

class SessionThread
  attr_reader :thread

  def initialize(input_queue, output_queue, api_key, model, system_prompt)
    @input_queue = input_queue
    @output_queue = output_queue
    @system_prompt = system_prompt
    @history = []

    RubyLLM.configure do |config|
      config.openai_api_key = api_key
      config.default_model = model
    end

    @thread = Thread.new { run }
  end

  def join(timeout = nil)
    @thread.join(timeout)
  end

  def alive?
    @thread.alive?
  end

  def kill
    @thread.kill
  end

  private

  def run
    loop do
      msg = @input_queue.pop
      break if msg[:type] == :shutdown

      case msg[:type]
      when :user_message
        handle_user_message(msg[:content])
      end
    rescue StandardError => e
      @output_queue.push(type: :error, message: format_error(e))
      @output_queue.push(type: :stream_end)
    end
  end

  def handle_user_message(content)
    chat = build_chat
    @history << { role: :user, content: content }
    @output_queue.push(type: :stream_start)

    full_response = +''
    assistant_started = false

    response = chat.ask(content) do |chunk|
      chunk_content = normalize_chunk(chunk)
      next if chunk_content.empty?

      full_response << chunk_content
      unless assistant_started
        assistant_started = true
        @output_queue.push(type: :assistant_start)
      end
      @output_queue.push(type: :stream_chunk, content: chunk_content)
    end

    assistant_text = full_response.empty? ? extract_response_content(response) : full_response
    if !assistant_started && !assistant_text.empty?
      @output_queue.push(type: :assistant_start)
      @output_queue.push(type: :stream_chunk, content: assistant_text)
    end

    @history << { role: :assistant, content: assistant_text } unless assistant_text.empty?
    @output_queue.push(type: :stream_end)
  rescue StandardError => e
    @output_queue.push(type: :error, message: format_error(e))
    @output_queue.push(type: :stream_end)
  end

  def build_chat
    chat = RubyLLM.chat
    if @system_prompt && !@system_prompt.strip.empty?
      chat.with_instructions(@system_prompt)
    end

    @history.each do |message|
      chat.add_message(role: message[:role], content: message[:content])
    end

    chat
  end

  def normalize_chunk(chunk)
    case chunk
    when String
      chunk
    else
      if chunk.respond_to?(:content)
        chunk.content.to_s
      elsif chunk.respond_to?(:text)
        chunk.text.to_s
      else
        chunk.to_s
      end
    end
  end

  def extract_response_content(response)
    return '' unless response
    return response.content.to_s if response.respond_to?(:content)

    response.to_s
  end

  def format_error(error)
    backtrace = Array(error.backtrace).first(5)
    [ "#{error.class}: #{error.message}", *backtrace ].join("\n")
  end
end

class CursesInput
  def initialize(adapter: Curses)
    @adapter = adapter
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

    normalize_key(key)
  end

  def normalize_key(key)
    return key if key.is_a?(String)

    case key
    when @adapter::KEY_RESIZE
      :resize
    when @adapter::KEY_UP
      :up
    when @adapter::KEY_DOWN
      :down
    when @adapter::KEY_LEFT
      :left
    when @adapter::KEY_RIGHT
      :right
    when @adapter::KEY_HOME, @adapter::KEY_CTRL_A, 1
      :home
    when @adapter::KEY_END, 5
      :end
    when @adapter::KEY_PPAGE
      :page_up
    when @adapter::KEY_NPAGE
      :page_down
    when @adapter::KEY_MOUSE
      :mouse
    when @adapter::KEY_BACKSPACE, 8, 127
      :backspace
    when @adapter::KEY_DC
      :delete
    when @adapter::KEY_ENTER, 10, 13
      :enter
    when 3, 4
      :quit
    else
      return key if key.negative? || key > 255
      return read_utf8_char(key) if key >= 0x80

      key.chr(Encoding::UTF_8)
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
end

class CursesChatApp
  HISTORY_FILE = File.expand_path('.chat_history', Dir.home)
  MAX_HISTORY = 1000

  def initialize(api_key, model: 'gpt-4o-mini')
    @api_key = api_key
    @model = model
    @system_prompt = load_system_prompt
    @input_queue = Queue.new
    @output_queue = Queue.new
    @session_thread = SessionThread.new(@input_queue, @output_queue, api_key, model, @system_prompt)
    @input = CursesInput.new
    @messages = []
    @input_buffer = +''
    @input_cursor = 0
    @input_history = []
    @history_index = -1
    @history_draft = nil
    @transcript_scroll = 0
    @mouse_debug = nil
    @debug_mouse_enabled = env_truthy?(ENV['TUI_CHAT_DEBUG_MOUSE']) || env_truthy?(ENV['TUI_CHAT_DEBUG'])
    @running = true
    @pending_response = false
    @screen_ready = false
    load_history
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
    while @running
      drain_output_queue
      draw

      key = @input.read_nonblock
      handle_key(key) unless key.nil?
      sleep 0.01 if key.nil?
    end
  rescue Interrupt
    @running = false
  end

  def handle_key(key)
    case key
    when :resize
      nil
    when :backspace
      delete_before_cursor unless @pending_response
    when :delete
      delete_after_cursor unless @pending_response
    when :left
      move_input_cursor(-1) unless @pending_response
    when :right
      move_input_cursor(1) unless @pending_response
    when :home
      move_input_cursor_to(0) unless @pending_response
    when :end
      move_input_cursor_to(input_length) unless @pending_response
    when :up
      recall_history(:up)
    when :down
      recall_history(:down)
    when :page_up
      scroll_transcript(page_scroll_amount)
    when :page_down
      scroll_transcript(-page_scroll_amount)
    when :mouse
      handle_mouse_event
    when :enter
      submit_input
    when :quit
      @running = false
    else
      append_input(key)
    end
  end

  def append_input(key)
    return unless key.is_a?(String)
    return if @pending_response

    return unless key.match?(/\A[[:print:]]+\z/u)

    chars = @input_buffer.each_char.to_a
    chars.insert(@input_cursor, key)
    @input_buffer = chars.join
    @input_cursor += key.length
  end

  def submit_input
    scroll_to_bottom
    text = @input_buffer.dup
    return if text.strip.empty?
    return if @pending_response

    @messages << { role: :user, content: text }
    save_history_entry(text)
    @input_queue.push(type: :user_message, content: text)

    @input_buffer = +''
    @input_cursor = 0
    @history_index = -1
    @history_draft = nil
  end

  def recall_history(direction)
    return if @input_history.empty?

    case direction
    when :up
      if @history_index == -1
        @history_draft = @input_buffer.dup
        @history_index = @input_history.length - 1
      elsif @history_index.positive?
        @history_index -= 1
      end
      @input_buffer = @input_history[@history_index].dup
      @input_cursor = input_length
    when :down
      return if @history_index == -1

      if @history_index < @input_history.length - 1
        @history_index += 1
        @input_buffer = @input_history[@history_index].dup
        @input_cursor = input_length
      else
        @history_index = -1
        @input_buffer = @history_draft.to_s
        @history_draft = nil
        @input_cursor = input_length
      end
    end
  end

  def drain_output_queue
    loop do
      msg = @output_queue.pop(true)
      handle_output_message(msg)
    rescue ThreadError
      break
    end
  end

  def handle_output_message(msg)
    case msg[:type]
    when :stream_start
      @pending_response = true
    when :assistant_start
      @messages << { role: :assistant, content: +'' }
    when :stream_chunk
      append_assistant_chunk(msg[:content])
    when :stream_end
      @pending_response = false
    when :system_message
      @messages << { role: :system, content: msg[:content].to_s }
    when :error
      @messages << { role: :error, content: msg[:message].to_s }
      @pending_response = false
    end
  end

  def append_assistant_chunk(content)
    text = content.to_s
    return if text.empty?

    if @messages.empty? || @messages[-1][:role] != :assistant
      @messages << { role: :assistant, content: +'' }
    end

    @messages[-1][:content] << text
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
    status = @pending_response ? 'thinking...' : 'ready'
    title = "RubyLLM Chat"
    model = @model.to_s
    prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
    line = "#{title} | model: #{model} | #{status} | #{prompt_state}"
    Curses.stdscr.setpos(0, 0)
    Curses.stdscr.addstr(truncate_to_width(line, cols))
  end

  def draw_transcript(rows, cols)
    visible_height = [rows - 3, 0].max
    @transcript_visible_height = visible_height
    return if visible_height.zero?

    lines = transcript_lines(cols)
    max_scroll = [lines.length - visible_height, 0].max
    @transcript_scroll = [[@transcript_scroll, 0].max, max_scroll].min
    start_index = [lines.length - visible_height - @transcript_scroll, 0].max
    visible_lines = lines[start_index, visible_height] || []

    visible_lines.each_with_index do |line, idx|
      row = 1 + idx
      break if row >= rows - 2

      Curses.stdscr.setpos(row, 0)
      Curses.stdscr.addstr(truncate_to_width(line, cols))
    end

    if lines.empty?
      Curses.stdscr.setpos(1, 0)
      Curses.stdscr.addstr(truncate_to_width('Type a message and press Enter.', cols))
    end
  end

  def draw_separator(rows, cols)
    return if rows < 2

    Curses.stdscr.setpos(rows - 2, 0)
    Curses.stdscr.addstr(truncate_to_width(status_line, cols).ljust(cols))
  end

  def draw_input(rows, cols)
    return if rows < 1

    prefix = '> '
    visible_text, cursor_x = input_viewport([cols - display_width(prefix), 0].max)
    line = "#{prefix}#{visible_text}"
    visible_line = truncate_to_width(line, cols)

    Curses.stdscr.setpos(rows - 1, 0)
    Curses.stdscr.addstr(visible_line)
    Curses.stdscr.clrtoeol if Curses.stdscr.respond_to?(:clrtoeol)
    Curses.stdscr.setpos(rows - 1, [display_width(prefix) + cursor_x, cols - 1].min)
  end

  def status_line
    status = @pending_response ? 'thinking...' : 'ready'
    prompt_state = @system_prompt && !@system_prompt.strip.empty? ? 'system prompt loaded' : 'no system prompt'
    scroll_value = @transcript_scroll.to_i
    scroll_state = scroll_value.positive? ? "scroll: #{scroll_value}" : 'scroll: bottom'
    mouse_state = @debug_mouse_enabled ? (@mouse_debug || 'mouse: -') : nil
    parts = ["model: #{@model}", status, prompt_state, scroll_state]
    parts << mouse_state if mouse_state
    parts.join(' | ')
  end

  def transcript_lines(cols)
    @messages.flat_map do |message|
      format_message_block(message, cols)
    end
  end

  def format_message_block(message, cols)
    label = case message[:role]
            when :user then 'You'
            when :assistant then 'Assistant'
            when :system then 'System'
            when :error then 'Error'
            else 'Message'
            end

    content_lines = wrap_text(message[:content].to_s, cols)
    content_lines = [''] if content_lines.empty?

    [ "#{label}:", *content_lines, '' ]
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

  def break_word(word, width)
    return [word] if display_width(word) <= width

    chunks = []
    current = +''
    current_width = 0

    word.each_char do |char|
      char_width = display_width(char)
      if current_width.positive? && current_width + char_width > width
        chunks << current
        current = +''
        current_width = 0
      end

      current << char
      current_width += char_width
    end

    chunks << current unless current.empty?
    chunks
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

  def char_width(char)
    codepoint = char.ord
    return 0 if codepoint < 32 || (127..159).cover?(codepoint)
    return 2 if char.match?(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u1100-\u115F\u2329\u232A\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE10-\uFE19\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/u)

    1
  end

  def input_length
    @input_buffer.each_char.count
  end

  def move_input_cursor(delta)
    move_input_cursor_to(@input_cursor + delta)
  end

  def move_input_cursor_to(position)
    @input_cursor = [[position, 0].max, input_length].min
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

  def input_viewport(available_width)
    available_width = [available_width, 0].max
    chars = @input_buffer.each_char.to_a
    widths = chars.map { |char| display_width(char) }
    cursor_index = [[@input_cursor, 0].max, chars.length].min
    cursor_width = widths[0...cursor_index].sum
    total_width = widths.sum

    return [@input_buffer.dup, cursor_width] if total_width <= available_width

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

    (bstate & mask) != 0
  end

  def format_mouse_debug(event)
    parts = [
      "mouse:",
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

  def load_history
    return unless File.exist?(HISTORY_FILE)

    File.readlines(HISTORY_FILE, chomp: true).each do |line|
      next if line.empty?

      @input_history << line
    end
  rescue StandardError
    @input_history = []
  end

  def save_history_entry(entry)
    @input_history << entry
    @input_history = @input_history.last(MAX_HISTORY)
    File.write(HISTORY_FILE, @input_history.join("\n"))
  rescue StandardError
    # History is best-effort only.
  end

  def load_system_prompt
    prompt_file = File.join(Dir.pwd, '.system_prompt')
    return nil unless File.exist?(prompt_file)

    prompt = File.read(prompt_file)
    prompt.strip.empty? ? nil : prompt
  rescue StandardError
    nil
  end

  def shutdown
    @running = false
    close_screen

    return unless @session_thread

    @input_queue.push(type: :shutdown)
    @session_thread.join(0.5)
    @session_thread.kill if @session_thread.alive?
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
end

if __FILE__ == $PROGRAM_NAME
  api_key = ENV['OPENAI_API_KEY'] || ENV['ZAI_API_KEY']
  if api_key.nil? || api_key.empty?
    STDERR.puts 'Error: OPENAI_API_KEY environment variable is not set'
    exit 1
  end

  model = ENV.fetch('OPENAI_MODEL', 'gpt-4o-mini')
  CursesChatApp.new(api_key, model: model).run
end
