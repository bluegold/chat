# Ruby Thread + OpenAI API Chat CLI 設計

## アーキテクチャ概要

```
+--------------+
|  Main Thread | <- 入力受付・コマンド処理・セッション管理
+------+-------+
       | ユーザー入力
       v
   ユーザー

+---------------------------------------+
|           メッセージフロー              |
+---------------------------------------+
                                       |
|  Main Thread ---コマンド結果--->        |
|              v                        |
|       Session Thread                  |
|              v                        |
|       API レスポンス                   |
|              v                        |
|       Output Thread ---> 画面          |
                                       |
+---------------------------------------+

## Thread の責務

### Main Thread
- ユーザー入力の受付
- コマンド処理（/new, /switch, /list, /exit）
- セッションの作成・切り替え・削除
- Session Thread へのメッセージ転送（Queue経由）
- コマンド実行結果を Output Thread に送信（Queue経由）

### Session Thread（単一）
- メッセージ履歴の維持
- OpenAI API リクエストの実行（ruby-openai gem使用）
- レスポンスの処理と履歴への追加
- API レスポンスを Output Thread に送信（Queue経由）

### Output Thread
- メッセージの整形・フォーマット
- 出力順序の制御（Queueから順次取り出し）
- ストリーミング出力のバッファリング
- 色付け・装飾の適用
- エラー表示

## データフロー

### ユーザーメッセージ送信
```
ユーザー "Hello"
  v
Main Thread（入力受付）
  v input_queue.push({type: :user_message, content: "Hello"})
Session Thread（input_queue.pop）
  v 履歴追加 [{role: :user, content: "Hello"}]
  v API リクエスト（ruby-openai gem）
OpenAI API
  v レスポンス "Hi!"
Session Thread
  v 履歴追加 [{role: :assistant, content: "Hi!"}]
  v output_queue.push({type: :chat_response, content: "Hi!"})
Output Thread（output_queue.pop）
  v 整形・出力
画面: "Assistant: Hi!"
```

### コマンド実行
```
ユーザー "/list"
  v
Main Thread（コマンド処理）
  v output_queue.push({type: :system_message, content: "Sessions: ..."})
Output Thread（output_queue.pop）
  v 整形・出力
画面: "System: Sessions: ..."
```

### ストリーミング出力
```
Session Thread（チャンク受信）
  v チャンク1: "I think"
  v チャンク2: " the answer"
  v チャンク3: " is 42"
Output Thread（output_queue.pop）
  v バッファリング & 整形
  v オプション: 逐次表示 or 一括表示
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

### Thread 間メッセージ（Queue経由）

#### Main → Session（input_queue）
```ruby
{type: :user_message, content: String}
{type: :get_history}
{type: :clear_history}
{type: :shutdown}
```

#### Session → Output（output_queue）
```ruby
{type: :chat_response, content: String}
{type: :stream_chunk, content: String}
{type: :error, message: String}
```

#### Main → Output（output_queue）
```ruby
{type: :system_message, content: String}
```

## クラス設計

```ruby
require 'thread'
require 'openai'

# メインコントローラ
class ChatCLI
  def initialize(api_key, model = "gpt-4o-mini")
    @api_key = api_key
    @model = model
    @input_queue = Queue.new  # Main → Session
    @output_queue = Queue.new # Main/Session → Output
    @shutdown = false

    # Thread を開始
    @session_thread = SessionThread.new(@input_queue, @output_queue, api_key, model)
    @output_thread = OutputThread.new(@output_queue)
  end

  def run
    main_loop
    shutdown
  end

  private

  def main_loop
    until @shutdown
      print_prompt
      input = $stdin.gets&.chomp
      break if input.nil? || input == "/exit"

      if input.start_with?("/")
        handle_command(input)
      else
        send_to_session(input)
      end
    end
  end

  def handle_command(input)
    case input
    when "/list"
      list_sessions
    when "/clear"
      clear_history
    when "/history"
      show_history
    else
      @output_queue.push({type: :error, message: "Unknown command: #{input}"})
    end
  end

  def send_to_session(content)
    @output_queue.push({type: :system_message, content: "You: #{content}"})
    @input_queue.push({type: :user_message, content: content})
  end

  def clear_history
    @input_queue.push({type: :clear_history})
  end

  def show_history
    @input_queue.push({type: :get_history})
  end

  def shutdown
    @shutdown = true
    @input_queue.push({type: :shutdown})
    @session_thread.join
    @output_thread.push({type: :shutdown})
    @output_thread.join
    @output_queue.push({type: :system_message, content: "Goodbye!"})
  end

  def print_prompt
    print "> "
  end
end

# セッション管理 Thread
class SessionThread
  def initialize(input_queue, output_queue, api_key, model)
    @input_queue = input_queue
    @output_queue = output_queue
    @client = OpenAI::Client.new(access_token: api_key)
    @model = model
    @history = []

    @thread = Thread.new { run }
  end

  def join
    @thread.join
  end

  private

  def run
    loop do
      msg = @input_queue.pop
      break if msg[:type] == :shutdown

      begin
        case msg[:type]
        when :user_message
          handle_user_message(msg[:content])
        when :get_history
          handle_get_history
        when :clear_history
          @history = []
          @output_queue.push({type: :system_message, content: "History cleared"})
        end
      rescue => e
        @output_queue.push({type: :error, message: e.message})
      end
    end
  end

  def handle_user_message(content)
    @history << {role: "user", content: content}

    response = @client.chat(
      parameters: {
        model: @model,
        messages: @history
      }
    )

    if response["error"]
      @output_queue.push({type: :error, message: response["error"]["message"]})
    else
      assistant_message = response.dig("choices", 0, "message", "content")
      @history << {role: "assistant", content: assistant_message}
      @output_queue.push({type: :chat_response, content: assistant_message})
    end
  end

  def handle_get_history
    @output_queue.push({type: :system_message, content: format_history})
  end

  def format_history
    @history.map { |m| "#{m[:role].capitalize}: #{m[:content]}" }.join("\n")
  end
end

# 出力管理 Thread
class OutputThread
  def initialize(output_queue)
    @output_queue = output_queue
    @thread = Thread.new { run }
  end

  def join
    @thread.join
  end

  private

  def run
    loop do
      msg = @output_queue.pop
      break if msg[:type] == :shutdown

      begin
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
      rescue => e
        STDERR.puts "Output error: #{e.message}"
      end
    end
  end

  def print_chat(content)
    puts "\e[32mAssistant\e[0m: #{content}"
  end

  def print_system(content)
    puts "\e[33mSystem\e[0m: #{content}"
  end

  def print_error(content)
    puts "\e[31mError\e[0m: #{content}"
  end

  def print_stream_chunk(content)
    print content
    $stdout.flush
  end
end
```

## 技術的仕様

### Thread の特徴
- **共有メモリあり**：ミューテックス（Mutex）で保護可能
- **Queue による通信**：スレッドセーフなキューでメッセージパッシング
- **外部ライブラリ使用可能**：ruby-openai gem などが使用可能
- **デバッグ容易**：Thread.report_on_exception = true で例外を通知

### 対応策
- Queue を使用して Thread 間通信（ミューテックス不要）
- ruby-openai gem を使用して API クライアントを実装
- 各 Thread で例外を rescue してエラーメッセージを Queue に送信
- shutdown フラグで Thread を正常終了

## 並列化のメリット

1. **非ブロッキング操作**：API リクエスト中も他の操作が可能
2. **フォールトトレランス**：Session Thread がクラッシュしても Main/Output Thread には影響なし（例外処理で対応）
3. **責任分離**：各 Thread が独立した責務を持つ
4. **柔軟性**：共有メモリが使えるので、将来の機能追加が容易
5. **成熟した技術**：Thread は長く使われている技術で、情報やツールが豊富

## 実装の優先順位

1. **フェーズ1**: 基本的な対話機能
   - Main Thread + Session Thread + Output Thread
   - ユーザー入力 → API レスポンス → 表示
   - Queue による通信

2. **フェーズ2**: コマンド機能
   - /list, /clear, /history, /exit
   - 履歴管理

3. **フェーズ3**: ストリーミング対応
   - ruby-openai のストリーミングオプションを使用
   - チャンクごとの受信と表示

4. **フェーズ4**: 永続化
   - セッション履歴の保存・読み込み（JSONファイル）

5. **フェーズ5**: 高度な機能
   - ファイル添付
   - ツール呼び出し（Function Calling）
   - カスタムプロンプトテンプレート

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

- Ruby 2.7 以上（Thread は 1.9 から対応、Queue は標準）
- ruby-openai gem（OpenAI API クライアント）
- json（標準ライブラリ）

### Gemfile
```ruby
gem 'ruby-openai'
```

### インストール
```bash
bundle install
# または
gem install ruby-openai
```
