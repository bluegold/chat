# frozen_string_literal: true

require 'yaml'

module ChatBackend
  class HistoryStore
    attr_reader :path, :max_entries

    def initialize(path:, max_entries: 1000)
      @path = path
      @max_entries = max_entries
      @entries = []
      load
    end

    def each = @entries.each

    def to_a
      @entries.dup
    end

    def add(entry)
      text = entry.to_s
      return if text.empty?

      @entries << text
      @entries = @entries.last(@max_entries)
      save
      text
    end

    def empty?
      @entries.empty?
    end

    private

    def load
      return unless File.exist?(@path)

      load_serialized_entries || load_legacy_entries
      @entries = @entries.last(@max_entries)
    rescue StandardError
      @entries = []
    end

    def save
      File.write(@path, YAML.dump(@entries))
    rescue StandardError
      # History is best-effort only.
    end

    def load_serialized_entries
      content = File.read(@path)
      return false unless serialized_history?(content)

      entries = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
      return false unless entries.is_a?(Array)

      entries.each do |entry|
        next if entry.nil?

        @entries << entry.to_s
      end

      true
    rescue StandardError
      false
    end

    def load_legacy_entries
      File.readlines(@path, chomp: true).each do |line|
        next if line.empty?

        @entries << line
      end
    rescue StandardError
      @entries = []
    end

    def serialized_history?(content)
      stripped = content.to_s.lstrip
      stripped.start_with?('---', '!')
    end
  end
end
