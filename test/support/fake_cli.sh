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
#   FAKE_CLI_ERROR_SUBTYPE=<s> emit an is_error result with subtype <s>
#   FAKE_CLI_UUID_ECHO=0       leave the prompt's "uuid" off the result (by
#                              default it is echoed as both "user_message_uuid"
#                              and "user_message_uuids", as claude 2.1.292 does)
#   FAKE_CLI_RATE_LIMIT=1      emit one rate_limit_event before the result
#   FAKE_CLI_ECHO_ARGV=1       result.result is the argv, each token in [ ]
#
# Every result also carries a fixed "usage".

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
# Every argv token bracketed, so an empty one shows as [].
ARGV=$(printf '[%s]' "$@")

if [ "${FAKE_CLI_GARBAGE:-}" = "1" ]; then
  echo "not-json-but-newline-terminated"
fi

printf '{"type":"system","subtype":"init","session_id":"%s","tools":[]}\n' "$(json_escape "$SESSION_ID")"

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

  # Fields appended to every result: a fixed usage, and the prompt's uuid.
  uuid=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
  extra=',"usage":{"input_tokens":3,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":7}'
  if [ -n "$uuid" ] && [ "${FAKE_CLI_UUID_ECHO:-1}" != "0" ]; then
    escaped_uuid=$(json_escape "$uuid")
    extra="$extra,\"user_message_uuid\":\"$escaped_uuid\",\"user_message_uuids\":[\"$escaped_uuid\"]"
  fi

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

  if [ "${FAKE_CLI_RATE_LIMIT:-}" = "1" ]; then
    printf '{"type":"rate_limit_event","session_id":"%s","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":4102444800,"utilization":1.0}}\n' "$(json_escape "$SESSION_ID")"
  fi

  if [ -n "${FAKE_CLI_ERROR_SUBTYPE:-}" ]; then
    printf '{"type":"result","subtype":"%s","is_error":true,"num_turns":1,"session_id":"%s","total_cost_usd":0%s}\n' "$(json_escape "$FAKE_CLI_ERROR_SUBTYPE")" "$(json_escape "$SESSION_ID")" "$extra"
  elif [ -n "${FAKE_CLI_ECHO_ENV:-}" ]; then
    # Read the env var named by FAKE_CLI_ECHO_ENV without evaluating anything.
    # NOT `${!FAKE_CLI_ECHO_ENV}`: bash evaluates array subscripts inside
    # indirect expansion arithmetically, so a value like 'x[$(touch /tmp/pwned)]'
    # -- which passes CrowdControl.CLI.validate_env!/1 -- executes. This script
    # is the oracle that proves the escaping works, so it must not itself be
    # bypassable. printenv performs a plain lookup.
    val=$(printenv "$FAKE_CLI_ECHO_ENV" || true)
    val_escaped=$(json_escape "$val")
    printf '{"type":"result","subtype":"success","result":"%s=%s","total_cost_usd":0%s}\n' "$FAKE_CLI_ECHO_ENV" "$val_escaped" "$extra"
  elif [ "${FAKE_CLI_ECHO_ARGV:-}" = "1" ]; then
    printf '{"type":"result","subtype":"success","result":"%s","total_cost_usd":0%s}\n' "$(json_escape "$ARGV")" "$extra"
  else
    printf '{"type":"result","subtype":"success","result":"done:%s","total_cost_usd":0%s}\n' "$content" "$extra"
  fi

  if [ "${FAKE_CLI_FAIL:-}" = "1" ]; then
    exit 1
  fi

  # One prompt-cycle per fake-cli invocation matches the Claude CLI's behavior.
  exit 0
done
