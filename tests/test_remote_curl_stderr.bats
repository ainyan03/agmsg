#!/usr/bin/env bats
# WHEN THE ONLY THING A CALLER SEES IS "000", THROWING AWAY curl's STDERR IS
# THROWING AWAY THE DIAGNOSIS (#850).
#
# `_remote_http_post_json` reports `000` for every kind of failure alike: a
# refused connection, a timeout, a path curl could not open. The reason existed
# each time -- curl wrote it to stderr -- and `2>/dev/null` discarded it. A
# Windows run spent an afternoon on a bare `000` whose cause was in that stream.
#
# WHAT HAS TO HOLD, and each is its own case here:
#
#   on failure   the diagnosis reaches the caller's stderr
#   on success   nothing does, even if curl wrote something -- the show is
#                gated on curl having FAILED, not on the stream being empty
#   either way   the http code is exactly what it was before
#   either way   no scratch file is left behind
#
# The stderr of the helper is captured to a FILE rather than read from bats's
# `$output`, which merges the two streams: a test that cannot tell stdout from
# stderr cannot check that a message went to the right one, and "the message
# appears somewhere" is what this fix is not about.

load test_helper

SANDBOX_TOOLS=(bash dirname mktemp mkfifo chmod rm rmdir sed cp cat grep python3 uname)

setup() {
  setup_test_env

  STUB_SRC="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_SRC"

  # A curl whose behaviour the test dictates: STUB_CURL_MODE says whether it
  # succeeds, and STUB_CURL_STDERR is written to stderr either way. Writing on
  # the success path too is the point of one of the cases below -- it is how
  # "shown only when curl failed" is told apart from "the stream was empty".
  cat > "$STUB_SRC/curl" <<'STUB'
#!/usr/bin/env bash
set -u
cfg=""; out=""; prev=""
for arg in "$@"; do
  case "$prev" in
    -K) cfg="$arg" ;;
    -o) out="$arg" ;;
  esac
  prev="$arg"
done
[ -z "${STUB_CURL_STDERR:-}" ] || printf '%s\n' "$STUB_CURL_STDERR" >&2
if [ "${STUB_CURL_MODE:-ok}" = "fail" ]; then
  # A real curl that cannot open a config path exits non-zero and writes
  # nothing to the output file. Exit 26 is curl's "read error".
  exit 26
fi
hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$cfg")"
[ -z "$hdr" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
[ -z "$out" ] || printf '{"ok":true}' > "$out"
printf '200'
STUB
  chmod +x "$STUB_SRC/curl"
}

teardown() { teardown_test_env; }

sandbox_path() {
  local dir tool src
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/sandbox.XXXXXX")"
  for tool in "${SANDBOX_TOOLS[@]}"; do
    src="$(command -v "$tool")" || { echo "host lacks $tool" >&2; return 1; }
    ln -s "$src" "$dir/$tool"
  done
  ln -s "$STUB_SRC/curl" "$dir/curl"
  printf '%s' "$dir"
}

# Runs the helper with its own TMPDIR, so "what scratch files remain" is a
# question about this call and not about everything else on the machine.
# stdout (the http code) lands in $output; stderr lands in $ERR_FILE.
post_with_curl() {
  local mode="$1" stderr_text="$2"
  RUN_TMPDIR="$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  ERR_FILE="$BATS_TEST_TMPDIR/helper-stderr"
  local bin; bin="$(sandbox_path)"
  local body="$RUN_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  run env PATH="$bin" TMPDIR="$RUN_TMPDIR" STUB_CURL_MODE="$mode" \
    STUB_CURL_STDERR="$stderr_text" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body"'" \
      "'"$RUN_TMPDIR"'/out-body" "'"$RUN_TMPDIR"'/out-header" 2>"'"$ERR_FILE"'"
  '
}

@test "a failing curl's diagnosis reaches the caller's stderr (#850)" {
  # The whole point. Without this the operator has "000" and nothing else, and
  # the reason they need is written down and then deleted.
  post_with_curl fail "curl: (26) Failed to open/read local data from file"
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]

  grep -q 'Failed to open/read local data' "$ERR_FILE"
}

@test "a successful curl's stderr is NOT shown, even when it wrote something (#850)" {
  # Distinguishes "shown only when curl failed" from "the stream happened to be
  # empty". curl -sS is quiet on success, so a test that let it stay quiet here
  # would pass against a version that dumped stderr unconditionally -- and that
  # version would drop noise into the middle of a caller's output.
  post_with_curl ok "a progress line nobody asked for"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  [ ! -s "$ERR_FILE" ]
}

@test "the http code is unchanged on both paths (#850)" {
  # The contract this must not have altered while adding the diagnosis.
  post_with_curl ok ""
  [ "$output" = "200" ]

  post_with_curl fail "curl: (7) Failed to connect"
  [ "$output" = "000" ]
}

@test "no scratch file is left behind, on either path (#850)" {
  # The helper writes a config, a fifo directory and now an error file. All of
  # them are removed on the normal paths; this asserts it for the run's own
  # TMPDIR, so nothing else on the machine can make the check pass or fail.
  post_with_curl ok ""
  [ "$output" = "200" ]
  refute ls "$RUN_TMPDIR"/agmsg-curl-err.* 2>/dev/null
  refute ls "$RUN_TMPDIR"/agmsg-curl-cfg.* 2>/dev/null

  post_with_curl fail "curl: (7) Failed to connect"
  [ "$output" = "000" ]
  refute ls "$RUN_TMPDIR"/agmsg-curl-err.* 2>/dev/null
  refute ls "$RUN_TMPDIR"/agmsg-curl-cfg.* 2>/dev/null
}

@test "the leftover check can see a leftover when there is one (#850)" {
  # Control on the assertion above, which is an absence: a glob that matches
  # nothing looks exactly like a glob pointed at the wrong directory. Plant one
  # and confirm the same check fires.
  post_with_curl ok ""
  : > "$RUN_TMPDIR/agmsg-curl-err.planted"
  run ls "$RUN_TMPDIR"/agmsg-curl-err.*
  [ "$status" -eq 0 ]
}
