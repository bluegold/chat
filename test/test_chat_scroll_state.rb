# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/chat_scroll_state'

class ChatBackendScrollStateTest < Minitest::Test
  def setup
    @state = ChatApp::ScrollState.new(visible_height: 10)
  end

  def test_initial_scroll
    assert_equal 0, @state.scroll
    assert_equal 10, @state.visible_height
  end

  def test_scroll_by
    @state.scroll_by(5)

    assert_equal 5, @state.scroll

    @state.scroll_by(-3)

    assert_equal 2, @state.scroll

    @state.scroll_by(-10) # should not go below 0

    assert_equal 0, @state.scroll
  end

  def test_scroll_to_bottom
    @state.scroll_by(20)

    assert_equal 20, @state.scroll

    @state.scroll_to_bottom

    assert_equal 0, @state.scroll
  end

  def test_page_scroll_amount
    assert_equal 9, @state.page_scroll_amount

    small_state = ChatApp::ScrollState.new(visible_height: 5)

    assert_equal 8, small_state.page_scroll_amount

    zero_state = ChatApp::ScrollState.new(visible_height: 0)

    assert_equal 8, zero_state.page_scroll_amount
  end

  def test_wheel_scroll_amount
    assert_equal 4, @state.wheel_scroll_amount
  end
end
