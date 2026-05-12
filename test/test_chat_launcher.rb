# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

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

  def test_resolve_agent_registry_loads_names_from_config_path
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
            :helper:
              :model: gpt-4o-mini
              :system_prompt: Be kind
        YAML
      )

      registry = ChatAppLauncher.resolve_agent_registry('MYAGENT_CONFIG' => path)

      assert_equal 'coder', registry.default_agent_name
      assert_equal %w[coder helper], registry.names
    end
  end

  def test_resolve_agent_registry_loads_metadata_from_config_path
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
            :helper:
              :model: gpt-4o-mini
              :system_prompt: Be kind
        YAML
      )

      registry = ChatAppLauncher.resolve_agent_registry('MYAGENT_CONFIG' => path)

      assert_equal 'ChatGPT', registry['coder'].label
      assert_in_delta 0.8, registry['coder'].temperature, 0.0001
    end
  end

  def test_resolve_agent_name_prefers_environment_override
    registry = ChatBackend::AgentRegistry.new(
      agents: {
        'coder' => ChatBackend::AgentSpec.new(
          name: 'coder',
          display_name: nil,
          model: 'gpt-4o-mini',
          system_prompt: nil,
          temperature: nil,
          tools: []
        ),
        'helper' => ChatBackend::AgentSpec.new(
          name: 'helper',
          display_name: nil,
          model: 'gpt-4o-mini',
          system_prompt: nil,
          temperature: nil,
          tools: []
        )
      },
      default_agent_name: 'coder'
    )

    assert_equal 'helper', ChatAppLauncher.resolve_agent_name({ 'CHAT_AGENT' => 'helper' }, registry)
    assert_equal 'coder', ChatAppLauncher.resolve_agent_name({}, registry)
  end
end
