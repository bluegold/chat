# Ruby Chat TUI 設計

## 目的

`chat.rb` を起動口にして、`reline` ベースの CLI と `curses` ベースの TUI を同じ backend で動かす。

今の方針は次のとおり。

- `chat.rb` は launcher のみ
- 実装本体は `lib/` 配下
- 共通ロジックは `ChatBackend` に集約
- UI は `ChatApp::RelineUI` と `ChatApp::CursesUI` に分離

## ディレクトリ構成

```text
chat.rb
lib/
  chat_app_launcher.rb
  chat_backend.rb
  chat_reline_ui.rb
  chat_curses_ui.rb
test/
  test_chat_backend.rb
  test_chat_launcher.rb
  test_simple.rb
```

## 実行口

`chat.rb` は起動時に `ChatAppLauncher.run` を呼ぶだけ。

```bash
ruby chat.rb
ruby chat.rb --ui reline
ruby chat.rb --ui curses
```

`CHAT_UI=reline|curses` でも切り替えられる。

## 責務分割

### `ChatAppLauncher`

- `--ui` と `CHAT_UI` を解釈する
- API key を解決する
- `ChatApp::RelineUI` または `ChatApp::CursesUI` を起動する

### `ChatApp::RelineUI`

- `Reline` で 1 行入力を受ける
- 送信前後の画面描画を行う
- 会話ログを上部、入力欄を下部に表示する
- 日本語入力は `Reline` に任せる

### `ChatApp::CursesUI`

- `curses` でフルスクリーン TUI を描画する
- 非ブロッキング入力を読む
- 入力欄のカーソル移動、履歴、スクロール、マウスホイールを扱う
- `curses` の都合はこの層に閉じ込める

### `ChatBackend::Transcript`

- 会話ログだけを持つ
- `user_message`, `assistant_start`, `assistant_chunk`, `system_message`, `error_message`
- 表示用に `lines(cols)`, `tail_lines(cols, count)`, `window(cols, scroll:, height:)` を返す

### `ChatBackend::Status`

- 応答待ちか、生成中かを持つ
- UI はこの状態を見て `thinking...` などを出す

### `ChatBackend::HistoryStore`

- 入力履歴の永続化を担当する
- CLI と TUI の両方で共通

### `ChatBackend::SessionThread`

- LLM 通信だけを担当する
- `Queue` 経由で入出力する
- `Status` を更新し、出力イベントを流す

### `ChatBackend::TextLayout`

- 文字幅計算
- 折り返し
- 切り詰め

## データフロー

1. UI がユーザー入力を受け取る
2. UI が `HistoryStore` に保存する
3. UI が `Transcript` に user メッセージを追加する
4. UI が `SessionThread` へ `Queue` で送る
5. `SessionThread` が LLM に問い合わせる
6. 応答チャンクや完了イベントを `Queue` に流す
7. UI が `Transcript` と `Status` を更新して再描画する

## 画面構成

### Reline UI

- 上部: 会話ログ
- 下部: 入力欄
- 入力中は `Reline` に任せる

### Curses UI

- 上部: 会話ログ
- 中段: status line
- 下部: 入力欄
- スクロールは会話ログのみ対象

## テスト方針

- `test/test_chat_backend.rb`
  - `Transcript`
  - `Status`
  - `HistoryStore`
  - `SessionThread`

- `test/test_chat_launcher.rb`
  - `ChatAppLauncher.resolve_ui`
  - `ChatAppLauncher.resolve_api_key`

- `test/run.rb`
  - 全テストをまとめて実行する runner

## 依存関係

- `ruby_llm`
- `reline`
- `curses` は TUI 用

`curses` は `--ui curses` のときだけ必要になる。
