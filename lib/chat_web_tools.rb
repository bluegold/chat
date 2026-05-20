# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'open3'
require 'ruby_llm'
require_relative 'chat_tool_features'

module ChatApp
  module WebTools
    def self.register(klass)
      registered_tools[klass.tool_name] = klass
      klass
    end

    def self.tool_class(name)
      registered_tools[name.to_s]
    end

    def self.tool_classes
      registered_tools.values
    end

    def self.registered_tools
      @registered_tools ||= {}
    end

    class BaseTool < RubyLLM::Tool
      extend ChatApp::ToolFeatures

      class << self
        def tool_name(value = nil)
          if value.nil?
            @tool_name
          else
            @tool_name = value.to_s
          end
        end
      end

      def name
        self.class.tool_name || super
      end
    end

    class TavilySearchTool < BaseTool
      tool_name 'tavily_search'
      features :web, :search
      description 'Search the web using the Tavily API.'
      param :query, desc: 'The search query string.'

      def execute(query:)
        api_key = ENV.fetch('TAVILY_API_KEY', nil)
        return 'Error: TAVILY_API_KEY environment variable is not set.' if api_key.nil? || api_key.empty?

        query = query.to_s.strip
        return 'No search query given.' if query.empty?

        uri = URI('https://api.tavily.com/search')
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/json' })
        request.body = {
          api_key: api_key,
          query: query,
          search_depth: 'basic',
          max_results: 5
        }.to_json

        response = http.request(request)

        return "Error: Tavily API returned status code #{response.code}: #{response.body}" unless response.code == '200'

        data = JSON.parse(response.body)
        results = data['results'] || []

        return "No results found for query: #{query}" if results.empty?

        formatted = results.map do |res|
          "Title: #{res['title']}\nURL: #{res['url']}\nSnippet: #{res['content']}"
        end.join("\n---\n\n")

        "Search results for: #{query}\n\n#{formatted}"
      rescue StandardError => e
        "Error performing search: #{e.message}"
      end
    end

    class FetchPageTool < BaseTool
      tool_name 'fetch_page'
      features :web, :fetch
      description 'Fetch and read the main body content of a web page URL as Markdown using trafilatura.'
      param :url, desc: 'The absolute URL of the web page to fetch.'

      def execute(url:)
        url = url.to_s.strip
        return 'No URL given.' if url.empty?

        stdout, stderr, status = Open3.capture3('trafilatura', '-u', url, '--markdown', '--with-metadata')

        return "Error running trafilatura: #{stderr.strip}" unless status.success?

        content = stdout.to_s.strip
        return "No content could be extracted from: #{url}" if content.empty?

        content[0...8000]
      rescue Errno::ENOENT
        "Error: 'trafilatura' CLI tool is not installed or not found in PATH.\n" \
        "Please install it using: pip install trafilatura"
      rescue StandardError => e
        "Error fetching page: #{e.message}"
      end
    end

    register(TavilySearchTool)
    register(FetchPageTool)
  end
end
