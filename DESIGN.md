# Ruby Ractor + OpenAI API Chat CLI 設計

## アーキテクチャ概要

```
┌──────────────┐
│ Main Ractor  │ ← 入力受付・コマンド処理・セッション管理
└──────┬───────┘
       │ ユーザー入力
       ▼
   ユーザー

┌─────────────────────────────────┐
│         メッセージフロー          │
├─────────────────────────────────┤
│                                 │
│  Main Ractor ─コマンド結果──→   │
│              ↓                 │
│       Session Ractor            │
│              ↓                 │
│       API レスポンス            │
│              ↓                 │
│       Output Ractor ─→ 画面    │
│                                 │
└─────────────────────────────────┘
```

## Ractor の責務

### Main Ractor
- ユーザー入力の受付
- コマンド処理（/new, /switch, /list, /exit）
- セッションの作成・切り替え・削除
- Session Ractor へのメッセージ転送
- コマンド実行結果を Output Ractor に送信

### Session Ractor（単一）
- メッセージ履歴の維持
- OpenAI API リクエストの実行
- レスポンスの処理と履歴への追加
- API レスポンスを Output Ractor に送信

### Output Ractor
- メッセージの整形・フォーマット
- 出力順序の制御
- ストリーミング出力のバッファリング
- 色付け・装飾の適用
- エラー表示

## データフロー

### ユーザーメッセージ送信
```
ユーザー "Hello"
  ↓
Main Ractor（入力受付）
  ↓ Ractor.send({type: :user_message, content: "Hello"})
Session Ractor
  ↓ 履歴追加 [{role: :user, content: "Hello"}]
  ↓ API リクエスト（net/http）
OpenAI API
  ↓ レスポンス "Hi!"
Session Ractor
  ↓ 履歴追加 [{role: :assistant, content: "Hi!"}]
  ↓ Ractor.send({type: :chat_response, content: "Hi!"})
Output Ractor
  ↓ 整形・出力
画面: "Assistant: Hi!"
```

### コマンド実行
```
ユーザー "/list"
  ↓
Main Ractor（コマンド処理）
  ↓ Ractor.send({type: :system_message, content: "Sessions: ..."})
Output Ractor
  ↓ 整形・出力
画面: "System: Sessions: ..."
```

### ストリーミング出力
```
Session Ractor（チャンク受信）
  ↓ チャンク1: "I think"
  ↓ チャンク2: " the answer"
  ↓ チャンク3: " is 42"
Output Ractor
  ↓ バッファリング & 整形
  ↓ オプション: 逐次表示 or 一括表示
画面: "Assistant: I think the answer is 42"
```

## コマンド仕様

| コマンド | 説明 |
|----------|------|
| `/new [name]` | 新規セッション作成 |
| `/switch <id>` | セッション切り替え |
| `/list` | セッション一覧表示 |
| `/history` | 現在のセッション履歴表示 |
| `/clear` | 現在のセッション履歴クリア |
| `/exit` | 終了 |

## データ構造

### Message
```ruby
{
  role: :user | :assistant,
  content: String
}
```

### Session
```ruby
{
  id: Integer,
  name: String,
  history: [Message],
  model: String,
  created_at: Time
}
```

### Ractor 間メッセージ

#### Main → Session
```ruby
{type: :user_message, content: String}
{type: :get_history}
{type: :clear_history}
```

#### Session → Output
```ruby
{type: :chat_response, content: String}
{type: :stream_chunk, content: String}
{type: :error, message: String}
```

#### Main → Output
```ruby
{type: :system_message, content: String}
```

## クラス設計

```ruby
# メインコントローラ
class ChatCLI
  def initialize(api_key, model = "gpt-4o-mini")
    @api_key = api_key
    @model = model
    @sessions = {}  # id => Session
    @current_session_id = nil
    @main_ractor = Ractor.new { main_loop }
    @output_ractor = OutputRactor.start
  end

  def run
    @main_ractor.take
  end

  private

  def main_loop
    loop do
      print_prompt
      input = $stdin.gets&.chomp
      break if input.nil? || input == "/exit"

      if input.start_with?("/")
        handle_command(input)
      else
        send_to_session(input)
      end
    end
    @output_ractor.send({type: :system_message, content: "Goodbye!"})
  end

  def handle_command(input)
    case input
    when "/new"
      create_new_session
    when "/list"
      list_sessions
    when "/clear"
      clear_history
    else
      @output_ractor.send({type: :error, message: "Unknown command: #{input}"})
    end
  end

  def send_to_session(content)
    @output_ractor.send({type: :system_message, content: "You: #{content}"})
    # Session Ractor に送信
  end

  def print_prompt
    print "> "
  end
end

# セッション管理 Ractor
class SessionRactor
  def self.start(api_key, model)
    Ractor.new(api_key, model) do |api_key, model|
      history = []
      output_ractor = OutputRactor.instance

      loop do
        msg = Ractor.receive
        case msg[:type]
        when :user_message
          history << {role: :user, content: msg[:content]}
          response = OpenAIClient.chat(history, api_key, model)
          if response[:error]
            output_ractor.send({type: :error, message: response[:error]})
          else
            history << {role: :assistant, content: response[:content]}
            output_ractor.send({type: :chat_response, content: response[:content]})
          end
        when :get_history
          # 履歴を返却
        when :clear_history
          history = []
        end
      end
    end
  end
end

# OpenAI API クライアント（Ractor 内で使用）
module OpenAIClient
  API_ENDPOINT = "https://api.openai.com/v1/chat/completions"

  def self.chat(messages, api_key, model)
    uri = URI(API_ENDPOINT)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"

    body = {
      model: model,
      messages: messages.map { |m| {role: m[:role].to_s, content: m[:content]} }
    }
    request.body = body.to_json

    response = https.request(request)

    if response.code == "200"
      data = JSON.parse(response.body)
      {content: data["choices"][0]["message"]["content"]}
    else
      {error: "API Error: #{response.code} - #{response.body}"}
    end
  rescue => e
    {error: e.message}
  end
end

# 出力管理 Ractor
class OutputRactor
  @instance = nil

  def self.start
    @instance ||= Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :chat_response
          print_chat(msg[:content])
        when :system_message
          print_system(msg[:content])
        when :stream_chunk
          print_stream_chunk(msg[:content])
        when :error
          print_error(msg[:content])
        end
      end
    end
  end

  def self.instance
    @instance
  end

  private

  def self.print_chat(content)
    puts "\e[32mAssistant\e[0m: #{content}"
  end

  def self.print_system(content)
    puts "\e[33mSystem\e[0m: #{content}"
  end

  def self.print_error(content)
    puts "\e[31mError\e[0m: #{content}"
  end

  def self.print_stream_chunk(content)
    print content
    $stdout.flush
  end
end
```

## 技術的制約と対応

### Ractor の制約
- **共有メモリなし**：全てメッセージパッシングで通信
- **非共有オブジェクトのみ**：`Ractor.make_shareable` を使用
- **外部ライブラリ**：スレッドセーフなもののみ使用可能（net/http は OK）

### 対応策
- Session Ractor 間でデータを共有しない
- メッセージオブジェクトは基本型のみ使用（String, Integer, Array, Hash）
- API クライアントは Ractor 内でインスタンス化
- エラー処理は `Ractor::Error` をキャッチ

## 並列化のメリット

1. **非ブロッキング操作**：API リクエスト中も他の操作が可能
2. **フォールトトレランス**：Session Ractor がクラッシュしても Main/Output Ractor には影響なし
3. **責任分離**：各 Ractor が独立した責務を持つ
4. **スケーラビリティ**：必要に応じて Session Ractor を複数化可能

## 実装の優先順位

1. **フェーズ1**: 基本的な対話機能
   - Main Ractor + Session Ractor + Output Ractor
   - ユーザー入力 → API レスポンス → 表示

2. **フェーズ2**: コマンド機能
   - /new, /list, /clear, /exit
   - セッション管理

3. **フェーズ3**: ストリーミング対応
   - チャンクごとの受信と表示

4. **フェーズ4**: 永続化
   - セッション履歴の保存・読み込み

5. **フェーズ5**: 高度な機能
   - ファイル添付
   - ツール呼び出し
   - カスタムプロンプト

## 環境変数

```bash
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini  # デフォルト
```

## 実行方法

```bash
ruby chat.rb
```

## 依存ライブラリ

- Ruby 3.0 以上（Ractor 対応）
- net/http（標準ライブラリ）
- json（標準ライブラリ）

※ 外部ライブラリ（ruby-openai など）は使用せず、net/http で直接 API を呼び出す
