# Chat TUI

Ruby ベースの CLI / TUI チャットインターフェース

## 概要

Chat TUI は、LLM と対話するためのターミナルベースのチャットアプリケーションです。コマンドライン (CLI) とフルスクリーン (TUI) の 2 つの UI モードを提供し、`ruby_llm` を通じて複数の LLM プロバイダに対応します。

## 主な機能

- **双 UI モード**: Reline ベースの CLI と curses ベースの TUI を切替可能
- **マルチプロバイダ対応**: `ruby_llm` 経由で各種 LLM プロバイダに接続（OpenAI、ZAI など）
- **柔軟なモデル設定**: エージェント単位でモデル、システムプロンプト、ツール、パラメータを個別設定
- **高度な入力機能**: マルチライン編集、履歴ナビゲーション、ブラケットペースト対応
- **ツールシステム**: コード実行、メモリ管理、Web 検索などの組み込みツール
- **セッション管理**: 履歴の永続化とトランスクリプト管理、アーカイブログ出力
- **フルスクリーン TUI**: スクロール、マウスホイール、ステータスラインを備えた curses インターフェース

## 動作環境

- Ruby 4.0.3 以上

## インストール

```bash
# リポジトリのクローン
git clone <repository-url>
cd chat

# 依存関係のインストール
bundle install
```

## 環境変数設定

```bash
# 必須: LLM プロバイダの API キー
export OPENAI_API_KEY="your-api-key"
# または ZAI を使用する場合
export ZAI_API_KEY="your-api-key"

# オプション: デフォルトモデル（エージェント設定で上書き可能）
export OPENAI_MODEL="gpt-4o-mini"

# オプション: UI モード (reline または curses、デフォルトは reline)
export CHAT_UI="reline"

# オプション: エージェント設定ファイルパス
export CHAT_AGENT="default"
export MYAGENT_CONFIG="$HOME/.config/myagent.yml"
```

## 使用方法

### アプリケーションの起動

```bash
# デフォルトモード (reline) で起動
ruby chat.rb

# UI モードを明示指定
ruby chat.rb --ui reline
ruby chat.rb --ui curses

# 環境変数による指定
CHAT_UI=curses ruby chat.rb
```

### エージェント設定

エージェント設定ファイル（デフォルト: `~/.config/myagent.yml`）で、モデルやツールをエージェント単位に構成できます。

```yaml
default_agent: agent

agents:
  agent:
    display_name: Agent
    model: gpt-5.4-mini
    temperature: 0.8
    tools:
      - search_files
      - search_text
      - read_file
      - list_dir
      - memory_search
      - memory_add
      - memory_list
      - memory_read
      - memory_forget
      - run_ruby
      - run_python
      - tavily_search
      - fetch_page
```

モデルは各エージェントの `model` フィールドで自由に指定できます。未設定の場合のデフォルトは `gpt-4o-mini` です。

### キーボードショートカット (Curses TUI)

- `Ctrl+N` / `Ctrl+P`: 次の/前の履歴エントリ
- `Ctrl+E` / `Ctrl+A`: 行末/行頭へ移動
- `Ctrl+H`: バックスペース
- `Ctrl+M`: メッセージ送信
- `Ctrl+C`: 終了
- `矢印キー上/下`: 履歴ナビゲーション
- `Page Up/Down`: トランスクリプトスクロール
- `マウスホイール`: トランスクリプトスクロール

## ファイルレイアウト

アプリケーションはホームディレクトリ配下に設定とログを保持します。

```
~/.config/
  myagent.yml              # エージェント設定ファイル
  myagent/
    archive/               # 会話ログ (JSONL)
      YYYY/MM/DD/
        <cwd>-<title>-HHMMSS.jsonl

~/.chat_history            # 入力履歴
```

| パス | 役割 | 備考 |
|------|------|------|
| `~/.config/myagent.yml` | エージェント定義、デフォルトエージェント、モデル・ツール・プロンプトの設定 | `MYAGENT_CONFIG` 環境変数で変更可能 |
| `~/.config/myagent/archive/` | セッションごとの会話ログを日付階層で保存 | JSONL 形式、自動作成 |
| `~/.chat_history` | 入力履歴（最大 1000 件） | YAML 形式 |

### 会話ログの形式

各セッションは JSONL ファイルとして記録され、1 行につき 1 イベントが出力されます。

```jsonl
{"event":"session_start","agent":"assistant","model":"gpt-4o","cwd":"/home/user/project","timestamp":"2026-05-22T10:00:00+09:00"}
{"role":"user","content":"こんにちは","timestamp":"2026-05-22T10:00:05+09:00"}
{"role":"assistant","content":"こんにちは！何かお手伝いしましょうか？","timestamp":"2026-05-22T10:00:08+09:00"}
{"role":"tool_call","name":"CodeExecutionTools","arguments":{"code":"puts 1+1"},"timestamp":"2026-05-22T10:00:15+09:00"}
{"role":"tool_result","name":"CodeExecutionTools","result":"2","timestamp":"2026-05-22T10:00:16+09:00"}
```

主なイベント種別:

- `session_start`: セッション開始時のメタ情報（エージェント名、モデル、作業ディレクトリ）
- `user`: ユーザーメッセージ
- `assistant`: アシスタント応答
- `tool_call`: ツール呼び出し（ツール名と引数）
- `tool_result`: ツール実行結果

## アーキテクチャ

### コアコンポーネント

- **ChatAppLauncher**: UI モード、API キー、エージェント設定の解決および起動処理
- **ChatBackend::AgentRegistry**: YAML 設定ファイルからのエージェント定義の読み込みと管理
- **ChatBackend::AgentSpec**: エージェントのモデル、システムプロンプト、ツール、パラメータを保持するデータオブジェクト
- **ChatBackend::SessionThread**: `ruby_llm` を通じた LLM 通信とストリーミング応答の処理
- **ChatApp::RelineUI**: Reline を使用したコマンドラインインターフェース
- **ChatApp::CursesUI**: curses ライブラリを使用したフルスクリーン TUI

### ディレクトリ構成

```
chat.rb                       # メインエントリーポイント
lib/
  chat_app_launcher.rb        # ランチャーおよび設定管理
  backend/
    chat_backend.rb           # バックエンドのエントリとツール解決
    chat_agent_registry.rb    # エージェントレジストリ（YAML 読み込み）
    chat_agent_spec.rb        # エージェント定義（Data クラス）
    chat_session_config.rb    # セッション設定
    chat_session_thread.rb    # LLM 通信とストリーミング
    chat_session_controller.rb # セッション制御
    chat_transcript.rb        # 会話ログ管理
    chat_history_store.rb     # 入力履歴の永続化
    chat_text_layout.rb       # 文字幅計算と折り返し
    chat_status.rb            # 応答状態管理
  tools/
    chat_tool_*.rb            # 各種ツール実装
  ui/
    chat_reline_ui.rb         # CLI インターフェース
    chat_curses_ui.rb         # TUI インターフェース
    chat_curses_session.rb    # curses セッション管理
    chat_curses_input*.rb     # curses 入力処理
    chat_command_*.rb         # コマンド解釈/補完
    chat_history_navigator.rb # 履歴ナビゲーション
    chat_session_info.rb      # 表示用セッション情報
    chat_status_line_formatter.rb # ステータス行の整形
test/
  test_chat_*.rb              # テストスイート
  run.rb                      # テストランナー
```

### データフロー

1. UI がユーザー入力を受信する
2. 入力を `HistoryStore` に保存する
3. `Transcript` にユーザーメッセージを追加する
4. `SessionThread` へ `Queue` 経由でメッセージを送信する
5. `SessionThread` がエージェント設定に基づき `ruby_llm` で LLM に問い合わせる
6. 応答チャンクと完了イベントを `Queue` に流す
7. UI が `Transcript` と `Status` を更新して再描画する

## テスト

```bash
# 全テストの実行
ruby test/run.rb

# 特定のテストファイルの実行
ruby test/test_chat_backend.rb
```

テストは Minitest フレームワークを使用し、以下の領域を網羅しています：

- バックエンドロジック (Transcript, HistoryStore, SessionThread)
- エージェントレジストリと設定
- UI コンポーネント (入力処理、curses、reline)
- ツール実行とトラッキング
- セッション管理

現在のテスト状況: 111 ケース、336 アサーション、すべて通過

## 設定

### ツールシステム

ツールはエージェント設定の `tools` フィールドでエージェントごとに個別に割り当て可能です。

#### 組み込みツール

| カテゴリ | ツール名 | 説明 | features |
|----------|----------|------|----------|
| **ローカル** | `search_files` | ファイル・ディレクトリ名を検索 | baseline, filesystem, search |
| | `search_text` | ファイル内容を全文検索（既知ファイルの閲覧には使わない） | baseline, filesystem, search |
| | `read_file` | 既知ファイルを読み込み（行範囲指定可、長い場合は続きの開始行を案内） | filesystem, read |
| | `list_dir` | ディレクトリの内容を一覧表示 | filesystem, list |
| **メモリ** | `memory_search` | メモリを検索 | baseline, memory, search |
| | `memory_add` | メモリを追加 | memory, write |
| | `memory_list` | メモリ一覧を表示 | memory, read |
| | `memory_read` | メモリを読み込み | memory, read |
| | `memory_forget` | メモリを削除 | memory, write |
| **コード実行** | `run_ruby` | サンドボックスで Ruby コードを実行 | runtime, code_execution, ruby |
| | `run_python` | サンドボックスで Python コードを実行 | runtime, code_execution, python |
| **Web** | `tavily_search` | Tavily で Web 検索 | web, search |
| | `fetch_page` | URL からページを取得 | web, fetch |

各ツールは `features` タグを持ち、ツールヒントによる動的選択に利用されます。

#### ツールヒント（入力ベースの動的フィルタリング）

ユーザーの入力テキストに含まれるキーワードを解析し、そのメッセージに必要なツールだけを動的に選択します。これにより、すべてのツールを毎回 LLM に渡すことを避け、コンテキストの節約と応答精度の向上を実現します。

判定は `ToolHints` モジュールが行います。

| ヒント feature | マッチするキーワードの例 | 選択されるツール |
|-----------------|--------------------------|------------------|
| `filesystem` | ファイル、ディレクトリ、ログ、設定、config、エラー、コード | `search_files`, `search_text`, `read_file`, `list_dir` |
| `list` | 一覧、リスト、中身、配下、構成、tree | `list_dir` |
| `memory` | 前に、以前、いつもの、覚えて、忘れて、remember、forget | `memory_search`, `memory_add`, `memory_list`, `memory_read`, `memory_forget` |
| `runtime` | 計算、集計、変換、CSV、JSON、実行、Ruby、Python | `run_ruby`, `run_python` |
| `search` + `web` | 検索、調べ、最新、ニュース、Web、google | `tavily_search` |
| `fetch` + `web` | fetch、取得、ページ、URL、http | `fetch_page` |

ツール選択の優先順位:

1. `baseline` feature を持つツールを基本セットとして選択
2. 入力テキストからヒント feature を抽出し、対応するツールを追加
3. ヒントが一件も検出されなければ、エージェントに設定された全ツールを使用

## 依存関係

- `ruby_llm` - マルチプロバイダ対応 LLM インタラクションライブラリ
- `reline` - Readline 互換の入力処理
- `curses` - ターミナル UI（TUI モードのみ）

## 開発

### コードスタイル

プロジェクトは RuboCop 標準に準拠しています。リンティングの確認:

```bash
bundle exec rubocop
```

### テストの実行

```bash
ruby test/run.rb
```

## ライセンス

詳細は LICENSE ファイルを参照してください。

## コントリビューション

コントリビューションを歓迎します。ご協力の際は以下をご確認ください：

- すべてのテストが通過すること (`ruby test/run.rb`)
- コードが RuboCop ガイドラインに準拠していること
- 変更内容が適切にドキュメントされていること

## 更新履歴

- アーカイブログ出力機能の追加とファイルシステムツールの制限強化
- WebTools (TavilySearchTool, FetchPageTool) の追加
- SessionController と HistoryNavigator の抽出による UI ロジックの統一
- バックエンドのモジュール化とサービスクラスへの分割
- サンドボックス化されたコード実行ツールの追加
- メモリツールと YAML 履歴永続化の追加
- ブラケットペースト対応による入力機能の強化
