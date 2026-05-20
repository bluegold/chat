# frozen_string_literal: true

module ChatApp
  module ToolHints
    def tool_hints_for(text)
      text = text.to_s
      return [] if text.strip.empty?
      return [] if text.lstrip.start_with?('/')

      hints = []

      if text.match?(/ファイル|ディレクトリ|ログ|設定|config|repo|リポジトリ|コード|エラー|stack trace|traceback|Gemfile|package\.json|Dockerfile/i)
        hints << :filesystem
      end

      hints << :memory if text.match?(/前に|以前|いつもの|覚えて|忘れて|from now on|remember|forget|前回/i)
      hints << :runtime if text.match?(/計算|集計|変換|CSV|JSON|YAML|正規表現|パース|検証|試して|実行|ベンチ|比較|Ruby|Python|コード/i)
      if text.match?(/検索|調べ|最新|ニュース|現在|天気|Web|ネット|google|tavily|search|latest|news|weather/i)
        hints << :search
        hints << :web
      end

      if text.match?(%r{fetch|取得|読み込み|ページ|url|http://|https://}i)
        hints << :fetch
        hints << :web
      end

      hints.uniq
    end
  end
end
