# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'

require_relative '../lib/chat_backend'
require_relative '../lib/chat_command_completion'
require_relative '../lib/chat_tool_tracking'
require_relative '../lib/chat_session_status'
require_relative '../lib/chat_session_info'

class ChatBackendHistoryStoreTest < Minitest::Test
  def test_history_store_persists_multiline_entries_and_trims_old_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      store.add("first\nline")
      store.add('second')
      store.add("third\nline")

      assert_equal 'second', store.to_a.first
      assert_equal "third\nline", store.to_a.last
    end
  end

  def test_history_store_serializes_multiline_entries_as_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      store.add("first\nline")
      store.add('second')
      store.add("third\nline")

      contents = File.read(path)

      assert_match(/\A---\n/, contents)
      assert_includes contents, "|-\n  third\n  line"
    end
  end

  def test_history_store_reloads_multiline_entries
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      store.add("first\nline")
      store.add('second')
      store.add("third\nline")

      reloaded = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      assert_equal 'second', reloaded.to_a.first
      assert_equal "third\nline", reloaded.to_a.last
    end
  end

  def test_history_store_reads_legacy_line_based_history
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      File.write(path, "first\nsecond\n")

      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      assert_equal %w[first second], store.to_a
    end
  end
end

class ChatBackendTextLayoutTest < Minitest::Test
  def setup
    @layout = Object.new.extend(ChatBackend::TextLayout)
  end

  def test_transcript_lines_format_messages
    lines = @layout.transcript_lines(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ],
      20
    )

    assert_equal [
      '',
      '> hello',
      '',
      '',
      'world',
      ''
    ], lines
  end

  def test_truncate_to_width_respects_double_width_characters
    assert_equal 'あい', @layout.truncate_to_width('あいう', 4)
    assert_equal 'abc', @layout.truncate_to_width('abcd', 3)
  end

  def test_tool_call_text_formats_arguments
    assert_equal(
      "Using tool search_text(query: 'hoge', limit: 10)",
      @layout.tool_call_text('search_text', { query: 'hoge', limit: 10 })
    )
  end
end

class ChatBackendTranscriptTest < Minitest::Test
  def test_transcript_accumulates_output_messages
    transcript = ChatBackend::Transcript.new

    transcript.user_message('hello')
    transcript.apply_output_message(type: :stream_start)
    transcript.apply_output_message(type: :stream_chunk, content: 'wor')
    transcript.apply_output_message(type: :assistant_start)
    transcript.apply_output_message(type: :stream_chunk, content: 'ld')
    transcript.apply_output_message(type: :system_message, content: 'note')
    transcript.apply_output_message(type: :error, message: 'boom')

    assert_equal [
      { role: :user, content: 'hello' },
      { role: :assistant, content: 'world' },
      { role: :system, content: 'note' },
      { role: :error, content: 'boom' }
    ], transcript.messages
  end

  def test_transcript_lines_reads_back_message_buffer
    transcript = ChatBackend::Transcript.new([{ role: :user, content: 'hi' }])

    assert_equal ['', '> hi', ''], transcript.lines(20)
  end

  def test_transcript_formats_tool_call_as_info_line
    transcript = ChatBackend::Transcript.new

    transcript.apply_output_message(
      type: :tool_call,
      name: 'search_text',
      arguments: { query: 'hoge', limit: 10 }
    )

    assert_includes transcript.lines(80), "Using tool search_text(query: 'hoge', limit: 10)"
  end

  def test_transcript_tail_lines_returns_bottom_slice
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['', 'world', ''], transcript.tail_lines(20, 3)
  end

  def test_transcript_window_returns_bottom_window
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['', 'world', ''], transcript.window(20, height: 3, scroll: 0)
  end

  def test_transcript_window_returns_scrolled_window
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['', '', 'world'], transcript.window(20, height: 3, scroll: 1)
  end
end

class ChatBackendStatusTest < Minitest::Test
  def test_status_starts_idle
    status = ChatBackend::Status.new

    refute_predicate status, :pending?
    refute_predicate status, :streaming?
  end

  def test_status_expect_response_marks_pending
    status = ChatBackend::Status.new

    status.expect_response

    assert_predicate status, :pending?
    refute_predicate status, :streaming?
  end

  def test_status_start_response_marks_streaming
    status = ChatBackend::Status.new

    status.expect_response
    status.start_response

    assert_predicate status, :pending?
    assert_predicate status, :streaming?
  end

  def test_status_end_response_clears_state
    status = ChatBackend::Status.new

    status.expect_response
    status.start_response
    status.end_response

    refute_predicate status, :pending?
    refute_predicate status, :streaming?
  end
end

class ChatBackendSessionInfoTest < Minitest::Test
  def build_session_info_object
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: "Be brief\nBe accurate",
      temperature: 0.8,
      tools: %w[search_files read_file]
    )

    object = Object.new
    object.extend(ChatApp::SessionInfo)
    object.instance_variable_set(:@agent, agent)
    object.instance_variable_set(:@status, ChatBackend::Status.new)

    def object.status_code
      'ready'
    end

    def object.response_pending?
      false
    end

    object
  end

  def test_session_info_text_dumps_agent_settings
    data = YAML.safe_load(build_session_info_object.session_info_text, permitted_classes: [], aliases: false)

    assert_equal(
      {
        'name' => 'coder',
        'display_name' => 'ChatGPT',
        'model' => 'gpt-4o-mini',
        'temperature' => 0.8,
        'tool_count' => 2,
        'tools' => %w[search_files read_file]
      },
      data['agent']
    )
  end

  def test_session_info_text_includes_status_and_prompt
    data = YAML.safe_load(build_session_info_object.session_info_text, permitted_classes: [], aliases: false)

    assert_equal 'ready', data['status']['code']
    assert_equal 'Be brief
Be accurate', data['system_prompt']
  end
end

class ChatBackendStatusLineTest < Minitest::Test
  def test_status_line_includes_tool_count
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[search_files read_file]
    )

    object = Object.new
    object.extend(ChatApp::SessionStatus)
    object.extend(ChatApp::SessionInfo)
    object.instance_variable_set(:@agent_name, 'coder')
    object.instance_variable_set(:@agent, agent)
    object.instance_variable_set(:@model, 'gpt-4o-mini')
    object.instance_variable_set(:@status, ChatBackend::Status.new)
    object.instance_variable_set(:@transcript_scroll, 0)
    object.instance_variable_set(:@debug_mouse_enabled, false)
    object.instance_variable_set(:@notice_message, nil)

    assert_includes object.status_line, 'tools: 1(2)'
  end

  def test_status_line_shows_filtered_tool_count_when_hint_matches
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[
        search_files search_text read_file list_dir
        memory_search memory_add memory_list memory_read memory_forget
        run_ruby run_python
      ]
    )

    object = Object.new
    object.extend(ChatApp::SessionStatus)
    object.extend(ChatApp::SessionInfo)
    object.instance_variable_set(:@agent_name, 'coder')
    object.instance_variable_set(:@agent, agent)
    object.instance_variable_set(:@model, 'gpt-4o-mini')
    object.instance_variable_set(:@status, ChatBackend::Status.new)
    object.instance_variable_set(:@transcript_scroll, 0)
    object.instance_variable_set(:@debug_mouse_enabled, false)
    object.instance_variable_set(:@notice_message, nil)

    object.instance_variable_set(:@tool_hint_features, [:filesystem])
    object.instance_variable_get(:@status).expect_response
    object.instance_variable_get(:@status).start_response

    def object.current_input_text
      ''
    end

    assert_includes object.status_line, 'tools: 5(11)'
  end

  def test_status_line_includes_tool_status_message
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: nil,
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: nil,
      tools: %w[search_files read_file]
    )

    object = Object.new
    object.extend(ChatApp::SessionStatus)
    object.extend(ChatApp::ToolTracking)
    object.instance_variable_set(:@agent_name, 'coder')
    object.instance_variable_set(:@agent, agent)
    object.instance_variable_set(:@model, 'gpt-4o-mini')
    object.instance_variable_set(:@status, ChatBackend::Status.new)
    object.instance_variable_set(:@transcript_scroll, 0)
    object.instance_variable_set(:@debug_mouse_enabled, false)
    object.instance_variable_set(:@notice_message, nil)
    object.start_tool_status('search_files')

    assert_includes object.status_line, 'tool: search_files'
  end
end

class ChatBackendCodeExecutionResolveTest < Minitest::Test
  def test_resolve_tool_finds_ruby_code_execution_tool
    session = ChatBackend::SessionThread.allocate

    assert_equal ChatApp::CodeExecutionTools::RunRubyTool, session.send(:resolve_tool, 'run_ruby')
  end
end

class ChatBackendSessionConfigTest < Minitest::Test
  def test_agent_spec_exposes_metadata
    spec = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: 0.8,
      tools: %w[search files]
    )

    assert_equal 'ChatGPT', spec.label
    assert_equal %w[search files], spec.tool_names
  end

  def test_agent_spec_resolves_tool_classes_and_filters_by_feature
    spec = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: 0.8,
      tools: %w[search_files run_ruby]
    )

    assert_equal(
      [ChatApp::LocalTools::SearchFilesTool, ChatApp::CodeExecutionTools::RunRubyTool],
      spec.tool_classes
    )
    assert_equal(
      [ChatApp::LocalTools::SearchFilesTool],
      spec.tool_classes_for_feature(:filesystem)
    )
  end

  def test_agent_spec_uses_baseline_tools_when_no_hint_matches
    spec = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: 0.8,
      tools: %w[search_files search_text read_file list_dir memory_search run_ruby]
    )

    assert_equal(
      [ChatApp::LocalTools::SearchFilesTool, ChatApp::LocalTools::SearchTextTool, ChatApp::MemoryTools::SearchTool],
      spec.tool_classes_for_input('こんにちは')
    )
  end

  def test_session_config_wraps_backend_dependencies
    agent = ChatBackend::AgentSpec.new(
      name: 'default',
      display_name: nil,
      model: 'test-model',
      system_prompt: 'Be brief',
      temperature: 0.2,
      tools: []
    )

    config = ChatBackend::SessionConfig.new(
      input_queue: Queue.new,
      output_queue: Queue.new,
      api_key: 'test-key',
      agent: agent,
      response_sync: ChatBackend::Status.new,
      llm: nil
    )

    assert_equal(
      {
        input_queue: config.input_queue,
        output_queue: config.output_queue,
        api_key: 'test-key',
        agent: agent,
        response_sync: config.response_sync,
        llm: nil
      },
      config.to_h
    )
    assert_in_delta 0.2, config.temperature, 0.0001
  end

  def test_session_config_defaults_llm_client_to_ruby_llm
    agent = ChatBackend::AgentSpec.new(
      name: 'default',
      display_name: nil,
      model: 'test-model',
      system_prompt: nil,
      temperature: nil,
      tools: []
    )

    config = ChatBackend::SessionConfig.new(
      input_queue: Queue.new,
      output_queue: Queue.new,
      api_key: 'test-key',
      agent: agent,
      response_sync: nil,
      llm: nil
    )

    assert_same RubyLLM, config.llm_client
  end
end

class ChatBackendAgentRegistryTest < Minitest::Test
  def test_agent_registry_loads_names_from_hash_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'myagent.yml')
      File.write(
        path,
        <<~YAML
          ---
          :default_agent: :coder
          :agents:
            :coder:
              :display_name: ChatGPT
              :temperature: 0.8
              :model: gpt-4o-mini
              :system_prompt: |
                Be brief
              :tools:
                - search
            :helper:
              :model: gpt-4o-mini
              :system_prompt: Be kind
        YAML
      )

      registry = ChatBackend::AgentRegistry.load(path: path, env: {})

      assert_equal 'coder', registry.default_agent_name
      assert_equal %w[coder helper], registry.names
    end
  end

  def test_agent_registry_loads_agent_label_and_temperature_from_hash_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'myagent.yml')
      File.write(
        path,
        <<~YAML
          ---
          :default_agent: :coder
          :agents:
            :coder:
              :display_name: ChatGPT
              :temperature: 0.8
              :model: gpt-4o-mini
              :system_prompt: |
                Be brief
              :tools:
                - search
            :helper:
              :model: gpt-4o-mini
              :system_prompt: Be kind
        YAML
      )

      registry = ChatBackend::AgentRegistry.load(path: path, env: {})

      assert_equal 'ChatGPT', registry['coder'].label
      assert_in_delta 0.8, registry['coder'].temperature, 0.0001
    end
  end

  def test_agent_registry_loads_agent_prompt_and_tools_from_hash_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'myagent.yml')
      File.write(
        path,
        <<~YAML
          ---
          :default_agent: :coder
          :agents:
            :coder:
              :display_name: ChatGPT
              :temperature: 0.8
              :model: gpt-4o-mini
              :system_prompt: |
                Be brief
              :tools:
                - search
            :helper:
              :model: gpt-4o-mini
              :system_prompt: Be kind
        YAML
      )

      registry = ChatBackend::AgentRegistry.load(path: path, env: {})

      assert_equal 'Be brief', registry['coder'].system_prompt
      assert_equal %w[search], registry['coder'].tool_names
    end
  end
end

class ChatBackendSessionThreadTest < Minitest::Test
  FakeConfig = Struct.new(:openai_api_key, :default_model)

  class FakeChat
    attr_reader :instructions, :messages, :asked_content, :tools

    def initialize(chunks, response_text, tool_name: nil, tool_result: 'tool-result')
      @chunks = chunks
      @response_text = response_text
      @tool_name = tool_name
      @tool_result = tool_result
      @messages = []
      @tools = []
      @before_tool_call = nil
      @after_tool_result = nil
    end

    def with_instructions(text)
      @instructions = text
      self
    end

    def with_tool(tool, **)
      @tools << tool
      self
    end

    def before_tool_call(&block)
      @before_tool_call = block
      self
    end

    def after_tool_result(&block)
      @after_tool_result = block
      self
    end

    def add_message(role:, content:)
      @messages << { role: role, content: content }
    end

    def ask(content, &)
      @asked_content = content
      if @tool_name
        tool_call = Struct.new(:name, :arguments, :id).new(@tool_name, { 'path' => 'README.md' }, 'tool-1')
        @before_tool_call&.call(tool_call)
        @after_tool_result&.call(@tool_result)
      end
      @chunks.each(&)
      Struct.new(:content).new(@response_text)
    end
  end

  class FakeLLM
    attr_reader :configured, :chat_instance

    def initialize(chunks:, response_text:, tool_name: nil, tool_result: 'tool-result')
      @configured = FakeConfig.new
      @chat_instance = FakeChat.new(chunks, response_text, tool_name:, tool_result:)
    end

    def configure
      yield @configured
    end

    def chat
      @chat_instance
    end
  end

  def drain_queue(queue)
    items = []
    loop do
      items << queue.pop(true)
    rescue ThreadError
      break
    end
    items
  end

  def build_session(input_queue, output_queue, llm)
    ChatBackend::SessionThread.new(
      ChatBackend::SessionConfig.new(
        input_queue: input_queue,
        output_queue: output_queue,
        api_key: 'test-key',
        agent: ChatBackend::AgentSpec.new(
          name: 'default',
          display_name: nil,
          model: 'test-model',
          system_prompt: 'Be brief',
          temperature: nil,
          tools: []
        ),
        response_sync: nil,
        llm: llm
      )
    )
  end

  def test_session_thread_replays_system_prompt_and_configures_llm
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')

    session = build_session(input_queue, output_queue, llm)

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    assert_equal 'test-key', llm.configured.openai_api_key
    assert_equal 'test-model', llm.configured.default_model
    assert_equal 'Be brief', llm.chat_instance.instructions
  end

  def test_session_thread_resolves_local_file_tools_from_agent_spec
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')
    agent = ChatBackend::AgentSpec.new(
      name: 'default',
      display_name: nil,
      model: 'test-model',
      system_prompt: 'Be brief',
      temperature: nil,
      tools: ['search_files']
    )

    session = ChatBackend::SessionThread.new(
      ChatBackend::SessionConfig.new(
        input_queue: input_queue,
        output_queue: output_queue,
        api_key: 'test-key',
        agent: agent,
        response_sync: nil,
        llm: llm
      )
    )

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    assert_equal [ChatApp::LocalTools::SearchFilesTool], llm.chat_instance.tools
  end

  def test_session_thread_replays_history_and_asked_content
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')

    session = build_session(input_queue, output_queue, llm)

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    assert_equal [], llm.chat_instance.messages
    assert_equal 'Hi', llm.chat_instance.asked_content
  end

  def test_session_thread_emits_stream_events
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')

    session = build_session(input_queue, output_queue, llm)

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    events = drain_queue(output_queue)

    assert_equal(
      %i[
        stream_start
        assistant_start
        stream_chunk
        stream_chunk
        stream_end
      ],
      events.map { |event| event[:type] }
    )
  end

  def test_session_thread_emits_chunk_payloads
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')

    session = build_session(input_queue, output_queue, llm)

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    events = drain_queue(output_queue)

    assert_equal(
      %w[Hel lo],
      events.select { |event| event[:type] == :stream_chunk }.map { |event| event[:content] }
    )
  end

  def test_session_thread_emits_tool_events
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello', tool_name: 'search_files')

    session = build_session(input_queue, output_queue, llm)

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    events = drain_queue(output_queue)

    assert_includes events.map { |event| event[:type] }, :tool_call
    assert_includes events.map { |event| event[:type] }, :tool_result
  end
end

class ChatBackendCommandCompletionTest < Minitest::Test
  def setup
    @completion = Object.new.extend(ChatApp::CommandCompletion)
  end

  def test_command_completion_expands_short_command_prefix
    result = @completion.send(
      :command_completion,
      buffer: '/a',
      cursor: 2,
      agent_names: %w[coder helper]
    )

    assert_equal '/agent ', result[:buffer]
    assert_equal 7, result[:cursor]
  end

  def test_command_completion_expands_agent_name
    result = @completion.send(
      :command_completion,
      buffer: '/agent h',
      cursor: 8,
      agent_names: %w[coder helper]
    )

    assert_equal '/agent helper ', result[:buffer]
    assert_equal 14, result[:cursor]
  end

  def test_command_completion_expands_session_info_command
    result = @completion.send(
      :command_completion,
      buffer: '/se',
      cursor: 3,
      agent_names: %w[coder helper]
    )

    assert_equal '/session_info', result[:buffer]
    assert_equal 13, result[:cursor]
  end
end
