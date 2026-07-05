#!/bin/bash
# Claude Conductor - Self Update
# Downloads the latest release source tarball and re-runs install.sh, following
# Claude Code's model (fetch a release artifact rather than pulling git).
#
# The update source URL is read from ~/.claude-conductor/REPO_URL (recorded by
# install.sh). CONDUCTOR_TARBALL_URL can override the download URL (used by
# tests via a file:// URL).

set -e

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
# shellcheck source=/dev/null
source "$CONDUCTOR_HOME/scripts/update-lib.sh"

GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

REPO_URL=""
[ -f "$CONDUCTOR_HOME/REPO_URL" ] && REPO_URL=$(cat "$CONDUCTOR_HOME/REPO_URL")
if [ -z "$REPO_URL" ]; then
    echo "更新元リポジトリが不明です。リポジトリで install.sh を再実行してください。" >&2
    exit 1
fi

SLUG=$(uc_repo_slug "$REPO_URL") || {
    echo "リポジトリURLを解釈できません: $REPO_URL" >&2
    exit 1
}

echo -e "${BOLD}最新バージョンを確認しています...${NC}"
LATEST=$(uc_latest_tag "$REPO_URL") || {
    echo "最新バージョンの取得に失敗しました。" >&2
    exit 1
}
CURRENT=$(uc_current_version)

if ! uc_version_gt "$LATEST" "$CURRENT"; then
    echo "既に最新です（$CURRENT）。"
    exit 0
fi

echo "$CURRENT -> $LATEST に更新します..."

TARBALL_URL="${CONDUCTOR_TARBALL_URL:-https://github.com/$SLUG/archive/refs/tags/$LATEST.tar.gz}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL --max-time 60 "$TARBALL_URL" -o "$TMP/src.tar.gz"; then
    echo "ダウンロードに失敗しました: $TARBALL_URL" >&2
    exit 1
fi

tar -xzf "$TMP/src.tar.gz" -C "$TMP"

# GitHub extracts a source tarball to <repo>-<version>/; locate the dir holding install.sh.
# Validate the find result first: an empty result would make `dirname ""` == "."
# and could run install.sh from the current directory instead of the tarball.
FOUND=$(find "$TMP" -maxdepth 2 -name install.sh -type f 2>/dev/null | head -1)
if [ -z "$FOUND" ]; then
    echo "展開したソースに install.sh が見つかりません。" >&2
    exit 1
fi
SRC=$(dirname "$FOUND")

# Reinstall, injecting the version and URL (the tarball has no .git).
CONDUCTOR_VERSION="$LATEST" CONDUCTOR_REPO_URL="$REPO_URL" bash "$SRC/install.sh"

echo ""
echo -e "${GREEN}${BOLD}✅ $LATEST に更新しました。${NC}"
exit 0
