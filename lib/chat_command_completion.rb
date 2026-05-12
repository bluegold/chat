# frozen_string_literal: true

module ChatApp
  module CommandCompletion
    private

    def complete_input(agent_names:)
      return if response_pending?

      result = command_completion(
        buffer: @input_buffer,
        cursor: @input_cursor,
        agent_names: agent_names
      )
      return unless result

      @input_buffer = result[:buffer]
      @input_cursor = result[:cursor]
      @notice_message = result[:notice]
    end

    def command_completion(buffer:, cursor:, agent_names:)
      context = command_completion_context(buffer, cursor, agent_names)
      return nil unless context

      candidates = context[:candidates]
      return completion_result(buffer, cursor, notice: nil) if candidates.empty?

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

    def command_completion_candidates(buffer:, cursor:, agent_names:)
      context = command_completion_context(buffer, cursor, agent_names)
      context ? context[:candidates] : []
    end

    def completion_result(buffer, cursor, notice:)
      {
        buffer: buffer,
        cursor: cursor,
        notice: notice
      }
    end

    def command_completion_context(buffer, cursor, agent_names)
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
        candidates = Array(agent_names).map(&:to_s).select { |name| name.start_with?(fragment) }.map { |name| "#{name} " }
        {
          range: (cursor - fragment.length)...cursor,
          fragment: fragment,
          candidates: candidates
        }
      end
    end

    def command_replacements(prefix)
      commands = []
      commands << '/agent ' if 'agent'.start_with?(prefix.to_s)
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
  end
end
