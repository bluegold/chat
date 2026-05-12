# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../chat'

class ChatAppLauncherTest < Minitest::Test
  def test_resolve_ui_defaults_to_reline
    assert_equal 'reline', ChatAppLauncher.resolve_ui([], {})
  end

  def test_resolve_ui_accepts_flag_and_env
    assert_equal 'curses', ChatAppLauncher.resolve_ui(['--ui', 'curses'], {})
    assert_equal 'curses', ChatAppLauncher.resolve_ui([], { 'CHAT_UI' => 'curses' })
  end

  def test_resolve_api_key_prefers_openai_key_then_zai_key
    assert_equal 'openai', ChatAppLauncher.resolve_api_key('OPENAI_API_KEY' => 'openai')
    assert_equal 'zai', ChatAppLauncher.resolve_api_key('ZAI_API_KEY' => 'zai')
  end

  def test_resolve_api_key_raises_when_missing
    _stdout, _stderr = capture_io do
      assert_raises(SystemExit) { ChatAppLauncher.resolve_api_key({}) }
    end
  end
end
