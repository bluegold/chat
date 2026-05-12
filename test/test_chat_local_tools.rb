# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../lib/chat_backend'

class ChatBackendLocalToolsTest < Minitest::Test
  def test_search_files_tool_finds_matching_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/user.rb'), 'class User; end')
      File.write(File.join(dir, 'README.md'), 'hello')

      output = ChatApp::LocalTools::SearchFilesTool.new.call(
        query: 'user',
        root: dir,
        limit: 10
      )

      assert_includes output, 'Found 1 files under'
      assert_includes output, 'app/models/user.rb'
    end
  end

  def test_search_text_tool_finds_matching_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/user.rb'), "class User\n  # needle\nend\n")

      output = ChatApp::LocalTools::SearchTextTool.new.call(
        query: 'needle',
        root: dir,
        limit: 10
      )

      assert_includes output, 'Found 1 matches under'
      assert_includes output, 'app/models/user.rb:2:   # needle'
    end
  end

  def test_read_file_tool_reads_selected_range
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'notes.txt')
      File.write(path, "one\ntwo\nthree\n")

      output = ChatApp::LocalTools::ReadFileTool.new.call(
        path: 'notes.txt',
        root: dir,
        start_line: 2,
        end_line: 3
      )

      assert_includes output, 'notes.txt (2-3/3)'
      assert_includes output, '    2 | two'
      assert_includes output, '    3 | three'
    end
  end

  def test_list_dir_tool_lists_directory_entries
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app'))
      File.write(File.join(dir, 'README.md'), 'hello')

      output = ChatApp::LocalTools::ListDirTool.new.call(
        path: '.',
        root: dir
      )

      assert_includes output, 'Listing .:'
      assert_includes output, '- README.md'
      assert_includes output, '- app/'
    end
  end
end
