# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'thread'

require_relative 'chat_backend'

class ChatBackendHistoryStoreTest < Minitest::Test
  def test_history_store_persists_entries_and_trims_old_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.chat_history')
      store = ChatBackend::HistoryStore.new(path: path, max_entries: 2)

      store.add('first')
      store.add('second')
      store.add('third')

      assert_equal ['second', 'third'], store.to_a
      assert_equal "second\nthird", File.read(path)

      reloaded = ChatBackend::HistoryStore.new(path: path, max_entries: 2)
      assert_equal ['second', 'third'], reloaded.to_a
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

class ChatBackendResponseSyncTest < Minitest::Test
  def test_response_flags_follow_state_transitions
    sync = ChatBackend::ResponseSync.new

    refute sync.pending?
    refute sync.streaming?

    sync.expect_response
    assert sync.pending?
    refute sync.streaming?

    sync.start_response
    assert sync.pending?
    assert sync.streaming?

    sync.end_response
    refute sync.pending?
    refute sync.streaming?
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

    def ask(content)
      @asked_content = content
      @chunks.each { |chunk| yield(chunk) }
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

  def test_session_thread_streams_chunks_and_replays_system_prompt
    input_queue = Queue.new
    output_queue = Queue.new
    llm = FakeLLM.new(chunks: ['Hel', 'lo'], response_text: 'Hello')

    session = ChatBackend::SessionThread.new(
      input_queue,
      output_queue,
      'test-key',
      'test-model',
      'Be brief',
      nil,
      llm: llm
    )

    input_queue << { type: :user_message, content: 'Hi' }
    input_queue << { type: :shutdown }
    session.join(1)

    events = drain_queue(output_queue)

    assert_equal 'test-key', llm.configured.openai_api_key
    assert_equal 'test-model', llm.configured.default_model
    assert_equal 'Be brief', llm.chat_instance.instructions
    assert_equal [], llm.chat_instance.messages
    assert_equal 'Hi', llm.chat_instance.asked_content
    assert_equal [
      :stream_start,
      :assistant_start,
      :stream_chunk,
      :stream_chunk,
      :stream_end
    ], events.map { |event| event[:type] }
    assert_equal ['Hel', 'lo'], events.select { |event| event[:type] == :stream_chunk }.map { |event| event[:content] }
  end
end
