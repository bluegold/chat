# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/ui/chat_history_navigator'

class ChatHistoryNavigatorTest < Minitest::Test
  class FakeHistoryStore
    def initialize(entries)
      @entries = entries
    end

    def to_a
      @entries
    end
  end

  def test_empty_history_returns_buffer
    store = FakeHistoryStore.new([])
    navigator = ChatApp::HistoryNavigator.new(store)

    assert_equal 'hello', navigator.recall(:up, 'hello')
    assert_equal 'hello', navigator.recall(:down, 'hello')
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_navigate_up_and_down
    store = FakeHistoryStore.new(%w[first second third])
    navigator = ChatApp::HistoryNavigator.new(store)

    # 1. Start up
    assert_equal 'third', navigator.recall(:up, 'current draft')

    assert_equal 'current draft', navigator.draft
    assert_equal 2, navigator.index

    # 2. Up again
    assert_equal 'second', navigator.recall(:up, 'third')

    assert_equal 1, navigator.index

    # 3. Up again
    assert_equal 'first', navigator.recall(:up, 'second')

    assert_equal 0, navigator.index

    # 4. Limit up (stays at index 0)
    assert_equal 'first', navigator.recall(:up, 'first')

    assert_equal 0, navigator.index

    # 5. Down
    assert_equal 'second', navigator.recall(:down, 'first')

    assert_equal 1, navigator.index

    # 6. Down
    assert_equal 'third', navigator.recall(:down, 'second')

    assert_equal 2, navigator.index

    # 7. Down to draft (returns to original draft)
    assert_equal 'current draft', navigator.recall(:down, 'third')

    assert_equal(-1, navigator.index)
    assert_nil navigator.draft
  end

  def test_reset_clears_state
    store = FakeHistoryStore.new(%w[first second])
    navigator = ChatApp::HistoryNavigator.new(store)

    navigator.recall(:up, 'draft')

    assert_equal 1, navigator.index

    navigator.reset

    assert_equal(-1, navigator.index)
    assert_nil navigator.draft
  end
  # rubocop:enable Minitest/MultipleAssertions
end
