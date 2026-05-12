# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'securerandom'
require 'time'
require 'yaml'
require 'ruby_llm'

module ChatApp
  module MemoryTools
    GLOBAL_MEMORY_ROOT = File.expand_path('~/.config/myagent/memory')
    PROJECT_MEMORY_ROOT_NAME = '.myagent/memory'
    MAX_SEARCH_RESULTS = 20
    MAX_LIST_RESULTS = 50

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

    def self.project_root(pwd = Dir.pwd)
      File.join(pwd, PROJECT_MEMORY_ROOT_NAME)
    end

    def self.global_root(home = Dir.home)
      File.expand_path('~/.config/myagent/memory', home)
    end

    def self.scope_roots(scope, pwd: Dir.pwd, home: Dir.home)
      case scope.to_s
      when 'project'
        [project_root(pwd)]
      when 'global'
        [global_root(home)]
      else
        [project_root(pwd), global_root(home)]
      end
    end

    def self.normalize_scope(scope)
      value = scope.to_s.strip
      return 'project' if value.empty?
      return value if %w[project global both].include?(value)

      'project'
    end

    class Store
      def add(scope:, title:, content:, pwd: Dir.pwd, home: Dir.home)
        scope = MemoryTools.normalize_scope(scope)
        root = note_root(scope, pwd:, home:)
        FileUtils.mkdir_p(root)

        id = generate_note_id
        slug = slugify(title.to_s.empty? ? content.to_s.lines.first.to_s : title.to_s)
        path = File.join(root, "#{id}-#{slug}.md")
        payload = build_note_payload(id:, scope:, title:, content:)
        File.write(path, payload)
        { id: id, scope: scope, title: title.to_s, path: path }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      def list(scope:, limit: MAX_LIST_RESULTS, pwd: Dir.pwd, home: Dir.home)
        files = note_files(scope, pwd:, home:)
        files = files.sort_by { |path| File.mtime(path) }.reverse
        files = files.first(limit.to_i) if limit.to_i.positive?

        files.map do |path|
          metadata = read_note_metadata(path)
          {
            id: metadata[:id],
            scope: metadata[:scope],
            title: metadata[:title],
            path: path
          }
        end
      end

      def read(note_id:, scope:, pwd: Dir.pwd, home: Dir.home)
        files = matching_files(note_id, scope:, pwd:, home:)
        return nil if files.empty?

        path = files.first
        {
          metadata: read_note_metadata(path),
          content: File.read(path),
          path: path
        }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      def forget(note_id:, scope:, pwd: Dir.pwd, home: Dir.home)
        files = matching_files(note_id, scope:, pwd:, home:)
        deleted = []

        files.each do |path|
          File.delete(path)
          deleted << path
        rescue StandardError
          next
        end

        deleted
      end

      def search(query:, scope:, limit: MAX_SEARCH_RESULTS, pwd: Dir.pwd, home: Dir.home)
        query = query.to_s.strip
        return [] if query.empty?

        scope_roots = MemoryTools.scope_roots(scope, pwd:, home:)
        results = []

        scope_roots.each do |root|
          next unless Dir.exist?(root)

          results.concat(search_root(query, root))
          break if results.length >= limit.to_i
        end

        results.first(limit.to_i)
      end

      private

      def note_root(scope, pwd:, home:)
        case MemoryTools.normalize_scope(scope)
        when 'global'
          MemoryTools.global_root(home)
        else
          MemoryTools.project_root(pwd)
        end
      end

      def note_files(scope, pwd:, home:)
        MemoryTools.scope_roots(scope, pwd:, home:).flat_map do |root|
          next [] unless Dir.exist?(root)

          Dir.glob(File.join(root, '*.md'))
        end
      end

      def matching_files(note_id, scope:, pwd:, home:)
        needle = note_id.to_s.strip
        return [] if needle.empty?

        note_files(scope, pwd:, home:).select do |path|
          File.basename(path).include?(needle) || read_note_metadata(path)[:id].to_s.include?(needle)
        end
      end

      def search_root(query, root)
        cmd = [
          'rg', '--no-heading', '--line-number', '--hidden', '--color', 'never', '-i',
          '--glob', '*.md', query, root
        ]
        stdout, _stderr, status = Open3.capture3(*cmd)
        return parse_rg_results(stdout, root) if status.success? || status.exitstatus == 1

        search_root_fallback(query, root)
      rescue Errno::ENOENT
        search_root_fallback(query, root)
      end

      def parse_rg_results(stdout, _root)
        stdout.each_line.filter_map do |line|
          path, line_number, text = line.split(':', 3)
          next unless path && line_number && text

          {
            scope: scope_for_path(path),
            path: path,
            line: line_number.to_i,
            text: text.rstrip
          }
        end
      end

      def search_root_fallback(query, root)
        Dir.glob(File.join(root, '*.md')).flat_map do |path|
          next [] unless File.file?(path)

          File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
            next unless line.downcase.include?(query.downcase)

            {
              scope: scope_for_path(path),
              path: path,
              line: index + 1,
              text: line
            }
          end
        end
      end

      def scope_for_path(path)
        return 'global' if path.start_with?(MemoryTools.global_root, File::SEPARATOR)
        return 'project' if path.start_with?(MemoryTools.project_root, File::SEPARATOR)

        'project'
      end

      def build_note_payload(id:, scope:, title:, content:)
        now = Time.now.utc.iso8601
        normalized_title = title.to_s.strip
        normalized_title = content.to_s.lines.first.to_s.strip if normalized_title.empty?
        normalized_title = 'Untitled memory' if normalized_title.empty?
        body = content.to_s.strip

        <<~MD
          ---
          id: #{id}
          scope: #{scope}
          title: #{normalized_title}
          created_at: #{now}
          ---
          #{body}
        MD
      end

      def read_note_metadata(path)
        return { id: nil, scope: nil, title: nil } unless File.file?(path)

        lines = File.readlines(path, chomp: true)
        return { id: nil, scope: nil, title: nil } unless lines.first == '---'

        metadata = {}
        lines[1..].each do |line|
          break if line == '---'

          key, value = line.split(/:\s*/, 2)
          metadata[key.to_s] = value.to_s if key && value
        end

        {
          id: metadata['id'],
          scope: metadata['scope'],
          title: metadata['title']
        }
      rescue StandardError
        { id: nil, scope: nil, title: nil }
      end

      def generate_note_id
        "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
      end

      def slugify(text)
        slug = text.to_s.downcase
        slug = slug.unicode_normalize(:nfkd)
        slug = slug.encode('ASCII', replace: '')
        slug = slug.gsub(/[^a-z0-9]+/, '-')
        slug = slug.gsub(/^-+|-+$/, '')
        slug.empty? ? 'memory' : slug[0, 60]
      rescue StandardError
        'memory'
      end
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

      def store
        @store ||= Store.new
      end

      def normalize_scope(scope)
        MemoryTools.normalize_scope(scope)
      end
    end

    class SearchTool < BaseTool
      tool_name 'memory_search'
      description 'Search global and project memory notes.'
      param :query, desc: 'Search text.'
      param :scope, required: false, desc: 'project, global, or both.'
      param :limit, type: 'integer', required: false, desc: 'Maximum results.'

      def execute(query:, scope: 'both', limit: MAX_SEARCH_RESULTS)
        results = store.search(query:, scope: normalize_scope(scope), limit:)
        return "No memory matches for #{query.inspect}." if results.empty?

        lines = ["Found #{results.length} memory matches:"]
        lines.concat(results.map do |result|
          "#{result[:scope]}: #{File.basename(result[:path])}:#{result[:line]}: #{result[:text]}"
        end)
        lines.join("\n")
      end
    end

    class AddTool < BaseTool
      tool_name 'memory_add'
      description 'Add a memory note to project or global memory.'
      param :content, desc: 'Memory content.'
      param :title, required: false, desc: 'Optional memory title.'
      param :scope, required: false, desc: 'project or global.'

      def execute(content:, title: nil, scope: 'project')
        note = store.add(scope:, title:, content:)
        return note[:error] if note[:error]

        "Saved memory #{note[:id]} in #{note[:scope]} memory: #{note[:path]}"
      end
    end

    class ListTool < BaseTool
      tool_name 'memory_list'
      description 'List memory notes.'
      param :scope, required: false, desc: 'project, global, or both.'
      param :limit, type: 'integer', required: false, desc: 'Maximum results.'

      def execute(scope: 'both', limit: MAX_LIST_RESULTS)
        notes = store.list(scope:, limit:)
        return "No memory notes found in #{normalize_scope(scope)} memory." if notes.empty?

        lines = ["Memory notes in #{normalize_scope(scope)} memory:"]
        lines.concat(notes.map do |note|
          title = note[:title].to_s.strip
          title = '(untitled)' if title.empty?
          "#{note[:scope]}: #{note[:id]}: #{title}"
        end)
        lines.join("\n")
      end
    end

    class ReadTool < BaseTool
      tool_name 'memory_read'
      description 'Read a memory note by id.'
      param :note_id, desc: 'Memory note id.'
      param :scope, required: false, desc: 'project, global, or both.'

      def execute(note_id:, scope: 'both')
        note = store.read(note_id:, scope: normalize_scope(scope))
        return "No memory note found for #{note_id.inspect}." unless note
        return note[:error] if note[:error]

        note[:content]
      end
    end

    class ForgetTool < BaseTool
      tool_name 'memory_forget'
      description 'Delete a memory note by id.'
      param :note_id, desc: 'Memory note id.'
      param :scope, required: false, desc: 'project, global, or both.'

      def execute(note_id:, scope: 'project')
        deleted = store.forget(note_id:, scope: normalize_scope(scope))
        return "No memory note found for #{note_id.inspect}." if deleted.empty?

        "Deleted memory note(s): #{deleted.join(', ')}"
      end
    end

    register SearchTool
    register AddTool
    register ListTool
    register ReadTool
    register ForgetTool
  end
end
