#!/bin/bash
# Claude Conductor - Binary Library
# Shared helpers for obtaining the `conductor` binary (the Go TUI that renders
# the panes). Sourced by install.sh and unit-tested by test.sh; defines
# functions only. bash 3.2 compatible.
#
# Acquisition order (cb_install_binary):
#   1. Download the release asset matching this version+platform.
#   2. Fall back to a local `go build` when the download fails and Go is
#      available. This is what makes a git checkout installable before the
#      matching release exists.
#
# CONDUCTOR_BINARY_URL overrides the download URL (tests point it at file://).
# CONDUCTOR_FORCE_BUILD=1 skips the download entirely and builds from source.

# uc_repo_slug lives in update-lib.sh. Source it here so this library works on
# its own: without it cb_install_binary would silently skip the download path
# (an empty slug yields an empty URL) and always fall back to a local build.
if ! command -v uc_repo_slug >/dev/null 2>&1; then
    # shellcheck source=scripts/update-lib.sh
    . "${CONDUCTOR_HOME:-$HOME/.claude-conductor}/scripts/update-lib.sh" 2>/dev/null || true
fi

# Go のバージョン埋め込み先。cmd/conductor のビルドで -ldflags に渡す。
CB_VERSION_SYMBOL="github.com/k-kudo-hub/claude-conductor/internal/cli.Version"

# cb_platform -> "darwin-arm64" のような GOOS-GOARCH。
# 対応外のOS/CPUでは非ゼロを返す（呼び出し側はビルドへ倒す）。
cb_platform() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) return 1 ;;
    esac
    echo "${os}-${arch}"
}

# cb_asset_name [platform] -> リリースに添付するファイル名。
# 引数を省略した場合は実行中のプラットフォームを使う。
cb_asset_name() {
    local platform="$1"
    if [ -z "$platform" ]; then
        platform=$(cb_platform) || return 1
    fi
    echo "conductor-${platform}"
}

# cb_binary_url <repo-slug> <version> [platform] -> リリース資産のURL。
cb_binary_url() {
    local slug="$1" version="$2" platform="$3" asset
    [ -n "$slug" ] || return 1
    [ -n "$version" ] || return 1
    asset=$(cb_asset_name "$platform") || return 1
    echo "https://github.com/${slug}/releases/download/${version}/${asset}"
}

# cb_download_binary <url> <dest> -> ダウンロードして実行権を付ける。
# 空ファイルを掴んだまま成功扱いにしないよう、サイズも確認する。
cb_download_binary() {
    local url="$1" dest="$2" tmp
    [ -n "$url" ] || return 1
    [ -n "$dest" ] || return 1

    tmp="${dest}.download"
    if ! curl -fsSL --max-time 120 "$url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi

    chmod +x "$tmp"
    mv "$tmp" "$dest"
}

# cb_build_binary <repo-dir> <dest> <version> -> ローカルの Go でビルドする。
# repo-dir に Go のソースが無い（tarball 更新など）場合は非ゼロ。
cb_build_binary() {
    local repo_dir="$1" dest="$2" version="$3"
    [ -d "$repo_dir/cmd/conductor" ] || return 1
    command -v go >/dev/null 2>&1 || return 1

    ( cd "$repo_dir" && go build \
        -ldflags "-s -w -X ${CB_VERSION_SYMBOL}=${version}" \
        -o "$dest" ./cmd/conductor ) >/dev/null 2>&1
}

# cb_repo_is_ahead_of_release <repo-dir>
# リポジトリの HEAD が、直近のタグそのものより先に進んでいれば真。
#
# install.sh はバージョンを `git describe --tags --abbrev=0` で決めるが、
# これは常に「到達可能な直近タグ」を返すので、開発中のコミットでも
# 既存リリースの資産がダウンロードできてしまい、手元の変更が反映されない
# バイナリが黙って入る。タグが無い / git でない場合は偽（判断できない）。
cb_repo_is_ahead_of_release() {
    local repo_dir="$1" tag head tagged
    git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || return 1

    tag=$(git -C "$repo_dir" describe --tags --abbrev=0 2>/dev/null) || return 1
    [ -n "$tag" ] || return 1

    head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 1
    tagged=$(git -C "$repo_dir" rev-parse "${tag}^{commit}" 2>/dev/null) || return 1

    [ "$head" != "$tagged" ]
}

# cb_install_binary <repo-dir> <dest> <version> <repo-url>
# ダウンロードを試し、失敗したらローカルビルドに落とす。
# CONDUCTOR_FORCE_BUILD=1 のときはダウンロードを飛ばす。
# 標準出力に採用した経路（download / build）を出す。
cb_install_binary() {
    local repo_dir="$1" dest="$2" version="$3" repo_url="$4"
    local url="" slug

    mkdir -p "$(dirname "$dest")"

    if [ -n "$CONDUCTOR_FORCE_BUILD" ]; then
        url=""
    elif [ -n "$CONDUCTOR_BINARY_URL" ]; then
        url="$CONDUCTOR_BINARY_URL"
    elif [ -n "$repo_url" ] && [ -n "$version" ]; then
        if slug=$(uc_repo_slug "$repo_url" 2>/dev/null); then
            url=$(cb_binary_url "$slug" "$version" 2>/dev/null) || url=""
        fi
    fi

    if [ -n "$url" ] && cb_download_binary "$url" "$dest"; then
        echo "download"
        return 0
    fi

    if cb_build_binary "$repo_dir" "$dest" "$version"; then
        echo "build"
        return 0
    fi

    return 1
}
