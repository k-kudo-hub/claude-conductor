#!/bin/bash
# Claude Conductor - Update Library
# Shared helpers for the self-update flow (check-update.sh / update.sh).
# Sourced by those scripts and unit-tested by test.sh; defines functions only.
# bash 3.2 compatible.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# uc_repo_slug <git-url> -> "owner/repo"
# Accepts SSH (git@github.com:owner/repo.git), HTTPS
# (https://github.com/owner/repo.git) and ssh:// forms. Prints owner/repo.
# Returns non-zero if the URL does not yield a plausible slug.
uc_repo_slug() {
    local url="$1"
    [ -n "$url" ] || return 1
    url="${url%.git}"     # drop trailing .git
    url="${url//:/\/}"    # SSH colon -> slash so we can split on '/'
    local repo="${url##*/}"
    local rest="${url%/*}"
    local owner="${rest##*/}"
    # owner and repo may legitimately be identical (e.g. torvalds/torvalds),
    # so only reject when either component is missing.
    if [ -z "$owner" ] || [ -z "$repo" ] || [ "$owner" = "$rest" ]; then
        return 1
    fi
    echo "$owner/$repo"
}

# uc_version_gt <a> <b> -> exit 0 if semver a > b, else exit 1.
# Accepts an optional leading "v". Uses base-10 arithmetic so leading-zero
# segments (e.g. 1.2.08) do not trigger octal parse errors.
uc_version_gt() {
    local a="${1#v}" b="${2#v}"
    local ar br
    local am ai ap bm bi bp
    am=$((10#${a%%.*})); ar="${a#*.}"; ai=$((10#${ar%%.*})); ap=$((10#${ar#*.}))
    bm=$((10#${b%%.*})); br="${b#*.}"; bi=$((10#${br%%.*})); bp=$((10#${br#*.}))
    if [ "$am" -ne "$bm" ]; then [ "$am" -gt "$bm" ]; return; fi
    if [ "$ai" -ne "$bi" ]; then [ "$ai" -gt "$bi" ]; return; fi
    [ "$ap" -gt "$bp" ]
}

# uc_current_version -> the installed version, or v0.0.0 when unknown.
uc_current_version() {
    local f="$CONDUCTOR_HOME/VERSION"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo "v0.0.0"
    fi
}

# uc_latest_tag <git-url> -> highest semver tag on the remote (e.g. v1.2.3).
# Prints nothing (and returns non-zero) when the remote is unreachable or has
# no semver tags.
uc_latest_tag() {
    local url="$1"
    [ -n "$url" ] || return 1
    local latest
    # Bound the network wait so an unreachable remote never blocks startup:
    # http.lowSpeed* caps HTTPS transfers, ConnectTimeout+BatchMode caps SSH,
    # GIT_TERMINAL_PROMPT=0 avoids interactive auth hangs.
    latest=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o ConnectTimeout=5 -o BatchMode=yes" \
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 ls-remote --tags "$url" 2>/dev/null \
        | awk '{print $2}' \
        | sed 's#refs/tags/##' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)
    [ -n "$latest" ] || return 1
    echo "v$latest"
}
