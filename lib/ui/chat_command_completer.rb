# frozen_string_literal: true

module ChatApp
  class CommandCompleter
    def initialize(agent_names)
      @agent_names = Array(agent_names).map(&:to_s)
    end

    def complete(buffer, cursor)
      context = command_completion_context(buffer, cursor)
      return nil unless context

      candidates = context[:candidates]
      return completion_result(buffer, cursor, notice: nil) if candidates.empty?
      return completion_result(buffer, cursor, notice: ambiguous_notice(candidates)) if context[:fragment].empty? && candidates.length > 1

      replacement = if candidates.length == 1
                      candidates.first
                    else
                      longest_common_prefix(candidates)
                    end

      if replacement.length <= context[:fragment].length
        return completion_result(buffer, cursor, notice: ambiguous_notice(candidates))
      end

      new_buffer = buffer.dup
      new_buffer[context[:range]] = replacement
      completion_result(new_buffer, context[:range].begin + replacement.length, notice: nil)
    end

    def candidates(buffer, cursor)
      context = command_completion_context(buffer, cursor)
      context ? context[:candidates] : []
    end

    private

    def command_completion_context(buffer, cursor)
      before = buffer.to_s[0...cursor]
      return nil unless before&.start_with?('/')

      if (match = before.match(%r{\A/([^\s]*)\z}))
        fragment = match[1]
        candidates = command_replacements(fragment)
        {
          range: 0...cursor,
          fragment: fragment,
          candidates: candidates
        }
      elsif (match = before.match(%r{\A/agent\s+(\S*)\z}))
        fragment = match[1]
        candidates = @agent_names.select { |name| name.start_with?(fragment) }.map { |name| "#{name} " }
        {
          range: (cursor - fragment.length)...cursor,
          fragment: fragment,
          candidates: candidates
        }
      end
    end

    def command_replacements(prefix)
      if prefix.to_s.empty?
        return %w[/agent /agent_info /api_dump /instructions /session_info /exit]
      end

      commands = []
      commands << '/agent ' if 'agent'.start_with?(prefix.to_s)
      commands << '/agent_info' if 'agent_info'.start_with?(prefix.to_s) && prefix.to_s.start_with?('agent_')
      commands << '/api_dump' if 'api_dump'.start_with?(prefix.to_s) && prefix.to_s.start_with?('api')
      commands << '/instructions' if 'instructions'.start_with?(prefix.to_s)
      commands << '/session_info' if 'session_info'.start_with?(prefix.to_s)
      commands << '/exit' if 'exit'.start_with?(prefix.to_s)
      commands
    end

    def longest_common_prefix(strings)
      return '' if strings.empty?

      prefix = strings.first.dup
      strings.drop(1).each do |string|
        prefix = prefix[0...-1] until string.start_with?(prefix) || prefix.empty?
      end
      prefix
    end

    def ambiguous_notice(candidates)
      "completions: #{candidates.join(', ')}"
    end

    def completion_result(buffer, cursor, notice:)
      {
        buffer: buffer,
        cursor: cursor,
        notice: notice
      }
    end
  end
end
