# frozen_string_literal: true

require 'find'
require 'pathname'
require 'ruby_llm'

module ChatApp
  module LocalTools
    IGNORED_DIRS = %w[.git .hg .svn node_modules vendor tmp log coverage].freeze
    MAX_FILE_LINES = 200
    MAX_SEARCH_RESULTS = 20

    def self.register(klass)
      registered_tools[klass.tool_name] = klass
      klass
    end

    def self.tool_class(name)
      registered_tools[name.to_s]
    end

    def self.registered_tools
      @registered_tools ||= {}
    end

    class BaseTool < RubyLLM::Tool
      class << self
        def tool_name(value = nil)
          if value.nil?
            @tool_name
          else
            @tool_name = value.to_s
          end
        end
      end

      def name
        self.class.tool_name || super
      end

      protected

      def expand_root(root)
        base = root.to_s.strip.empty? ? Dir.pwd : File.expand_path(root.to_s, Dir.pwd)
        raise ArgumentError, "root does not exist: #{base}" unless Dir.exist?(base)

        base
      end

      def expand_path(path, root:)
        base = expand_root(root)
        candidate = File.expand_path(path.to_s, base)
        return candidate if candidate == base || candidate.start_with?("#{base}#{File::SEPARATOR}")

        raise ArgumentError, "path escapes root: #{path}"
      end

      def relative_path(path, root)
        base = Pathname.new(expand_root(root))
        Pathname.new(path).relative_path_from(base).to_s
      rescue StandardError
        path.to_s
      end

      def text_file?(path)
        return false unless File.file?(path)

        sample = File.binread(path, 1024)
        !sample.include?("\x00")
      rescue StandardError
        false
      end

      def format_lines(lines, start_line:)
        Array(lines).each_with_index.map do |line, index|
          number = start_line + index
          format('%<number>5d | %<line>s', number: number, line: line)
        end.join("\n")
      end
    end

    class SearchFilesTool < BaseTool
      tool_name 'search_files'
      description 'Search file and directory names under a root directory.'
      param :query, desc: 'Substring to match against relative paths.'
      param :root, required: false, desc: 'Search root directory.'
      param :limit, type: 'integer', required: false, desc: 'Maximum results.'

      def execute(query:, root: '.', limit: MAX_SEARCH_RESULTS)
        query = query.to_s.strip
        return "No query given." if query.empty?

        root = expand_root(root)
        needle = query.downcase
        matches = []

        Find.find(root) do |path|
          prune_ignored_dirs(path)
          next if path == root

          rel = relative_path(path, root)
          basename = File.basename(path)
          next unless rel.downcase.include?(needle) || basename.downcase.include?(needle)

          matches << rel
          break if matches.length >= limit.to_i
        end

        format_match_list(matches, root: root, label: 'files')
      end

      private

      def prune_ignored_dirs(path)
        return unless File.directory?(path)
        return unless IGNORED_DIRS.include?(File.basename(path))

        Find.prune
      end

      def format_match_list(matches, root:, label:)
        return "No #{label} found." if matches.empty?

        lines = ["Found #{matches.length} #{label} under #{root}:"]
        lines.concat(matches.map { |match| "- #{match}" })
        lines.join("\n")
      end
    end

    class SearchTextTool < BaseTool
      tool_name 'search_text'
      description 'Search text content under a root directory.'
      param :query, desc: 'Substring to find in file contents.'
      param :root, required: false, desc: 'Search root directory.'
      param :limit, type: 'integer', required: false, desc: 'Maximum results.'

      def execute(query:, root: '.', limit: MAX_SEARCH_RESULTS)
        query = query.to_s
        return "No query given." if query.strip.empty?

        root = expand_root(root)
        matches = []

        Find.find(root) do |path|
          prune_ignored_dirs(path)
          next unless text_file?(path)

          File.readlines(path, chomp: true).each_with_index do |line, index|
            next unless line.include?(query)

            matches << format(
              '%<path>s:%<line>d: %<content>s',
              path: relative_path(path, root),
              line: index + 1,
              content: line
            )
            break if matches.length >= limit.to_i
          end
          break if matches.length >= limit.to_i
        end

        format_match_list(matches, root: root, label: 'matches')
      end

      private

      def prune_ignored_dirs(path)
        return unless File.directory?(path)
        return unless IGNORED_DIRS.include?(File.basename(path))

        Find.prune
      end

      def format_match_list(matches, root:, label:)
        return "No #{label} found." if matches.empty?

        lines = ["Found #{matches.length} #{label} under #{root}:"]
        lines.concat(matches.map { |match| "- #{match}" })
        lines.join("\n")
      end
    end

    class ReadFileTool < BaseTool
      tool_name 'read_file'
      description 'Read a file, optionally within a line range.'
      param :path, desc: 'Path to read relative to the root directory.'
      param :root, required: false, desc: 'Base directory.'
      param :start_line, type: 'integer', required: false, desc: 'First line to read.'
      param :end_line, type: 'integer', required: false, desc: 'Last line to read.'
      param :limit_lines, type: 'integer', required: false, desc: 'Maximum number of lines to return.'

      def execute(path:, root: '.', start_line: nil, end_line: nil, limit_lines: MAX_FILE_LINES)
        absolute = expand_path(path, root:)
        return "File not found: #{relative_path(absolute, expand_root(root))}" unless File.file?(absolute)

        root_path = expand_root(root)
        selected, from, to, total_lines = select_file_lines(
          absolute,
          start_line:,
          end_line:,
          limit_lines:
        )
        header = "#{relative_path(absolute, root_path)} (#{from}-#{[from + selected.length - 1, to].min}/#{total_lines})"
        body = format_lines(selected, start_line: from)
        [header, body].reject(&:empty?).join("\n")
      rescue StandardError => e
        "Error reading file: #{e.class}: #{e.message}"
      end

      private

      def select_file_lines(absolute, start_line:, end_line:, limit_lines:)
        lines = File.readlines(absolute, chomp: true)
        from = start_line.to_s.strip.empty? ? 1 : [start_line.to_i, 1].max
        to = end_line.to_s.strip.empty? ? lines.length : end_line.to_i
        to = lines.length if to <= 0
        to = [to, lines.length].min

        selected = lines[(from - 1)...to] || []
        selected = selected.first(limit_lines.to_i) if limit_lines.to_i.positive?

        [selected, from, to, lines.length]
      end
    end

    class ListDirTool < BaseTool
      tool_name 'list_dir'
      description 'List entries in a directory.'
      param :path, required: false, desc: 'Directory path relative to the root directory.'
      param :root, required: false, desc: 'Base directory.'
      param :limit, type: 'integer', required: false, desc: 'Maximum entries to return.'

      def execute(path: '.', root: '.', limit: 100)
        absolute = expand_path(path, root:)
        return "Directory not found: #{relative_path(absolute, expand_root(root))}" unless Dir.exist?(absolute)

        entries = Dir.children(absolute).sort
        entries = entries.first(limit.to_i) if limit.to_i.positive?
        entries = entries.map do |entry|
          full = File.join(absolute, entry)
          suffix = File.directory?(full) ? '/' : ''
          "- #{entry}#{suffix}"
        end

        header = "Listing #{relative_path(absolute, expand_root(root))}:"
        [header, *entries].join("\n")
      rescue StandardError => e
        "Error listing directory: #{e.class}: #{e.message}"
      end
    end

    register SearchFilesTool
    register SearchTextTool
    register ReadFileTool
    register ListDirTool
  end
end
