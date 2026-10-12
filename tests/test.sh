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

# A stand-in for the bb CLI, so no test ever asks the real bb (or depends on it
# being installed). Put "$1" first on PATH to use it. It answers from fixture
# files and logs every call:
#   STUB_BB_MODE      ok (default) | fail -- fail errors like a dead daemon
#   STUB_BB_OPEN      JSON for `bb thread list --json` (every non-deleted thread)
#   STUB_BB_ARCHIVED  JSON for `bb thread list --json --archived`
#   STUB_BB_SHOW_DIR  <dir>/<thr_id>.json answers `bb thread show`; else 404
#   STUB_BB_DATA_DIR  dataDir reported by `bb status --json`
#   STUB_BB_LOG       append each invocation's argv here
make_stub_bb() {
    mkdir -p "$1"
    cat > "$1/bb" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_BB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_BB_LOG"
if [ "${STUB_BB_MODE:-ok}" = fail ]; then
    echo '{"ok": false, "error": {"code": "daemon_unavailable", "message": "no daemon"}}'
    exit 1
fi
case "$1 $2" in
    "thread list")
        case " $* " in
            *" --archived "*) cat "${STUB_BB_ARCHIVED:?}" ;;
            *)                cat "${STUB_BB_OPEN:?}" ;;
        esac ;;
    "thread show")
        if [ -f "${STUB_BB_SHOW_DIR:-/nonexistent}/$3.json" ]; then cat "$STUB_BB_SHOW_DIR/$3.json"
        else echo '{"ok": false, "error": {"code": "thread_not_found", "message": "HTTP 404: Thread not found"}}'; exit 1; fi ;;
    "status --json") printf '{"dataDir": "%s"}\n' "${STUB_BB_DATA_DIR:-$HOME/.bb}" ;;
    *) echo '{"ok": false, "error": {"code": "usage"}}'; exit 1 ;;
esac
STUB
    chmod +x "$1/bb"
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
# Busy: a live process working inside a worktree pins it, however merged the
# branch is. This is the "agent mid-run" guard -- `--merged --reap --yes` must
# not sweep a tree someone is still in. Idle interactive shells are excluded,
# or every leftover terminal tab would pin a finished worktree forever.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    BSBX="$(mktemp -d)/busy"; mkdir -p "$BSBX"
    BUSY_PIDS=()
    (
        cd "$BSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$BSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g remote set-head origin main

        # two merged worktrees: one will host a worker, one an idle shell
        for n in busy shell; do
            g worktree add -q "../wt-$n" -b "feat-$n"
            ( cd "../wt-$n" && echo x > "$n.txt" && g add "$n.txt" && g commit -qm "feature $n" )
            g merge -q --no-ff "feat-$n" -m "merge feat-$n"
        done
        g push -q origin main
    ) >/dev/null 2>&1

    # A non-shell worker (sleep) parked inside wt-busy.
    ( cd "$BSBX/wt-busy" && exec sleep 120 ) &
    BUSY_PIDS+=("$!")
    # An interactive-shell stand-in inside wt-shell: bash blocked on a read, with
    # no child of its own (a plain `bash -c sleep` would exec into `sleep` and
    # defeat the point). The fifo is opened read-write so the open doesn't block.
    mkfifo "$BSBX/hold" 2>/dev/null || true
    ( cd "$BSBX/wt-shell" && exec bash -c 'read -r _ <&3' 3<>"$BSBX/hold" ) &
    BUSY_PIDS+=("$!")
    sleep 1  # let the processes settle so the process table sees their cwd

    bstatusof() { "$REAPER" --json --path "$BSBX" 2>/dev/null \
        | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status' 2>/dev/null; }

    check  # live worker pins an otherwise-sweepable merged worktree
    s="$(bstatusof feat-busy)"
    [ "$s" = "busy merged" ] && ok "live process marks a merged worktree busy" \
        || no "live process marks a merged worktree busy" "got: $s"

    check  # busy exposed as a JSON boolean for scripting
    b="$("$REAPER" --json --path "$BSBX" 2>/dev/null \
        | jq -r 'map(select(.busy))|.[].branch' 2>/dev/null)"
    [ "$b" = "feat-busy" ] && ok "busy boolean flags only the occupied worktree" \
        || no "busy boolean flags only the occupied worktree" "got: $b"

    check  # a parked shell is not work in progress
    s="$(bstatusof feat-shell)"
    [ "$s" = "merged" ] && ok "idle shell does not mark a worktree busy" \
        || no "idle shell does not mark a worktree busy" "got: $s"

    check  # the headline guard: --merged --reap --yes must skip the busy one
    "$REAPER" --reap --yes --merged --no-color --path "$BSBX" >/dev/null 2>&1
    if [ -d "$BSBX/wt-busy" ] && [ ! -d "$BSBX/wt-shell" ]; then
        ok "--merged --reap spares busy, sweeps the idle one"
    else
        no "--merged --reap spares busy, sweeps the idle one" \
           "wt-busy=$([ -d "$BSBX/wt-busy" ]&&echo y||echo n) wt-shell=$([ -d "$BSBX/wt-shell" ]&&echo y||echo n)"
    fi

    check  # --force is the documented override
    "$REAPER" --reap --yes --force --no-color --path "$BSBX" >/dev/null 2>&1
    [ ! -d "$BSBX/wt-busy" ] && ok "--force reaps a busy worktree" \
        || no "--force reaps a busy worktree" "wt-busy survived --force"

    for p in "${BUSY_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$(dirname "$BSBX")"
fi

# ---------------------------------------------------------------------------
# The Linux busy path reads /proc directly rather than shelling out to lsof.
# Drive it from a fixture so it is covered on any host, not only on Linux --
# otherwise the branch CI actually runs is the one never exercised locally.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    PSBX="$(mktemp -d)/proc"; mkdir -p "$PSBX"
    (
        cd "$PSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$PSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g remote set-head origin main
        for n in worker shell; do
            g worktree add -q "../wt-$n" -b "feat-$n"
            ( cd "../wt-$n" && echo x > "$n.txt" && g add "$n.txt" && g commit -qm "feature $n" )
            g merge -q --no-ff "feat-$n" -m "merge feat-$n"
        done
        g push -q origin main
    ) >/dev/null 2>&1

    # A stand-in /proc: one non-shell process in wt-worker, one shell in
    # wt-shell. Pids are far above any real one so they can't collide with our
    # own process chain. cwd symlinks point at resolved paths, as Linux reports.
    FAKEPROC="$PSBX/fakeproc"
    mkdir -p "$FAKEPROC/self" "$FAKEPROC/999001" "$FAKEPROC/999002"
    ln -s "$PSBX" "$FAKEPROC/self/cwd"
    ln -s "$(cd "$PSBX/wt-worker" && pwd -P)" "$FAKEPROC/999001/cwd"
    printf 'node\n' > "$FAKEPROC/999001/comm"
    ln -s "$(cd "$PSBX/wt-shell" && pwd -P)" "$FAKEPROC/999002/cwd"
    printf 'zsh\n' > "$FAKEPROC/999002/comm"

    pstatusof() { REAPER_PROC_DIR="$FAKEPROC" "$REAPER" --json --path "$PSBX" 2>/dev/null \
        | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status' 2>/dev/null; }

    check  # /proc branch flags the non-shell process
    s="$(pstatusof feat-worker)"
    [ "$s" = "busy merged" ] && ok "/proc path marks a worktree busy" \
        || no "/proc path marks a worktree busy" "got: $s"

    check  # /proc branch honours the shell exclusion
    s="$(pstatusof feat-shell)"
    [ "$s" = "merged" ] && ok "/proc path excludes shells" \
        || no "/proc path excludes shells" "got: $s"

    rm -rf "$(dirname "$PSBX")"
fi

# ---------------------------------------------------------------------------
# Locks: `git worktree remove` refuses a locked tree outright (only 'remove
# -f -f' overrides), so a lock left behind by a crashed session pins the
# worktree forever. A lock whose owning pid is gone is debris -- reaping lifts
# it. A lock whose owner is alive means someone is really in there: busy.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    KSBX="$(mktemp -d)/lock2"; mkdir -p "$KSBX"

    # A definitely-dead pid: spawn, kill, reap. (Picking a number risks
    # colliding with a live process.)
    sleep 120 & DEAD_PID=$!
    kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null
    # A definitely-live pid, deliberately parked OUTSIDE any worktree so only
    # the lock-owner path can flag it busy, not the cwd scan.
    sleep 120 & LIVE_PID=$!

    (
        cd "$KSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$KSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g remote set-head origin main

        for n in stale live; do
            g worktree add -q "../wt-$n" -b "feat-$n"
            ( cd "../wt-$n" && echo x > "$n.txt" && g add "$n.txt" && g commit -qm "feature $n" )
            g merge -q --no-ff "feat-$n" -m "merge feat-$n"
        done
        g push -q origin main

        g worktree lock --reason "agent session alpha (pid $DEAD_PID start Mon)" ../wt-stale
        g worktree lock --reason "agent session beta (pid $LIVE_PID start Mon)"  ../wt-live
    ) >/dev/null 2>&1

    kstatusof() { "$REAPER" --json --path "$KSBX" 2>/dev/null \
        | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status' 2>/dev/null; }

    check  # dead owner -> locked, but not busy
    s="$(kstatusof feat-stale)"
    [ "$s" = "locked merged" ] && ok "stale lock reports locked, not busy" \
        || no "stale lock reports locked, not busy" "got: $s"

    check  # live owner -> busy
    s="$(kstatusof feat-live)"
    [ "$s" = "busy locked merged" ] && ok "live lock owner marks the worktree busy" \
        || no "live lock owner marks the worktree busy" "got: $s"

    check  # locked exposed as a JSON boolean
    n="$("$REAPER" --json --path "$KSBX" 2>/dev/null | jq -r 'map(select(.locked))|length' 2>/dev/null)"
    [ "$n" = 2 ] && ok "locked boolean set on both locked worktrees" \
        || no "locked boolean set on both locked worktrees" "got: $n"

    check  # the headline fix: a stale lock no longer blocks reaping
    "$REAPER" --reap --yes --merged --no-color --path "$KSBX" >/dev/null 2>&1
    if [ ! -d "$KSBX/wt-stale" ] && [ -d "$KSBX/wt-live" ]; then
        ok "reaping lifts a stale lock; a held lock is spared"
    else
        no "reaping lifts a stale lock; a held lock is spared" \
           "wt-stale=$([ -d "$KSBX/wt-stale" ]&&echo y||echo n) wt-live=$([ -d "$KSBX/wt-live" ]&&echo y||echo n)"
    fi

    kill "$LIVE_PID" 2>/dev/null; wait 2>/dev/null
    rm -rf "$(dirname "$KSBX")"
fi

# ---------------------------------------------------------------------------
# bb (getbb.app) worktrees: <data-dir>/worktrees/<env-id>/<repo>. The data dir
# lives outside every code root, so discovery has to know about it by name;
# reaping has to clear the now-empty <env-id> container it leaves behind.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    BSBX="$(mktemp -d)/bb"; mkdir -p "$BSBX/elsewhere"
    # These worktrees are bb-managed, so gh-reaper asks bb about them. A stub
    # bb reports their threads archived, which leaves them to the usual rules.
    make_stub_bb "$BSBX/stubbin"
    printf '[{"id":"thr_a","environmentId":"env_aaa","archivedAt":1,"deletedAt":null},{"id":"thr_b","environmentId":"env_bbb","archivedAt":1,"deletedAt":null}]\n' \
        > "$BSBX/threads.json"
    bbenv() { env -u BB_CLI PATH="$BSBX/stubbin:$PATH" STUB_BB_OPEN="$BSBX/threads.json" \
        STUB_BB_ARCHIVED="$BSBX/threads.json" STUB_BB_DATA_DIR="$BSBX/.bb" "$@"; }
    (
        cd "$BSBX" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$BSBX/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g remote set-head origin main
        # Default data dir ($HOME/.bb) and an explicit $BB_DATA_DIR one.
        mkdir -p "$BSBX/.bb/worktrees/env_aaa" "$BSBX/custom/worktrees/env_bbb"
        g worktree add -q "$BSBX/.bb/worktrees/env_aaa/repo" -b feat-bb-default
        g worktree add -q "$BSBX/custom/worktrees/env_bbb/repo" -b feat-bb-custom
        g push -q -u origin feat-bb-default
        g push -q -u origin feat-bb-custom
    ) >/dev/null 2>&1

    check  # found with no --path at all: the root has to be a curated default
    branches="$(cd "$BSBX/elsewhere" && HOME="$BSBX" bbenv "$REAPER" --json 2>/dev/null \
        | jq -r '.[].branch' 2>/dev/null | sort | tr '\n' ',')"
    [ "$branches" = "feat-bb-default," ] \
        && ok "scans bb's default data dir (~/.bb/worktrees)" \
        || no "scans bb's default data dir (~/.bb/worktrees)" "got: $branches"

    check  # $BB_DATA_DIR relocates it
    branches="$(cd "$BSBX/elsewhere" && HOME="$BSBX" BB_DATA_DIR="$BSBX/custom" \
        bbenv "$REAPER" --json 2>/dev/null | jq -r '.[].branch' 2>/dev/null | sort | tr '\n' ',')"
    [ "$branches" = "feat-bb-custom,feat-bb-default," ] \
        && ok "honors \$BB_DATA_DIR" \
        || no "honors \$BB_DATA_DIR" "got: $branches"

    check  # reaping clears the empty <env-id> husk but never the root itself
    ( cd "$BSBX/elsewhere" && HOME="$BSBX" bbenv "$REAPER" --reap --yes --no-color ) >/dev/null 2>&1
    if [ ! -d "$BSBX/.bb/worktrees/env_aaa" ] && [ -d "$BSBX/.bb/worktrees" ]; then
        ok "reaping removes the emptied env dir, keeps the scan root"
    else
        no "reaping removes the emptied env dir, keeps the scan root" \
           "env_aaa=$([ -d "$BSBX/.bb/worktrees/env_aaa" ]&&echo y||echo n) root=$([ -d "$BSBX/.bb/worktrees" ]&&echo y||echo n)"
    fi

    check  # a scan root passed explicitly is never rmdir'd out from under you
    ( cd "$BSBX/elsewhere" && HOME="$BSBX" bbenv "$REAPER" --reap --yes --no-color \
        --path "$BSBX/custom/worktrees/env_bbb" ) >/dev/null 2>&1
    if [ ! -d "$BSBX/custom/worktrees/env_bbb/repo" ] && [ -d "$BSBX/custom/worktrees/env_bbb" ]; then
        ok "an explicit scan root survives reaping its last worktree"
    else
        no "an explicit scan root survives reaping its last worktree" \
           "wt=$([ -d "$BSBX/custom/worktrees/env_bbb/repo" ]&&echo y||echo n) root=$([ -d "$BSBX/custom/worktrees/env_bbb" ]&&echo y||echo n)"
    fi

    rm -rf "$(dirname "$BSBX")"
fi


# ---------------------------------------------------------------------------
# bb-live: a bb worktree whose thread is still open is never reaped -- not by
# --merged --reap --yes, not by --force. Found in the field: a disk-full
# `--merged --reap` swept nine live threads' worktrees, because a thread whose
# PR merged still reads `merged clean` while bb keeps running turns in it.
# Current layout: <data-dir>/plugins/environment-git-worktree/host-data/
# worktrees/thr_<id>-<n>/<repo>, beside bb's <repo>.completed marker.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    NTOP="$(mktemp -d)"
    make_stub_bb "$NTOP/stubbin"
    BBWT=".bb/plugins/environment-git-worktree/host-data/worktrees"

    # Threads: thr_live1 open; thr_arch1 archived; thr_gone1 deleted (in no
    # list, `show` 404s); thr_arch2 archived but its env dir is shared with the
    # open thr_share; env_old1 is an old-layout env of the open thr_old.
    # thr_unk1 is in no list, but `show` finds it open (a hidden thread).
    # The open list carries archived threads too, as real bb's does.
    make_bb_fixture() {  # $1 = sandbox (becomes $HOME)
        local s="$1" n
        mkdir -p "$s/elsewhere" "$s/show"
        (
            cd "$s" || exit 1
            g init --bare remote.git >/dev/null
            g init repo >/dev/null
            cd repo || exit 1
            g remote add origin "$s/remote.git"
            echo hi > a.txt; g add a.txt; g commit -qm init
            g push -q -u origin main
            g remote set-head origin main
            for n in live1 arch1 gone1 arch2 unk1; do
                mkdir -p "$s/$BBWT/thr_$n-1"
                g worktree add -q "$s/$BBWT/thr_$n-1/repo" -b "feat-$n"
                : > "$s/$BBWT/thr_$n-1/repo.completed"
            done
            mkdir -p "$s/.bb/worktrees/env_old1"
            g worktree add -q "$s/.bb/worktrees/env_old1/repo" -b feat-old1
            for n in live1 arch1 gone1 arch2 unk1 old1; do
                ( cd "$s/repo" && g merge -q --no-ff "feat-$n" -m "merge feat-$n" )
            done
            g push -q origin main
        ) >/dev/null 2>&1
        cat > "$s/open.json" <<JSON
[{"id":"thr_live1","environmentId":"env_l1","archivedAt":null,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_live1-1/repo"},
 {"id":"thr_share","environmentId":"env_sh","archivedAt":null,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_arch2-1/repo"},
 {"id":"thr_old","environmentId":"env_old1","archivedAt":null,"deletedAt":null,"environmentPath":null},
 {"id":"thr_arch1","environmentId":"env_a1","archivedAt":1700000000000,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_arch1-1/repo"},
 {"id":"thr_arch2","environmentId":"env_a2","archivedAt":1700000000000,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_arch2-1/repo"}]
JSON
        cat > "$s/archived.json" <<JSON
[{"id":"thr_arch1","environmentId":"env_a1","archivedAt":1700000000000,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_arch1-1/repo"},
 {"id":"thr_arch2","environmentId":"env_a2","archivedAt":1700000000000,"deletedAt":null,"environmentPath":"$s/$BBWT/thr_arch2-1/repo"}]
JSON
        printf '{"thread":{"id":"thr_unk1","archivedAt":null,"deletedAt":null}}\n' > "$s/show/thr_unk1.json"
    }
    # Run gh-reaper against sandbox $1 with the stub bb, HOME pointed at it.
    nbb() {
        local s="$1"; shift
        ( cd "$s/elsewhere" && env -u BB_CLI -u BB_DATA_DIR HOME="$s" PATH="$NTOP/stubbin:$PATH" \
            STUB_BB_OPEN="$s/open.json" STUB_BB_ARCHIVED="$s/archived.json" \
            STUB_BB_SHOW_DIR="$s/show" STUB_BB_DATA_DIR="$s/.bb" STUB_BB_LOG="$s/bb.log" \
            "$REAPER" "$@" )
    }
    alive() { local o="" n; for n in "$@"; do [ -d "$n" ] && o="$o y" || o="$o n"; done; printf '%s' "${o# }"; }

    S1="$NTOP/s1"; make_bb_fixture "$S1"
    nstatus() { nbb "$S1" --json 2>/dev/null | jq -r --arg b "$1" '.[]|select(.branch==$b)|.status'; }

    check
    s="$(nstatus feat-live1)"
    [ "$s" = "bb-live merged" ] && ok "open bb thread's worktree reads bb-live" \
        || no "open bb thread's worktree reads bb-live" "got: $s"

    check
    got="$(nstatus feat-arch1)/$(nstatus feat-gone1)"
    [ "$got" = "merged/merged" ] && ok "archived and deleted bb threads' worktrees read normally" \
        || no "archived and deleted bb threads' worktrees read normally" "got: $got"

    check  # threads share environments: an open one in the dir wins over the dir's name
    s="$(nstatus feat-arch2)"
    [ "$s" = "bb-live merged" ] && ok "a dir named for an archived thread but used by an open one is bb-live" \
        || no "a dir named for an archived thread but used by an open one is bb-live" "got: $s"

    check
    s="$(nstatus feat-unk1)"
    [ "$s" = "bb-live merged" ] && ok "a thread missing from the lists is asked for by name" \
        || no "a thread missing from the lists is asked for by name" "got: $s"

    check  # older bb: <data-dir>/worktrees/env_<id>/<repo>
    s="$(nstatus feat-old1)"
    [ "$s" = "bb-live merged" ] && ok "old-layout env of an open thread is bb-live" \
        || no "old-layout env of an open thread is bb-live" "got: $s"

    check
    n="$(nbb "$S1" --json 2>/dev/null | jq -r 'map(select(.bbLive))|length')"
    [ "$n" = 4 ] && ok "bbLive boolean in JSON" || no "bbLive boolean in JSON" "got: $n"

    check
    out="$(nbb "$S1" --no-color 2>/dev/null)"
    [[ "$out" == *"bb-live merged"* ]] && ok "table shows bb-live" || no "table shows bb-live" "$out"

    check  # one up-front pair of list calls, not one call per worktree
    : > "$S1/bb.log"; nbb "$S1" --json >/dev/null 2>&1
    n="$(grep -c '^thread list' "$S1/bb.log")"
    [ "$n" = 2 ] && ok "bb is asked once per run" || no "bb is asked once per run" "thread list calls: $n"

    check  # the incident: --merged --reap --yes
    nbb "$S1" --merged --reap --yes --no-color >/dev/null 2>&1
    got="$(alive "$S1/$BBWT/thr_live1-1/repo" "$S1/$BBWT/thr_arch2-1/repo" "$S1/$BBWT/thr_unk1-1/repo" \
        "$S1/.bb/worktrees/env_old1/repo" "$S1/$BBWT/thr_arch1-1/repo" "$S1/$BBWT/thr_gone1-1/repo")"
    [ "$got" = "y y y y n n" ] && ok "--merged --reap --yes spares bb-live, reaps archived/deleted" \
        || no "--merged --reap --yes spares bb-live, reaps archived/deleted" "live1 arch2 unk1 old1 arch1 gone1 = $got"

    check  # bb's own bookkeeping in the env dir is not ours to touch
    [ -f "$S1/$BBWT/thr_live1-1/repo.completed" ] && [ -f "$S1/$BBWT/thr_arch1-1/repo.completed" ] \
        && ok "bb's .completed markers are left alone" || no "bb's .completed markers are left alone" "marker gone"

    check  # --force is no override for bb-live
    S2="$NTOP/s2"; make_bb_fixture "$S2"
    out="$(nbb "$S2" --reap --yes --force --no-color 2>&1)"
    got="$(alive "$S2/$BBWT/thr_live1-1/repo" "$S2/$BBWT/thr_arch2-1/repo" "$S2/$BBWT/thr_unk1-1/repo" \
        "$S2/.bb/worktrees/env_old1/repo" "$S2/$BBWT/thr_arch1-1/repo" "$S2/$BBWT/thr_gone1-1/repo")"
    [ "$got" = "y y y y n n" ] && ok "--force never reaps bb-live, still reaps archived" \
        || no "--force never reaps bb-live, still reaps archived" "live1 arch2 unk1 old1 arch1 gone1 = $got"

    check
    [[ "$out" == *"bb thread is still open"* ]] && ok "skip message names the open bb thread" \
        || no "skip message names the open bb thread" "$out"

    check  # a dirty bb-live tree, with --force: still spared
    echo wip > "$S2/$BBWT/thr_live1-1/repo/wip.txt"
    nbb "$S2" --reap --yes --force --no-color >/dev/null 2>&1
    [ -f "$S2/$BBWT/thr_live1-1/repo/wip.txt" ] && ok "--force spares a dirty bb-live worktree" \
        || no "--force spares a dirty bb-live worktree" "removed"

    check  # fail safe: bb errors -> every bb worktree is bb-live, said once
    S3="$NTOP/s3"; make_bb_fixture "$S3"
    err="$(STUB_BB_MODE=fail nbb "$S3" --reap --yes --force --no-color 2>&1 >/dev/null)"
    got="$(alive "$S3/$BBWT/thr_arch1-1/repo" "$S3/$BBWT/thr_gone1-1/repo" "$S3/$BBWT/thr_live1-1/repo" \
        "$S3/.bb/worktrees/env_old1/repo")"
    [ "$got" = "y y y y" ] && ok "failing bb: nothing bb-managed is reaped, even with --force" \
        || no "failing bb: nothing bb-managed is reaped, even with --force" "arch1 gone1 live1 old1 = $got"

    check
    n="$(printf '%s\n' "$err" | grep -c 'could not ask bb')"
    [ "$n" = 1 ] && ok "failing bb is reported once on stderr" || no "failing bb is reported once on stderr" "$err"

    check  # bb not installed at all: same fail-safe
    nobb_path=""
    IFS=: read -r -a __pe <<<"$PATH"
    for d in "${__pe[@]}"; do [ -x "$d/bb" ] || nobb_path="${nobb_path:+$nobb_path:}$d"; done
    s="$(cd "$S3/elsewhere" && env -u BB_CLI -u BB_DATA_DIR HOME="$S3" PATH="$nobb_path" \
        "$REAPER" --json 2>/dev/null | jq -r '[.[].status]|map(select(startswith("bb-live")))|length')"
    [ "$s" = 6 ] && ok "no bb CLI: every bb-managed worktree is bb-live" \
        || no "no bb CLI: every bb-managed worktree is bb-live" "got: $s"

    check  # a bad answer is a failure too: an error envelope is not a thread list
    printf '{"ok": false}\n' > "$S3/open.json"
    s="$(nbb "$S3" --json 2>/dev/null | jq -r 'map(select(.bbLive))|length')"
    [ "$s" = 6 ] && ok "malformed bb output: every bb-managed worktree is bb-live" \
        || no "malformed bb output: every bb-managed worktree is bb-live" "got: $s"

    check  # $BB_DATA_DIR: the current layout under a relocated data dir
    S4="$NTOP/s4"; make_bb_fixture "$S4"
    mv "$S4/.bb" "$S4/relocated"
    s="$(cd "$S4/elsewhere" && env -u BB_CLI HOME="$S4" BB_DATA_DIR="$S4/relocated" \
        PATH="$NTOP/stubbin:$PATH" STUB_BB_MODE=fail "$REAPER" --json 2>/dev/null \
        | jq -r 'map(select(.bbLive))|length')"
    [ "$s" = 6 ] && ok "finds and protects bb worktrees under \$BB_DATA_DIR" \
        || no "finds and protects bb worktrees under \$BB_DATA_DIR" "got: $s"

    check  # a worktree outside bb never costs a bb call
    : > "$S1/bb.log"
    ( cd "$S1/elsewhere" && env -u BB_CLI HOME="$S1" PATH="$NTOP/stubbin:$PATH" STUB_BB_LOG="$S1/bb.log" \
        "$REAPER" --json --path "$S1/repo" ) >/dev/null 2>&1
    g -C "$S1/repo" worktree add -q "$S1/plain" -b feat-plain >/dev/null 2>&1
    ( cd "$S1/elsewhere" && env -u BB_CLI HOME="$S1" PATH="$NTOP/stubbin:$PATH" STUB_BB_LOG="$S1/bb.log" \
        "$REAPER" --json --path "$S1/plain" ) >/dev/null 2>&1
    [ ! -s "$S1/bb.log" ] && ok "bb is not consulted without bb-managed worktrees" \
        || no "bb is not consulted without bb-managed worktrees" "$(cat "$S1/bb.log")"

    rm -rf "$NTOP"
fi

# ---------------------------------------------------------------------------
echo
printf "Tests run: %d   ${GREEN}passed: %d${NC}   ${RED}failed: %d${NC}\n" "$RUN" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
