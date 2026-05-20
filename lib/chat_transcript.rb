# frozen_string_literal: true

require_relative 'chat_text_layout'

module ChatBackend
  class Transcript
    include TextLayout

    attr_reader :messages

    def initialize(messages = [])
      @messages = Array(messages).map do |message|
        {
          role: message[:role],
          content: message[:content].to_s
        }
      end
    end

    def user_message(content)
      append_message(:user, content)
    end

    def assistant_start
      return if last_role == :assistant

      append_message(:assistant, +'')
    end

    def assistant_chunk(content)
      text = content.to_s
      return if text.empty?

      assistant_start if last_role != :assistant
      @messages[-1][:content] << text
    end

    def system_message(content)
      append_message(:system, content)
    end

    def info_message(content)
      append_message(:info, content)
    end

    def error_message(content)
      append_message(:error, content)
    end

    def apply_output_message(msg)
      case msg[:type]
      when :stream_start, :assistant_start
        assistant_start
      when :stream_chunk
        assistant_chunk(msg[:content])
      when :system_message
        system_message(msg[:content])
      when :info_message
        info_message(msg[:content])
      when :tool_call
        info_message(tool_call_text(msg[:name], msg[:arguments]))
      when :error
        error_message(msg[:message])
      end
    end

    def lines(cols)
      transcript_lines(@messages, cols)
    end

    def line_entries(cols)
      transcript_line_entries(@messages, cols)
    end

    def window_line_entries(cols, scroll: 0, height: nil)
      entries = line_entries(cols)
      height = height.to_i
      return entries if height <= 0

      max_scroll = [entries.length - height, 0].max
      scroll = scroll.to_i.clamp(0, max_scroll)
      start_index = [entries.length - height - scroll, 0].max
      entries[start_index, height] || []
    end

    def tail_lines(cols, count)
      return [] if count.to_i <= 0

      lines(cols).last(count)
    end

    def window(cols, scroll: 0, height: nil)
      lines = self.lines(cols)
      height = height.to_i
      return lines if height <= 0

      max_scroll = [lines.length - height, 0].max
      scroll = scroll.to_i.clamp(0, max_scroll)
      start_index = [lines.length - height - scroll, 0].max
      lines[start_index, height] || []
    end

    private

    def append_message(role, content)
      @messages << { role: role, content: content.to_s }
    end

    def last_role
      @messages.empty? ? nil : @messages[-1][:role]
    end
  end
end
