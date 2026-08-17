#!/usr/bin/env bats
# THE SAME LOSS, ON THE OTHER HELPER (#850).
#
# `_remote_http_get_json` discarded curl's stderr exactly as the POST helper
# did, and reports the same `000` for every failure alike. `pull` goes through
# here, so a failure on this path was as undiagnosable as the connect one.
#
# SEPARATE TESTS, NOT A SHARED ONE. This is a different function with a
# different shape -- no fifo, no copier, its own trap and its own cleanup --
# and the two were fixed in two pull requests so that a mutation in one cannot
# be covered by the other's tests. A parameterised file over both helpers would
# put that back: reverting the GET change would redden a case whose name says
# POST, and the attribution is the thing being bought.
#
# Stderr is captured to a FILE rather than read from bats's `$output`, which
# merges the streams. The http code goes to stdout and the diagnosis has to go
# to stderr; a test that cannot tell them apart cannot say that.

load test_helper

SANDBOX_TOOLS=(bash dirname mktemp mkfifo chmod rm rmdir sed cp cat grep python3 uname)

setup() {
  setup_test_env

  STUB_SRC="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_SRC"

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
  exit 7
fi
# The GET helper sends the team in a header and expects a body back; nothing
# here dumps headers, which is one of the shape differences from the POST side.
grep -q '^header = "Agmsg-Team-ID: ' "$cfg" || { echo "STUB_CURL: no team header" >&2; exit 2; }
[ -z "$out" ] || printf '{"teams":[]}' > "$out"
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

get_with_curl() {
  local mode="$1" stderr_text="$2"
  RUN_TMPDIR="$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  ERR_FILE="$BATS_TEST_TMPDIR/helper-stderr"
  local bin; bin="$(sandbox_path)"

  run env PATH="$bin" TMPDIR="$RUN_TMPDIR" STUB_CURL_MODE="$mode" \
    STUB_CURL_STDERR="$stderr_text" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_get_json "https://example.invalid/v1/teams" "team-abc" \
      "'"$RUN_TMPDIR"'/out-body" 2>"'"$ERR_FILE"'"
  '
}

@test "GET: a failing curl's diagnosis reaches the caller's stderr (#850)" {
  # `pull` is the command a person runs here, and before this it could only say
  # 000 -- the same 000 as a refused connection, a timeout, or an unopenable
  # path.
  get_with_curl fail "curl: (7) Failed to connect to example.invalid port 443"
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]

  grep -q 'Failed to connect' "$ERR_FILE"
}

@test "GET: a successful curl's stderr is NOT shown, even when it wrote something (#850)" {
  # Tells "shown only when curl failed" apart from "the stream was empty". The
  # stub deliberately writes on the success path; real curl -sS would not, and
  # a quiet stub would pass against an unconditional dump.
  get_with_curl ok "a progress line nobody asked for"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  [ ! -s "$ERR_FILE" ]
}

@test "GET: the http code is unchanged on both paths (#850)" {
  get_with_curl ok ""
  [ "$output" = "200" ]

  get_with_curl fail "curl: (28) Operation timed out"
  [ "$output" = "000" ]
}

@test "GET: no scratch file is left behind, on either path (#850)" {
  # This helper writes a config and now an error file, and removes both. Each
  # run gets a private TMPDIR so the question is about this call only.
  get_with_curl ok ""
  [ "$output" = "200" ]
  refute ls "$RUN_TMPDIR"/agmsg-curl-err.* 2>/dev/null
  refute ls "$RUN_TMPDIR"/agmsg-curl-cfg.* 2>/dev/null

  get_with_curl fail "curl: (28) Operation timed out"
  [ "$output" = "000" ]
  refute ls "$RUN_TMPDIR"/agmsg-curl-err.* 2>/dev/null
  refute ls "$RUN_TMPDIR"/agmsg-curl-cfg.* 2>/dev/null
}

@test "GET: the leftover check can see a leftover when there is one (#850)" {
  # Control on the absence above: a glob matching nothing looks the same as a
  # glob aimed at the wrong directory.
  get_with_curl ok ""
  : > "$RUN_TMPDIR/agmsg-curl-err.planted"
  run ls "$RUN_TMPDIR"/agmsg-curl-err.*
  [ "$status" -eq 0 ]
}

@test "GET: the request still carries the team header (#850)" {
  # The contract the stub leans on, asserted rather than assumed. Without this
  # the stub's own guard could be satisfied by a config that changed shape, and
  # every case above would be reporting on something other than a GET.
  get_with_curl ok ""
  [ "$output" = "200" ]
  [ -s "$RUN_TMPDIR/out-body" ]
}
