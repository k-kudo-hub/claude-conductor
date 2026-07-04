---
name: verify
description: worktreeの修正をインストール済み環境にデプロイして動作確認を行う。修正の動作確認をする時に使用する。
---

# Verify - 動作確認スキル

worktreeで修正したスクリプトを `~/.claude-conductor/` にデプロイして実機検証し、検証後に元に戻す。

## `mdev-test` による非破壊検証（推奨）

`scripts/`, `layouts/`, `init.zsh` の変更（フックの**スクリプト内容**の変更を含む）は、インストール済み環境を上書きせずに検証できる:

```bash
mdev-test <worktree>
```

`CONDUCTOR_HOME` をworktreeに向けた `test-<worktree>` セッションが別ターミナルウィンドウで起動する。実データ（pending/daily）とも分離される。この場合、本スキルのデプロイ/ロールバック手順は不要。

ただし `hooks.json` の**構造**（イベント追加・コマンド差し替え）の変更は、グローバルな `~/.claude/settings.json` 依存のため `mdev-test` ではテストできない。その場合は以下の手順で settings.json にマージして検証する。

## 前提条件

- claude-conductor リポジトリの worktree 内で作業していること
- `~/.claude-conductor/` にインストール済みの環境が存在すること

## 手順

### 1. 検証対象の確認

worktree内で変更されたファイルを特定する:

```bash
git diff --name-only
```

対象が `scripts/`, `layouts/`, `init.zsh`, `hooks.json` のいずれかであることを確認する。

### 2. バックアップの作成

変更対象ファイルのバックアップを作成する:

```bash
# 変更されたファイルごとにバックアップ
cp ~/.claude-conductor/<対象ファイル> ~/.claude-conductor/<対象ファイル>.bak
```

`~/.claude/settings.json` に変更がある場合（hooks.jsonの変更を含む）:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.verify-bak
```

### 3. デプロイ

worktreeの修正ファイルをインストール済み環境にコピーする:

```bash
# スクリプトの場合
cp <worktree>/scripts/<file>.sh ~/.claude-conductor/scripts/<file>.sh

# hooks.jsonの場合はsettings.jsonにマージが必要
# 既存のsettings.jsonからhooks以外を保持し、新しいhooksをマージする
jq --argjson hooks "$(cat <worktree>/hooks.json)" '.hooks = (.hooks // {}) + $hooks' ~/.claude/settings.json > ~/.claude/settings.json.tmp
mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

### 4. 動作確認の実施

ユーザーに以下を依頼する:

1. 新しいタスクタブを作成（例: `task review verify-test`）
2. 修正対象の操作を実行
3. 期待通りの動作をするか確認

確認結果をユーザーから受け取る。

### 5. ロールバック

動作確認後、バックアップから復元する:

```bash
# 変更されたファイルごとに復元
mv ~/.claude-conductor/<対象ファイル>.bak ~/.claude-conductor/<対象ファイル>
```

`~/.claude/settings.json` を復元する場合:

```bash
mv ~/.claude/settings.json.verify-bak ~/.claude/settings.json
```

### 6. 結果報告

検証結果をユーザーに報告する:

```
検証結果:
- 対象: <変更ファイル一覧>
- 結果: OK / NG
- 詳細: <確認した内容>
- ロールバック: 完了
```

## 注意事項

- バックアップは必ず作成してからデプロイすること
- 検証後は必ずロールバックすること（マージ後に install.sh で正式反映する）
- 複数ファイルの変更がある場合は全てを一度にデプロイすること
- settings.json のhooks以外の設定（permissions等）を壊さないこと
- hooks.jsonのマージは同名イベントを上書きする。ユーザーが同じイベント（Notification等）にカスタムhookを追加している場合、デプロイ時に消えるため、バックアップからの復元を必ず行うこと
