#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

LUA="$SRC/build/oracle/lua"
[ -x "$LUA" ] || { echo "missing $LUA — mayhem/build.sh should have built it" >&2; emit_ctrf "luv" 0 1 0; exit 1; }
export LUA_CPATH="$SRC/build/oracle/?.so"

passed=0; failed=0

# 1. Upstream's TAP suite (tests/run.lua), run against the normally-built luv module.
tap="$(mktemp)"
timeout 900 "$LUA" tests/run.lua > "$tap" 2>&1
tap_rc=$?
tap_ok=$(grep -c '^ok ' "$tap")
tap_bad=$(grep -c '^not ok ' "$tap")
passed=$(( passed + tap_ok )); failed=$(( failed + tap_bad ))
# the suite has 178 cases; far fewer means the runner was cut short (or replaced by a no-op)
if [ "$tap_rc" -ne 0 ] || [ "$tap_ok" -lt 170 ] || ! grep -q '^# All tests passed' "$tap"; then
  echo "upstream suite: rc=$tap_rc ok=$tap_ok not-ok=$tap_bad" >&2
  tail -20 "$tap" >&2
  failed=$(( failed + 1 ))
fi
rm -f "$tap"

# 1b. The rest of upstream's `make test`: the embedding host (src/test.c, built by build.sh) runs
#     tests/manual-test-external-loop.lua on a caller-owned loop with a thread VM. Its exit status
#     is luaL_dofile's code returned as a result count (a script error still exits 0), so require
#     the lines the script prints when both loops finish instead.
HOST="$SRC/build/oracle/test"
if [ -x "$HOST" ]; then
  ext="$(cd "$SRC" && timeout 120 "$HOST" tests/manual-test-external-loop.lua 2>&1)"
  if grep -qx 'thread Lua done' <<<"$ext" && grep -qx 'Main Lua done' <<<"$ext" \
     && [ "$(tail -n1 <<<"$ext")" = "DONE" ]; then
    passed=$(( passed + 1 ))
  else
    failed=$(( failed + 1 ))
    printf 'external-loop test FAILED:\n%s\n' "$ext" >&2
  fi
else
  echo "missing $HOST — mayhem/build.sh should have built it" >&2
  failed=$(( failed + 1 ))
fi

# 2. Known-answer probes: a script run through the built interpreter must print exactly this.
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT
mkdir "$fx/sub"; : > "$fx/a.txt"; printf 'hello luv' > "$fx/b.txt"

probe() { # probe <name> <expected stdout> <lua chunk>
  local name="$1" want="$2" got
  got="$(FX="$fx" timeout 60 "$LUA" -e "local uv = require 'luv' $3" 2>&1)"
  if [ "$got" = "$want" ]; then
    passed=$(( passed + 1 ))
  else
    failed=$(( failed + 1 ))
    printf 'probe %s FAILED\n  want: %q\n  got:  %q\n' "$name" "$want" "$got" >&2
  fi
}

probe timer "t1,t2,t3" '
  local o, n, t = {}, 0, uv.new_timer()
  t:start(1, 1, function() n = n + 1; o[#o + 1] = "t" .. n; if n == 3 then t:close() end end)
  uv.run() print(table.concat(o, ","))'
probe version $'true\ttrue' 'print(uv.version_string():match("^%d+%.%d+%.%d+") ~= nil, uv.version() >= 0x012a00)'
probe wtf8 $'hi\t2\t2' '
  print(uv.utf16_to_wtf8("h\0i\0"), uv.utf16_length_as_wtf8("h\0i\0"), uv.wtf8_length_as_utf16("hi"))'
probe utf16 $'104\t0\t105\t0' 'print(uv.wtf8_to_utf16("hi"):byte(1, -1))'
probe errno $'-2\tENOENT: no such file or directory\tENOENT' '
  print(uv.errno.ENOENT, uv.translate_sys_error(2))'
probe scandir "directory:sub file:a.txt file:b.txt" '
  local r, t = uv.fs_scandir(os.getenv("FX")), {}
  while true do local n, k = uv.fs_scandir_next(r); if not n then break end; t[#t + 1] = k .. ":" .. n end
  table.sort(t) print(table.concat(t, " "))'
probe read $'hello luv\t9' '
  local fd = uv.fs_open(os.getenv("FX") .. "/b.txt", "r", 438)
  print(uv.fs_read(fd, 100, 0), uv.fs_fstat(fd).size) uv.fs_close(fd)'
probe stat $'directory\tfile' '
  print(uv.fs_stat(os.getenv("FX") .. "/sub").type, uv.fs_stat(os.getenv("FX") .. "/a.txt").type)'
probe async "pq" '
  local a, got; a = uv.new_async(function(x, y) got = x .. y; a:close() end)
  a:send("p", "q") uv.run() print(got)'
probe sem $'true\tfalse\ttrue' '
  local s = uv.new_sem(1)
  local a, b = s:trywait(), s:trywait() s:post() print(a, b, s:trywait())'

emit_ctrf "luv" "$passed" "$failed" 0
