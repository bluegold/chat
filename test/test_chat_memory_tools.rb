# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../lib/chat_backend'
require_relative '../lib/chat_memory_tools'

class ChatBackendMemoryToolsTest < Minitest::Test
  def test_memory_tools_expose_multiple_features
    assert ChatApp::MemoryTools::SearchTool.supports_feature?(:memory)
    assert ChatApp::MemoryTools::SearchTool.supports_feature?(:search)
    refute ChatApp::MemoryTools::SearchTool.supports_feature?(:runtime)
  end

  def test_memory_tools_can_be_filtered_by_feature
    tool_names = ChatApp::MemoryTools.tool_classes_for_feature(:write).map(&:tool_name)

    assert_equal %w[memory_add memory_forget], tool_names.sort
  end

  def with_memory_workspace
    Dir.mktmpdir do |workspace|
      project_dir = File.join(workspace, 'project')
      home_dir = File.join(workspace, 'home')
      FileUtils.mkdir_p(project_dir)
      FileUtils.mkdir_p(home_dir)

      original_home = Dir.home
      Dir.chdir(project_dir) do
        ENV['HOME'] = home_dir
        yield(project_dir, home_dir)
      ensure
        ENV['HOME'] = original_home
      end
    end
  end

  def add_project_memory
    ChatApp::MemoryTools::AddTool.new.call(
      content: 'remember this line',
      title: 'Project note',
      scope: 'project'
    )
  end

  def test_add_project_memory_writes_a_note
    with_memory_workspace do
      added = add_project_memory

      assert_includes added, 'Saved memory'
      assert_match(/Saved memory (\S+) in project memory:/, added)
    end
  end

  def test_search_project_memory_finds_matching_text
    with_memory_workspace do
      add_project_memory

      search = ChatApp::MemoryTools::SearchTool.new.call(
        query: 'remember',
        scope: 'project',
        limit: 10
      )

      assert_includes search, 'Found 1 memory matches:'
      assert_includes search, 'remember this line'
    end
  end

  def test_list_project_memory_shows_notes
    with_memory_workspace do
      add_project_memory

      list = ChatApp::MemoryTools::ListTool.new.call(scope: 'project', limit: 10)

      assert_includes list, 'Memory notes in project memory:'
      assert_includes list, 'Project note'
    end
  end

  def test_read_project_memory_returns_note_content
    with_memory_workspace do
      added = add_project_memory
      note_id = added[/Saved memory (\S+) in/, 1]

      refute_nil note_id

      read = ChatApp::MemoryTools::ReadTool.new.call(note_id: note_id, scope: 'project')

      assert_includes read, 'remember this line'
    end
  end

  def test_forget_project_memory_deletes_note
    with_memory_workspace do
      added = add_project_memory
      note_id = added[/Saved memory (\S+) in/, 1]

      refute_nil note_id

      deleted = ChatApp::MemoryTools::ForgetTool.new.call(note_id: note_id, scope: 'project')

      assert_includes deleted, 'Deleted memory note(s):'

      empty_search = ChatApp::MemoryTools::SearchTool.new.call(
        query: 'remember',
        scope: 'project',
        limit: 10
      )

      assert_includes empty_search, 'No memory matches for "remember".'
    end
  end

  def test_search_can_see_global_memory
    with_memory_workspace do
      ChatApp::MemoryTools::AddTool.new.call(
        content: 'global preference',
        title: 'Global note',
        scope: 'global'
      )

      output = ChatApp::MemoryTools::SearchTool.new.call(
        query: 'preference',
        scope: 'both',
        limit: 10
      )

      assert_includes output, 'global:'
      assert_includes output, 'global preference'
    end
  end
end
