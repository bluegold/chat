# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../lib/chat_backend'

class ChatBackendHistoryStoreTest < Minitest::Test
  def test_history_store_persists_entries_and_trims_old_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      store.add('first')
      store.add('second')
      store.add('third')

      assert_equal %w[second third], store.to_a
      assert_equal "second\nthird", File.read(path)

      reloaded = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      assert_equal %w[second third], reloaded.to_a
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
      'You:',
      'hello',
      '',
      'Assistant:',
      'world',
      ''
    ], lines
  end

  def test_truncate_to_width_respects_double_width_characters
    assert_equal 'あい', @layout.truncate_to_width('あいう', 4)
    assert_equal 'abc', @layout.truncate_to_width('abcd', 3)
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

    assert_equal ['You:', 'hi', ''], transcript.lines(20)
  end

  def test_transcript_tail_lines_returns_bottom_slice
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['Assistant:', 'world', ''], transcript.tail_lines(20, 3)
  end

  def test_transcript_window_returns_bottom_window
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['Assistant:', 'world', ''], transcript.window(20, height: 3, scroll: 0)
  end

  def test_transcript_window_returns_scrolled_window
    transcript = ChatBackend::Transcript.new(
      [
        { role: :user, content: 'hello' },
        { role: :assistant, content: 'world' }
      ]
    )

    assert_equal ['', 'Assistant:', 'world'], transcript.window(20, height: 3, scroll: 1)
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

class ChatBackendSessionConfigTest < Minitest::Test
  def test_session_config_wraps_backend_dependencies
    config = ChatBackend::SessionConfig.new(
      input_queue: Queue.new,
      output_queue: Queue.new,
      api_key: 'test-key',
      model: 'test-model',
      system_prompt: 'Be brief',
      response_sync: ChatBackend::Status.new,
      llm: nil
    )

    assert_equal(
      {
        input_queue: config.input_queue,
        output_queue: config.output_queue,
        api_key: 'test-key',
        model: 'test-model',
        system_prompt: 'Be brief',
        response_sync: config.response_sync,
        llm: nil
      },
      config.to_h
    )
  end

  def test_session_config_defaults_llm_client_to_ruby_llm
    config = ChatBackend::SessionConfig.new(
      input_queue: Queue.new,
      output_queue: Queue.new,
      api_key: 'test-key',
      model: 'test-model',
      system_prompt: nil,
      response_sync: nil,
      llm: nil
    )

    assert_same RubyLLM, config.llm_client
  end
end

class ChatBackendSessionThreadTest < Minitest::Test
  FakeConfig = Struct.new(:openai_api_key, :default_model)

  class FakeChat
    attr_reader :instructions, :messages, :asked_content

    def initialize(chunks, response_text)
      @chunks = chunks
      @response_text = response_text
      @messages = []
    end

    def with_instructions(text)
      @instructions = text
      self
    end

    def add_message(role:, content:)
      @messages << { role: role, content: content }
    end

    def ask(content, &)
      @asked_content = content
      @chunks.each(&)
      Struct.new(:content).new(@response_text)
    end
  end

  class FakeLLM
    attr_reader :configured, :chat_instance

    def initialize(chunks:, response_text:)
      @configured = FakeConfig.new
      @chat_instance = FakeChat.new(chunks, response_text)
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
        model: 'test-model',
        system_prompt: 'Be brief',
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
end
