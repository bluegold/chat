# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'yaml'

require_relative '../lib/backend/chat_backend'
require_relative '../lib/tools/chat_tool_tracking'
require_relative '../lib/ui/chat_session_info'

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
    object.instance_variable_set(:@status, ChatBackend::Status.new)
    object.instance_variable_set(
      :@session_controller,
      Struct.new(:agent, :instruction_source_paths, :transcript, :session_title).new(
        agent,
        [],
        ChatBackend::Transcript.new,
        nil
      )
    )

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

    assert_equal 'coder', data['agent']
  end

  def test_session_info_text_includes_status_and_prompt
    data = YAML.safe_load(build_session_info_object.session_info_text, permitted_classes: [], aliases: false)

    assert_nil data['title']
    assert_equal 0, data['summary']['turn_count']
    assert_equal 0, data['summary']['tool_call_count']
    assert_equal 'ready', data['status']['code']
    refute data.key?('system_prompt')
  end

  def test_session_info_text_counts_turns_and_tool_calls
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: 'Be brief',
      temperature: 0.8,
      tools: []
    )

    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'first' },
        { role: :assistant, content: 'one' },
        { role: :user, content: 'second' },
        { role: :info, content: 'Using tool search_files(path: "README.md")' },
        { role: :assistant, content: 'two' }
      ]
    )

    object = Object.new
    object.extend(ChatApp::SessionInfo)
    object.instance_variable_set(:@status, ChatBackend::Status.new)
    object.instance_variable_set(
      :@session_controller,
      Struct.new(:agent, :instruction_source_paths, :transcript, :session_title).new(
        agent,
        [],
        transcript,
        'chat-title'
      )
    )

    def object.status_code
      'ready'
    end

    def object.response_pending?
      false
    end

    data = YAML.safe_load(object.session_info_text, permitted_classes: [], aliases: false)

    assert_equal 'chat-title', data['title']
    assert_equal 2, data['summary']['turn_count']
    assert_equal 1, data['summary']['tool_call_count']
    assert_equal 'coder', data['agent']
  end

  def test_instructions_info_text_exposes_sources
    data = YAML.safe_load(build_session_info_object.instructions_info_text, permitted_classes: [], aliases: false)

    assert_equal 'coder', data['agent']['name']
    assert_equal 'ChatGPT', data['agent']['display_name']
    assert_equal 'Be brief
Be accurate', data['system_prompt']
    assert_equal [], data['instruction_messages']
  end

  def test_agent_info_text_exposes_agent_summary
    agent = ChatBackend::AgentSpec.new(
      name: 'coder',
      display_name: 'ChatGPT',
      model: 'gpt-4o-mini',
      system_prompt: nil,
      temperature: 0.8,
      tools: %w[search_files read_file]
    )

    object = Object.new
    object.extend(ChatApp::SessionInfo)
    object.define_singleton_method(:agent) { agent }

    data = YAML.safe_load(object.agent_info_text, permitted_classes: [], aliases: false)

    assert_equal 'coder', data['name']
    assert_equal 'ChatGPT', data['display_name']
    assert_equal 'gpt-4o-mini', data['model']
    assert_equal 2, data['tool_count']
    assert_equal false, data['system_prompt_present']
    assert_equal 0, data['system_prompt_length']
    refute data.key?('instruction_sources')
  end

  def test_instructions_info_text_includes_separate_agent_messages
    Dir.mktmpdir do |dir|
      agents_path = File.join(dir, 'AGENTS.md')
      File.write(agents_path, "cwd rule\n")

      object = Object.new
      object.extend(ChatApp::SessionInfo)
      object.define_singleton_method(:agent) do
        ChatBackend::AgentSpec.new(
          name: 'coder',
          display_name: 'ChatGPT',
          model: 'gpt-4o-mini',
          system_prompt: 'Be brief',
          temperature: 0.8,
          tools: []
        )
      end
      object.instance_variable_set(:@session_controller, Struct.new(:instruction_source_paths).new([agents_path]))

      data = YAML.safe_load(object.instructions_info_text, permitted_classes: [], aliases: false)

      assert_equal 'coder', data['agent']['name']
      assert_equal 'ChatGPT', data['agent']['display_name']
      assert_equal 'Be brief', data['system_prompt']
      assert_equal 1, data['instruction_messages'].length
      assert_equal 'system', data['instruction_messages'].first['role']
      assert_equal agents_path, data['instruction_messages'].first['path']
      assert_includes data['instruction_messages'].first['content'], 'cwd rule'
    end
  end

  def test_api_dump_state_text_exposes_enabled_state_and_path
    object = Object.new
    object.extend(ChatApp::SessionInfo)
    object.instance_variable_set(
      :@session_controller,
      Struct.new(:api_dump_enabled?, :api_dump_path).new(true, File.expand_path('~/.config/myagent/api_dump.log'))
    )

    data = YAML.safe_load(object.api_dump_state_text, permitted_classes: [], aliases: false)

    assert_equal true, data['api_dump']['enabled']
    assert_equal File.expand_path('~/.config/myagent/api_dump.log'), data['api_dump']['path']
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
        llm: nil,
        archive_base_dir: nil,
        summarizer_agent: nil,
        instruction_source_paths: nil,
        api_dump_path: nil,
        api_dump_enabled_proc: nil
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

      registry = ChatBackend::AgentRegistry.load(path: path, env: {}, cwd: dir)

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

      registry = ChatBackend::AgentRegistry.load(path: path, env: {}, cwd: dir)

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

      registry = ChatBackend::AgentRegistry.load(path: path, env: {}, cwd: dir)

      assert_equal 'Be brief', registry['coder'].system_prompt
      assert_equal %w[search], registry['coder'].tool_names
    end
  end

  def test_agent_registry_keeps_system_prompt_separate_from_instruction_sources
    Dir.mktmpdir do |dir|
      global_agents = File.join(dir, 'global-agents.md')
      project_dir = File.join(dir, 'project')
      nested_dir = File.join(project_dir, 'subdir')
      FileUtils.mkdir_p(nested_dir)
      File.write(global_agents, "global rule\n")
      File.write(File.join(project_dir, 'AGENTS.md'), "project rule\n")
      File.write(File.join(nested_dir, 'AGENTS.md'), "cwd rule\n")

      path = File.join(dir, 'myagent.yml')
      File.write(
        path,
        <<~YAML
          ---
          :default_agent: :coder
          :agents:
            :coder:
              :model: gpt-4o-mini
              :system_prompt: |
                Be brief
        YAML
      )

      registry = ChatBackend::AgentRegistry.load(
        path: path,
        env: { 'MYAGENT_AGENTS_PATH' => global_agents },
        cwd: nested_dir
      )

      assert_equal 'Be brief', registry['coder'].system_prompt
    end
  end

  def test_title_summarizer_does_not_append_agents_md
    Dir.mktmpdir do |dir|
      global_agents = File.join(dir, 'global-agents.md')
      project_dir = File.join(dir, 'project')
      nested_dir = File.join(project_dir, 'subdir')
      FileUtils.mkdir_p(nested_dir)
      File.write(global_agents, "global rule\n")
      File.write(File.join(project_dir, 'AGENTS.md'), "project rule\n")
      File.write(File.join(nested_dir, 'AGENTS.md'), "cwd rule\n")

      path = File.join(dir, 'myagent.yml')
      File.write(
        path,
        <<~YAML
          ---
          :default_agent: :coder
          :agents:
            :title_summarizer:
              :model: gpt-4o-mini
              :system_prompt: |
                Summarize briefly
        YAML
      )

      registry = ChatBackend::AgentRegistry.load(
        path: path,
        env: { 'MYAGENT_AGENTS_PATH' => global_agents },
        cwd: nested_dir
      )

      prompt = registry['title_summarizer'].system_prompt

      assert_equal 'Summarize briefly', prompt
      refute_includes prompt, '[AGENTS.md:'
    end
  end

  def test_agent_registry_instruction_source_paths_are_ordered
    Dir.mktmpdir do |dir|
      global_agents = File.join(dir, 'global-agents.md')
      project_dir = File.join(dir, 'project')
      nested_dir = File.join(project_dir, 'subdir')
      FileUtils.mkdir_p(nested_dir)
      File.write(global_agents, "global rule\n")
      File.write(File.join(project_dir, 'AGENTS.md'), "project rule\n")
      File.write(File.join(nested_dir, 'AGENTS.md'), "cwd rule\n")

      registry = ChatBackend::AgentRegistry.new(
        agents: {
          'coder' => ChatBackend::AgentSpec.new(
            name: 'coder',
            display_name: nil,
            model: 'gpt-4o-mini',
            system_prompt: nil,
            temperature: nil,
            tools: []
          )
        },
        default_agent_name: 'coder'
      )

      paths = registry.instruction_source_paths(cwd: nested_dir, env: { 'MYAGENT_AGENTS_PATH' => global_agents })

      assert_equal [global_agents, File.join(project_dir, 'AGENTS.md'), File.join(nested_dir, 'AGENTS.md')], paths
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
      @after_message = nil
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

    def after_message(&block)
      @after_message = block
      self
    end

    def add_message(role:, content:)
      @messages << { role: role, content: content }
    end

    def ask(content, &)
      @asked_content = content
      response = Struct.new(:role, :content, :tool_call?, :tool_calls).new(
        :assistant,
        @response_text,
        !@tool_name.nil?,
        @tool_name ? {
          'tool-1' => Struct.new(:name, :arguments).new(@tool_name, { 'arg1' => 'val1' })
        } : nil
      )
      if @tool_name
        tool_call = Struct.new(:name, :arguments, :id).new(@tool_name, { 'path' => 'README.md' }, 'tool-1')
        @before_tool_call&.call(tool_call)
        @after_tool_result&.call(@tool_result)
      end
      @chunks.each(&)
      @after_message&.call(response)
      response
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

  def build_session(input_queue, output_queue, llm, instruction_source_paths: nil)
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
        llm: llm,
        instruction_source_paths: instruction_source_paths
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

  def test_session_thread_adds_agents_md_as_separate_message
    Dir.mktmpdir do |dir|
      agents_path = File.join(dir, 'AGENTS.md')
      File.write(agents_path, "extra rule\n")

      input_queue = Queue.new
      output_queue = Queue.new
      llm = FakeLLM.new(chunks: %w[Hel lo], response_text: 'Hello')

      session = build_session(
        input_queue,
        output_queue,
        llm,
        instruction_source_paths: [agents_path]
      )

      input_queue << { type: :user_message, content: 'Hi' }
      input_queue << { type: :shutdown }
      session.join(1)

      assert_equal 'Be brief', llm.chat_instance.instructions
      assert_equal(
        [{ role: :system, content: "[AGENTS.md: #{agents_path}]\nextra rule" }],
        llm.chat_instance.messages
      )
    end
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

  def test_api_dump_recorder_writes_request_and_response_blocks
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'api-dump.log')

      ChatBackend::ApiDumpRecorder.write_start_marker(path, agent: 'coder', model: 'test-model')
      ChatBackend::ApiDumpRecorder.activate(path) do
        ChatBackend::ApiDumpRecorder.record_request(
          sequence: 1,
          method: :post,
          url: 'https://api.example.test/v1/chat/completions',
          request_body: { model: 'test-model' },
          request_headers: { 'Authorization' => 'Bearer secret' }
        )
        response = Struct.new(:role, :content, :tool_call?, :tool_calls).new(
          :assistant,
          'Hello there',
          false,
          nil
        )
        ChatBackend::ApiDumpRecorder.record_response_summary(
          sequence: 1,
          response: response,
          assistant_text: 'Hello there'
        )
      end

      contents = File.read(path)

      assert_includes contents, 'api_dump_start'
      assert_includes contents, 'request #1'
      assert_includes contents, 'response #1'
      assert_match(/^=+\n/m, contents)
      assert_includes contents, '[REDACTED]'
      assert_match(/"model": "test-model"/, contents)
      assert_match(/"kind": "text"/, contents)
      assert_match(/"has_content": true/, contents)
      assert_match(/"content_length": 11/, contents)
    end
  end

  def test_api_dump_recorder_summarizes_tool_calls
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'api-dump.log')

      ChatBackend::ApiDumpRecorder.write_start_marker(path)
      ChatBackend::ApiDumpRecorder.activate(path) do
        tool_call = Struct.new(:name, :arguments).new('search_files', { 'path' => 'README.md' })
        response = Struct.new(:role, :content, :tool_call?, :tool_calls).new(
          :assistant,
          nil,
          true,
          { 'tool-1' => tool_call }
        )

        ChatBackend::ApiDumpRecorder.record_response_summary(
          sequence: 1,
          response: response,
          assistant_text: ''
        )
      end

      contents = File.read(path)

      assert_match(/"kind": "tool_call"/, contents)
      assert_match(/"tool_calls"/, contents)
      assert_match(/search_files/, contents)
    end
  end

end
