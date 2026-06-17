#!/usr/bin/env bash
# Minimal stream-json CLI mock for CrowdControl tests.
#
# Emits a system/init message immediately, then for each user JSON line
# received on stdin emits a single assistant message and a result message
# echoing the prompt content.
#
# Optional behavior is toggled by environment variables (so the test
# harness can pass them via CrowdControl's :env option):
#   FAKE_CLI_SLEEP=<seconds>   sleep before result (simulate slow CLI)
#   FAKE_CLI_FAIL=1            exit non-zero after first message
#   FAKE_CLI_ECHO_ENV=<NAME>   include env var value in result.result
#   FAKE_CLI_GARBAGE=1         emit a non-JSON line before init
#   FAKE_CLI_SESSION_ID=<id>   override the assigned session id
#   FAKE_CLI_STREAM_NORESULT=<n>  emit <n> assistant messages (50ms apart) and
#                              never a result (exercises wait_for_result's
#                              absolute deadline under a steady message stream)

# JSON-escape a string so the emitted line is always valid JSON: backslash and
# double quote, the named control escapes (\b \t \n \f \r), and \u00NN for any
# remaining control byte. LC_ALL=C makes awk operate byte-wise so multibyte
# UTF-8 (e.g. "café-✓") passes through untouched. NB: env values reject all
# control chars upstream (CrowdControl.CLI.validate_env!), so the control-char
# branches are defense-in-depth for the oracle, not a live round-trip path.
json_escape() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    {
      res = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1); b = ord[c]
        if (c == "\\") res = res "\\\\"
        else if (c == "\"") res = res "\\\""
        else if (b == 8) res = res "\\b"
        else if (b == 9) res = res "\\t"
        else if (b == 10) res = res "\\n"
        else if (b == 12) res = res "\\f"
        else if (b == 13) res = res "\\r"
        else if (b < 32) res = res sprintf("\\u%04x", b)
        else res = res c
      }
      printf "%s", res
    }
  '
}

SESSION_ID="${FAKE_CLI_SESSION_ID:-test-session-$$}"

if [ "${FAKE_CLI_GARBAGE:-}" = "1" ]; then
  echo "not-json-but-newline-terminated"
fi

printf '{"type":"system","subtype":"init","session_id":"%s","tools":[]}\n' "$SESSION_ID"

while IFS= read -r line; do
  # Crude, deliberately limited content extraction: grabs the first
  # "content":"..." run up to the next double quote. It does NOT correctly
  # handle prompt content with embedded quotes/backslashes — the oracle's
  # faithful round-trip surface is *env values* (read directly from the
  # environment, see FAKE_CLI_ECHO_ENV below), which is what the security
  # tests assert against. Tests must not depend on round-tripping arbitrary
  # prompt content through this sed.
  content_raw=$(printf '%s' "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  content=$(json_escape "$content_raw")

  if [ -n "${FAKE_CLI_STREAM_NORESULT:-}" ]; then
    i=0
    while [ "$i" -lt "$FAKE_CLI_STREAM_NORESULT" ]; do
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"chunk:%d"}]}}\n' "$i"
      sleep 0.05
      i=$((i + 1))
    done
    exit 0
  fi

  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"echo:%s"}]}}\n' "$content"

  if [ -n "${FAKE_CLI_SLEEP:-}" ]; then
    sleep "$FAKE_CLI_SLEEP"
  fi

  if [ -n "${FAKE_CLI_ECHO_ENV:-}" ]; then
    # Bash indirect expansion — read the env var named by FAKE_CLI_ECHO_ENV
    # without `eval`, so a hostile var name/value can't be executed.
    val="${!FAKE_CLI_ECHO_ENV}"
    val_escaped=$(json_escape "$val")
    printf '{"type":"result","subtype":"success","result":"%s=%s","total_cost_usd":0}\n' "$FAKE_CLI_ECHO_ENV" "$val_escaped"
  else
    printf '{"type":"result","subtype":"success","result":"done:%s","total_cost_usd":0}\n' "$content"
  fi

  if [ "${FAKE_CLI_FAIL:-}" = "1" ]; then
    exit 1
  fi

  # One prompt-cycle per fake-cli invocation matches the Claude CLI's behavior.
  exit 0
done
