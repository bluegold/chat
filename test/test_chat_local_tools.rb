# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../lib/backend/chat_backend'

class ChatBackendLocalToolsTest < Minitest::Test
  def test_search_tools_expose_multiple_features
    assert ChatApp::LocalTools::SearchFilesTool.supports_feature?(:filesystem)
    assert ChatApp::LocalTools::SearchFilesTool.supports_feature?(:search)
    refute ChatApp::LocalTools::SearchFilesTool.supports_feature?(:memory)
  end

  def test_local_tools_can_be_filtered_by_feature
    tool_names = ChatApp::LocalTools.tool_classes_for_feature(:filesystem).map(&:tool_name)

    assert_equal %w[list_dir read_file search_files search_text], tool_names.sort
  end

  def test_search_tools_describe_query_as_required
    assert_includes ChatApp::LocalTools::SearchFilesTool.description, 'Use list_dir'
    assert_includes ChatApp::LocalTools::SearchTextTool.description, 'Use this when you already know a non-empty substring'
    assert_includes ChatApp::LocalTools::SearchTextTool.description, 'read_file instead'
    assert_includes ChatApp::LocalTools::ReadFileTool.description, 'known file by path'
  end

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

  def test_search_files_tool_rejects_dot_query_in_favor_of_list_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'README.md'), 'hello')

      output = ChatApp::LocalTools::SearchFilesTool.new.call(
        query: '.',
        root: dir,
        limit: 10
      )

      assert_includes output, 'Listing .:'
      assert_includes output, '- README.md'
    end
  end

  def test_search_files_tool_falls_back_to_list_dir_for_empty_query
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'README.md'), 'hello')

      output = ChatApp::LocalTools::SearchFilesTool.new.call(
        query: ' ',
        root: dir,
        limit: 10
      )

      assert_includes output, 'Listing .:'
      assert_includes output, '- README.md'
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

  def test_search_text_tool_searches_within_file_root
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'README.md'), 'needle')

      output = ChatApp::LocalTools::SearchTextTool.new.call(
        query: 'needle',
        root: File.join(dir, 'README.md'),
        limit: 10
      )

      assert_includes output, 'Found 1 matches under'
      assert_includes output, 'README.md:1: needle'
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

  def test_read_file_tool_reports_continuation_when_truncated
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'notes.txt')
      File.write(path, "one\ntwo\nthree\nfour\n")

      output = ChatApp::LocalTools::ReadFileTool.new.call(
        path: 'notes.txt',
        root: dir,
        start_line: 1,
        end_line: 4,
        limit_lines: 2
      )

      assert_includes output, 'notes.txt (1-2/4)'
      assert_includes output, '    1 | one'
      assert_includes output, '    2 | two'
      assert_includes output, 'Truncated. Continue with start_line: 3'
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
