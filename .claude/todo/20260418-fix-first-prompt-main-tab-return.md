# 初回指示時にMainタブに戻らないバグの修正 + CONDUCTOR_HOME対応

## 概要

1. `pending-resolve.sh` が pending ファイルの存在を前提にMainタブ遷移を行っているため、初回の指示送信時にMainタブへ自動遷移しない問題を修正する
2. hooks.json のスクリプトパスを `CONDUCTOR_HOME` 環境変数で切り替え可能にし、検証用環境と通常環境を分離できるようにする

## TODO

- [x] `pending-resolve.sh` の修正：pending ファイルの有無に関わらずMainタブに遷移するように変更
- [x] テストケース追加：pending ファイルがない場合でもMainタブに遷移することを検証
- [x] 既存テスト（セクション9）の期待値を修正：no-opではなくMainタブ遷移が発生する動作に合わせる
- [x] 全テスト実行して通ることを確認
- [ ] hooks.json のスクリプトパスを `CONDUCTOR_HOME` 環境変数参照に変更
- [ ] install.sh の hooks マージ処理を更新（環境変数参照パスに対応）
- [ ] テスト追加：`CONDUCTOR_HOME` 設定時に正しいパスが使われることを検証
- [ ] 全テスト実行して通ることを確認
- [ ] 動作確認：`CONDUCTOR_HOME` をworktreeに向けて修正版スクリプトが使われることを確認

## 完了条件

- 初回の指示送信時にもMainタブに自動遷移する
- `CONDUCTOR_HOME` を設定することで検証用スクリプトに切り替えられる
- `CONDUCTOR_HOME` 未設定時は従来通り `~/.claude-conductor` が使われる
- 全テストがパスする
