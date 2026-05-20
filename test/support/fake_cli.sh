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

# JSON-escape a string: backslash, double quote, control chars.
json_escape() {
  local s="$1"
  # shellcheck disable=SC2001
  s=$(printf '%s' "$s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '%s' "$s"
}

SESSION_ID="${FAKE_CLI_SESSION_ID:-test-session-$$}"

if [ "${FAKE_CLI_GARBAGE:-}" = "1" ]; then
  echo "not-json-but-newline-terminated"
fi

printf '{"type":"system","subtype":"init","session_id":"%s","tools":[]}\n' "$SESSION_ID"

while IFS= read -r line; do
  content_raw=$(printf '%s' "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  content=$(json_escape "$content_raw")

  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"echo:%s"}]}}\n' "$content"

  if [ -n "${FAKE_CLI_SLEEP:-}" ]; then
    sleep "$FAKE_CLI_SLEEP"
  fi

  if [ -n "${FAKE_CLI_ECHO_ENV:-}" ]; then
    val=$(eval "printf '%s' \"\$$FAKE_CLI_ECHO_ENV\"")
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
