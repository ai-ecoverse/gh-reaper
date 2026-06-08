#!/usr/bin/env bash
#
# Test suite for gh-reaper.
# Runs structural checks plus end-to-end worktree sandboxes: discovery,
# classification (clean/dirty/unpushed/merged), the gitignore-aware age
# signal, JSON output, dry-run safety, and real reaping.
#
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
RUN=0; PASS=0; FAIL=0

# Resolve repo root (this script lives in tests/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER="$ROOT/gh-reaper"

ok()   { printf "${GREEN}PASS${NC} %s\n" "$1"; PASS=$((PASS+1)); }
no()   { printf "${RED}FAIL${NC} %s\n  -> %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }
check(){ RUN=$((RUN+1)); }

# Local git that works offline with file:// remotes.
g() {
    command git \
        -c init.defaultBranch=main \
        -c user.email=test@example.com -c user.name=test \
        -c advice.detachedHead=false \
        -c protocol.file.allow=always "$@"
}

# ---------------------------------------------------------------------------
# Structural checks
# ---------------------------------------------------------------------------
check; [ -x "$REAPER" ] && ok "script is executable" || no "script is executable" "not found/executable"
check; head -n1 "$REAPER" | grep -q "#!/usr/bin/env bash" && ok "portable shebang" || no "portable shebang" "wrong shebang"
check; grep -q "^set -euo pipefail" "$REAPER" && ok "strict mode" || no "strict mode" "missing set -euo pipefail"
check; grep -q 'VERSION=' "$REAPER" && grep -q 'EXTENSION_NAME=' "$REAPER" && ok "metadata present" || no "metadata present" "missing VERSION/EXTENSION_NAME"

check
if out="$("$REAPER" --version 2>&1)" && [[ "$out" == *"gh-reaper version"* ]]; then
    ok "--version"
else
    no "--version" "$out"
fi

check
help="$("$REAPER" --help 2>&1)"
missing=""
for s in "USAGE:" "OPTIONS:" "STATUS FLAGS:" "EXAMPLES:"; do
    [[ "$help" == *"$s"* ]] || missing="$missing $s"
done
[ -z "$missing" ] && ok "--help has all sections" || no "--help has all sections" "missing:$missing"

check  # new flags & status documented
missing=""
for s in "--merged" "--check-prs" "merged"; do
    [[ "$help" == *"$s"* ]] || missing="$missing $s"
done
[ -z "$missing" ] && ok "--help documents merged signals" || no "--help documents merged signals" "missing:$missing"

check
if "$REAPER" --min-age nope >/dev/null 2>&1; then
    no "rejects bad --min-age" "exit 0 on non-numeric"
else
    ok "rejects bad --min-age"
fi

# ---------------------------------------------------------------------------
# Integration sandbox: clean / dirty / unpushed / merged
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP integration tests (git not available)"
else
    SBX="$(mktemp -d)/sbx"; mkdir -p "$SBX"
    trap 'rm -rf "$(dirname "$SBX")"' EXIT
    (
        cd "$SBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$SBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        printf 'node_modules/\ndist/\n' > .gitignore; g add .gitignore; g commit -qm ignore
        g push -q -u origin main
        g remote set-head origin main

        # clean: pushed, unmerged branch + clean worktree
        g worktree add -q ../wt-clean -b feat-clean
        ( cd ../wt-clean && echo c > c.txt && g add c.txt && g commit -qm "clean work" \
            && g push -q -u origin feat-clean )

        # dirty: pushed, unmerged branch + uncommitted edit
        g worktree add -q ../wt-dirty -b feat-dirty
        ( cd ../wt-dirty && echo d > d.txt && g add d.txt && g commit -qm "dirty work" \
            && g push -q -u origin feat-dirty && echo more >> d.txt )

        # unpushed: local commit, never pushed, not merged
        g worktree add -q ../wt-unpushed -b feat-unpushed
        ( cd ../wt-unpushed && echo u > u.txt && g add u.txt && g commit -qm "local only" )

        # merged: branch with a real commit, merged into main
        g worktree add -q ../wt-merged -b feat-merged
        ( cd ../wt-merged && echo m > m.txt && g add m.txt && g commit -qm "feature m" )
        g merge -q --no-ff feat-merged -m "merge feat-merged"
        g push -q origin main
    ) >/dev/null 2>&1

    if command -v jq >/dev/null 2>&1; then
        json="$("$REAPER" --json --path "$SBX" 2>/dev/null)"

        check
        n="$(printf '%s' "$json" | jq 'length' 2>/dev/null)"
        [ "$n" = 4 ] && ok "discovers 4 worktrees (JSON)" || no "discovers 4 worktrees (JSON)" "got: $n"

        check
        statuses="$(printf '%s' "$json" | jq -r '.[].status' 2>/dev/null | sort | tr '\n' ',')"
        [ "$statuses" = "clean,dirty,merged,unpushed," ] \
            && ok "classifies clean/dirty/unpushed/merged" \
            || no "classifies clean/dirty/unpushed/merged" "got: $statuses"

        check  # merged boolean tracks the merged worktree
        mb="$(printf '%s' "$json" | jq -r 'map(select(.merged))|.[].branch' 2>/dev/null)"
        [ "$mb" = "feat-merged" ] && ok "merged boolean flags only the merged worktree" \
            || no "merged boolean flags only the merged worktree" "got: $mb"

        check  # --merged filter narrows to the merged one
        only="$("$REAPER" --json --merged --path "$SBX" 2>/dev/null | jq -r '.[].branch' 2>/dev/null)"
        [ "$only" = "feat-merged" ] && ok "--merged filter narrows to merged" \
            || no "--merged filter narrows to merged" "got: $only"
    else
        check; ok "JSON classification [jq missing, skipped]"
    fi

    check  # default is read-only
    "$REAPER" --no-color --path "$SBX" >/dev/null 2>&1
    if [ -d "$SBX/wt-clean" ] && [ -d "$SBX/wt-merged" ]; then
        ok "default is read-only (no deletion)"
    else
        no "default is read-only (no deletion)" "a worktree disappeared without --reap"
    fi

    check  # --yes without --reap must not delete
    "$REAPER" --yes --no-color --path "$SBX" >/dev/null 2>&1
    if [ -d "$SBX/wt-clean" ] && [ -d "$SBX/wt-merged" ]; then
        ok "--yes without --reap deletes nothing"
    else
        no "--yes without --reap deletes nothing" "a worktree disappeared without --reap"
    fi

    check  # --reap --yes reaps clean + merged, skips dirty + unpushed
    "$REAPER" --reap --yes --no-color --path "$SBX" >/dev/null 2>&1
    if [ ! -d "$SBX/wt-clean" ] && [ ! -d "$SBX/wt-merged" ] \
       && [ -d "$SBX/wt-dirty" ] && [ -d "$SBX/wt-unpushed" ]; then
        ok "--reap --yes reaps clean+merged, skips dirty+unpushed"
    else
        no "--reap --yes reaps clean+merged, skips dirty+unpushed" \
           "clean=$([ -d "$SBX/wt-clean" ]&&echo y||echo n) merged=$([ -d "$SBX/wt-merged" ]&&echo y||echo n) dirty=$([ -d "$SBX/wt-dirty" ]&&echo y||echo n) unpushed=$([ -d "$SBX/wt-unpushed" ]&&echo y||echo n)"
    fi

    check  # --reap --force reaps the risky remainder
    "$REAPER" --reap --yes --force --no-color --path "$SBX" >/dev/null 2>&1
    if [ ! -d "$SBX/wt-dirty" ] && [ ! -d "$SBX/wt-unpushed" ]; then
        ok "--reap --force reaps dirty+unpushed"
    else
        no "--reap --force reaps dirty+unpushed" \
           "dirty=$([ -d "$SBX/wt-dirty" ]&&echo y||echo n) unpushed=$([ -d "$SBX/wt-unpushed" ]&&echo y||echo n)"
    fi
fi

# ---------------------------------------------------------------------------
# Age signal: gitignored churn must NOT reset a worktree's apparent age.
# A worktree with an old commit + old tracked files but a freshly-written
# node_modules/ file should still report a large age.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ASBX="$(mktemp -d)/age"; mkdir -p "$ASBX"
    OLD="2020-01-01T00:00:00"
    (
        cd "$ASBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$ASBX/remote.git"
        export GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD"
        echo hi > a.txt; g add a.txt; g commit -qm init
        printf 'node_modules/\n' > .gitignore; g add .gitignore; g commit -qm ignore
        g push -q -u origin main
        g remote set-head origin main
        g worktree add -q ../wt-old -b feat-old
        # Backdate the tracked files (checkout stamps them "now").
        for f in $(g -C ../wt-old ls-files); do touch -t 202001010000 "../wt-old/$f"; done
        # Fresh gitignored build churn -- must be ignored by the age signal.
        mkdir -p ../wt-old/node_modules; echo junk > ../wt-old/node_modules/x
    ) >/dev/null 2>&1

    check
    age="$("$REAPER" --json --path "$ASBX" 2>/dev/null | jq -r '.[0].ageDays' 2>/dev/null)"
    if [ -n "$age" ] && [ "$age" != null ] && [ "$age" -gt 365 ] 2>/dev/null; then
        ok "age ignores gitignored churn (ageDays=$age > 365)"
    else
        no "age ignores gitignored churn" "ageDays=$age (expected > 365)"
    fi
    rm -rf "$(dirname "$ASBX")"
fi

# ---------------------------------------------------------------------------
# Lock-file churn: a merged worktree whose only change is a regenerable lock
# file is NOT dirty by default, but IS with --no-ignore-locks. A lock change
# alongside a real edit stays dirty either way.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    LSBX="$(mktemp -d)/lock"; mkdir -p "$LSBX"
    (
        cd "$LSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$LSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        echo '{}' > package-lock.json; g add package-lock.json; g commit -qm lock
        g push -q -u origin main
        g remote set-head origin main

        # merged branch, then lock-only churn in the worktree
        g worktree add -q ../wt-lock -b feat-lock
        ( cd ../wt-lock && echo m > m.txt && g add m.txt && g commit -qm "feature" )
        g merge -q --no-ff feat-lock -m "merge feat-lock"; g push -q origin main
        echo '{"changed":1}' > ../wt-lock/package-lock.json

        # merged branch, lock churn + a real edit
        g worktree add -q ../wt-lock-real -b feat-lock-real
        ( cd ../wt-lock-real && echo n > n.txt && g add n.txt && g commit -qm "feature2" )
        g merge -q --no-ff feat-lock-real -m "merge feat-lock-real"; g push -q origin main
        echo '{"changed":1}' > ../wt-lock-real/package-lock.json
        echo real >> ../wt-lock-real/a.txt
    ) >/dev/null 2>&1

    statusof() { "$REAPER" --json ${2:-} --path "$LSBX" 2>/dev/null \
        | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status' 2>/dev/null; }

    check  # lock-only churn -> merged (not dirty) by default
    s="$(statusof feat-lock)"
    [ "$s" = "merged" ] && ok "lock-only churn is not dirty (default)" \
        || no "lock-only churn is not dirty (default)" "got: $s"

    check  # --no-ignore-locks counts the lock change as dirty
    s="$(statusof feat-lock --no-ignore-locks)"
    [ "$s" = "dirty merged" ] && ok "--no-ignore-locks marks lock churn dirty" \
        || no "--no-ignore-locks marks lock churn dirty" "got: $s"

    check  # lock change + real edit stays dirty regardless
    s="$(statusof feat-lock-real)"
    [ "$s" = "dirty merged" ] && ok "lock churn + real edit stays dirty" \
        || no "lock churn + real edit stays dirty" "got: $s"

    check  # a lock-only merged worktree actually reaps (git would otherwise
           # refuse the modified lock file); the lock+real one is skipped
    "$REAPER" --reap --yes --merged --no-color --path "$LSBX" >/dev/null 2>&1
    if [ ! -d "$LSBX/wt-lock" ] && [ -d "$LSBX/wt-lock-real" ]; then
        ok "lock-only merged worktree reaps; lock+real skipped"
    else
        no "lock-only merged worktree reaps; lock+real skipped" \
           "wt-lock=$([ -d "$LSBX/wt-lock" ]&&echo y||echo n) wt-lock-real=$([ -d "$LSBX/wt-lock-real" ]&&echo y||echo n)"
    fi

    rm -rf "$(dirname "$LSBX")"
fi

# ---------------------------------------------------------------------------
# Agent session markers: a coding agent (e.g. Qwen Code) drops a .qwen-session
# pointer into the worktree it creates. A merged worktree whose only change is
# that marker must NOT be dirty -- even with --no-ignore-locks, since a session
# pointer is never authored work -- and must still reap under --merged --reap.
# The marker beside a real edit stays dirty.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    QSBX="$(mktemp -d)/qsess"; mkdir -p "$QSBX"
    (
        cd "$QSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$QSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g remote set-head origin main

        # merged branch, then a lone .qwen-session marker in the worktree
        g worktree add -q ../wt-sess -b feat-sess
        ( cd ../wt-sess && echo s > s.txt && g add s.txt && g commit -qm "feature" )
        g merge -q --no-ff feat-sess -m "merge feat-sess"; g push -q origin main
        printf '11111111-2222-3333-4444-555555555555' > ../wt-sess/.qwen-session

        # merged branch, .qwen-session marker + a real untracked edit
        g worktree add -q ../wt-sess-real -b feat-sess-real
        ( cd ../wt-sess-real && echo t > t.txt && g add t.txt && g commit -qm "feature2" )
        g merge -q --no-ff feat-sess-real -m "merge feat-sess-real"; g push -q origin main
        printf '99999999-8888-7777-6666-555555555555' > ../wt-sess-real/.qwen-session
        echo real > ../wt-sess-real/real.txt
    ) >/dev/null 2>&1

    sstatusof() { "$REAPER" --json ${2:-} --path "$QSBX" 2>/dev/null \
        | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status' 2>/dev/null; }

    check  # session-only marker -> merged (not dirty) by default
    s="$(sstatusof feat-sess)"
    [ "$s" = "merged" ] && ok "session marker alone is not dirty (default)" \
        || no "session marker alone is not dirty (default)" "got: $s"

    check  # always ignored: --no-ignore-locks must NOT make it dirty
    s="$(sstatusof feat-sess --no-ignore-locks)"
    [ "$s" = "merged" ] && ok "session marker stays clean under --no-ignore-locks" \
        || no "session marker stays clean under --no-ignore-locks" "got: $s"

    check  # session marker + a real edit stays dirty
    s="$(sstatusof feat-sess-real)"
    [ "$s" = "dirty merged" ] && ok "session marker + real edit stays dirty" \
        || no "session marker + real edit stays dirty" "got: $s"

    check  # a session-only merged worktree actually reaps (git would otherwise
           # refuse the untracked .qwen-session); the marker+real one is skipped
    "$REAPER" --reap --yes --merged --no-color --path "$QSBX" >/dev/null 2>&1
    if [ ! -d "$QSBX/wt-sess" ] && [ -d "$QSBX/wt-sess-real" ]; then
        ok "session-only merged worktree reaps; marker+real skipped"
    else
        no "session-only merged worktree reaps; marker+real skipped" \
           "wt-sess=$([ -d "$QSBX/wt-sess" ]&&echo y||echo n) wt-sess-real=$([ -d "$QSBX/wt-sess-real" ]&&echo y||echo n)"
    fi

    rm -rf "$(dirname "$QSBX")"
fi

# ---------------------------------------------------------------------------
echo
printf "Tests run: %d   ${GREEN}passed: %d${NC}   ${RED}failed: %d${NC}\n" "$RUN" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
