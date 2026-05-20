# frozen_string_literal: true

require 'minitest/autorun'
require 'net/http'
require 'open3'
require 'json'

require_relative '../lib/chat_backend'

# Dynamic stubbing of Net::HTTP to avoid minitest/mock load conflicts
class << Net::HTTP
  attr_accessor :fake_enabled, :fake_response

  alias original_new new

  def new(...)
    if fake_enabled
      ChatBackendWebToolsTest::FakeHTTP.new(...)
    else
      original_new(...)
    end
  end
end

# Dynamic stubbing of Open3 to avoid minitest/mock load conflicts
class << Open3
  attr_accessor :fake_enabled, :fake_stdout, :fake_stderr, :fake_status, :fake_errno

  alias original_capture3 capture3

  def capture3(...)
    if fake_enabled
      raise fake_errno if fake_errno

      [fake_stdout, fake_stderr, fake_status]
    else
      original_capture3(...)
    end
  end
end

class ChatBackendWebToolsTest < Minitest::Test
  class FakeResponse
    attr_reader :code, :body

    def initialize(code, body)
      @code = code
      @body = body
    end
  end

  class FakeHTTP
    attr_accessor :use_ssl

    def initialize(*_args, **_kwargs); end

    def request(_req)
      Net::HTTP.fake_response
    end
  end

  class ProcessStatusMock
    def initialize(success)
      @success = success
    end

    def success?
      @success
    end
  end

  def setup
    @original_api_key = ENV.fetch('TAVILY_API_KEY', nil)
    ENV['TAVILY_API_KEY'] = 'fake_tavily_key'
    Net::HTTP.fake_enabled = true
    Net::HTTP.fake_response = nil

    Open3.fake_enabled = true
    Open3.fake_stdout = nil
    Open3.fake_stderr = nil
    Open3.fake_status = nil
    Open3.fake_errno = nil
  end

  def teardown
    ENV['TAVILY_API_KEY'] = @original_api_key
    Net::HTTP.fake_enabled = false
    Net::HTTP.fake_response = nil

    Open3.fake_enabled = false
    Open3.fake_stdout = nil
    Open3.fake_stderr = nil
    Open3.fake_status = nil
    Open3.fake_errno = nil
  end

  def test_tavily_search_tool_supports_features
    assert ChatApp::WebTools::TavilySearchTool.supports_feature?(:search)
    assert ChatApp::WebTools::TavilySearchTool.supports_feature?(:web)
  end

  def test_tavily_search_tool_returns_error_when_api_key_missing
    ENV['TAVILY_API_KEY'] = nil
    tool = ChatApp::WebTools::TavilySearchTool.new
    result = tool.call(query: 'test')

    assert_includes result, 'Error: TAVILY_API_KEY environment variable is not set.'
  end

  def test_tavily_search_tool_returns_error_when_query_empty
    tool = ChatApp::WebTools::TavilySearchTool.new
    result = tool.call(query: ' ')

    assert_includes result, 'No search query given.'
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_tavily_search_tool_formats_results_on_success
    tool = ChatApp::WebTools::TavilySearchTool.new

    Net::HTTP.fake_response = FakeResponse.new('200', {
      results: [
        { title: 'Test Title 1', url: 'http://test1.com', content: 'Test Content 1' },
        { title: 'Test Title 2', url: 'http://test2.com', content: 'Test Content 2' }
      ]
    }.to_json)

    result = tool.call(query: 'ruby news')

    assert_includes result, 'Search results for: ruby news'
    assert_includes result, 'Title: Test Title 1'
    assert_includes result, 'URL: http://test1.com'
    assert_includes result, 'Snippet: Test Content 1'
    assert_includes result, 'Title: Test Title 2'
    assert_includes result, 'URL: http://test2.com'
    assert_includes result, 'Snippet: Test Content 2'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_tavily_search_tool_handles_api_errors
    tool = ChatApp::WebTools::TavilySearchTool.new

    Net::HTTP.fake_response = FakeResponse.new('400', 'Bad Request')

    result = tool.call(query: 'ruby news')

    assert_includes result, 'Error: Tavily API returned status code 400: Bad Request'
  end

  def test_fetch_page_tool_supports_features
    assert ChatApp::WebTools::FetchPageTool.supports_feature?(:fetch)
    assert ChatApp::WebTools::FetchPageTool.supports_feature?(:web)
  end

  def test_fetch_page_tool_returns_error_when_url_empty
    tool = ChatApp::WebTools::FetchPageTool.new
    result = tool.call(url: ' ')

    assert_includes result, 'No URL given.'
  end

  def test_fetch_page_tool_extracts_markdown_on_success
    tool = ChatApp::WebTools::FetchPageTool.new
    Open3.fake_status = ProcessStatusMock.new(true)
    Open3.fake_stdout = "# RubyonRails\n\nLatest release is Rails 8."

    result = tool.call(url: 'https://rubyonrails.org')

    assert_includes result, '# RubyonRails'
    assert_includes result, 'Latest release is Rails 8.'
  end

  def test_fetch_page_tool_handles_command_not_found
    tool = ChatApp::WebTools::FetchPageTool.new
    Open3.fake_errno = Errno::ENOENT.new('No such file or directory - trafilatura')

    result = tool.call(url: 'https://rubyonrails.org')

    assert_includes result, "Error: 'trafilatura' CLI tool is not installed or not found in PATH."
  end

  def test_fetch_page_tool_handles_trafilatura_failures
    tool = ChatApp::WebTools::FetchPageTool.new
    Open3.fake_status = ProcessStatusMock.new(false)
    Open3.fake_stderr = 'Network timeout'
    Open3.fake_stdout = ''

    result = tool.call(url: 'https://rubyonrails.org')

    assert_includes result, 'Error running trafilatura: Network timeout'
  end

  class DummyHost
    include ChatApp::ToolHints
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_tool_hints_triggers_web_and_search_features
    host = DummyHost.new

    assert_includes host.tool_hints_for('今日のニュースを検索して'), :search
    assert_includes host.tool_hints_for('今日のニュースを検索して'), :web
    assert_includes host.tool_hints_for('Ruby 4.0について調べる'), :search
    assert_includes host.tool_hints_for('latest features of rails'), :search
    assert_includes host.tool_hints_for('latest features of rails'), :web

    refute_includes host.tool_hints_for('ファイルを読み込んで'), :search
    refute_includes host.tool_hints_for('ファイルを読み込んで'), :web
  end

  def test_tool_hints_triggers_web_and_fetch_features
    host = DummyHost.new

    assert_includes host.tool_hints_for('https://rubyonrails.org のページを取得して'), :fetch
    assert_includes host.tool_hints_for('https://rubyonrails.org のページを取得して'), :web
    assert_includes host.tool_hints_for('http://example.com をfetchして'), :fetch
    assert_includes host.tool_hints_for('URLを読み込む'), :fetch
    assert_includes host.tool_hints_for('URLを読み込む'), :web

    refute_includes host.tool_hints_for('正規表現をパースして'), :fetch
    refute_includes host.tool_hints_for('正規表現をパースして'), :web
  end
  # rubocop:enable Minitest/MultipleAssertions
end
