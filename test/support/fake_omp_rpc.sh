#!/usr/bin/env bash
# Minimal `omp --mode rpc` mock for CrowdControl tests.
#
# Emits a ready frame, then answers each JSONL command on stdin:
#   get_state -> a response frame carrying sessionId/model/dumpTools
#   prompt    -> an immediate ack, a message_end, then a terminal agent_end
# Unlike fake_cli.sh it does NOT exit after one turn: `omp --mode rpc` stays
# alive until stdin closes, which is what makes multi-turn sessions possible.
#
# Optional behavior toggles (passed via CrowdControl's :env option):
#   FAKE_OMP_SESSION_ID=<id>   override the reported session id
#   FAKE_OMP_PROMPT_FAIL=1     reject prompts with success:false
#   FAKE_OMP_NONTERMINAL=1     emit a non-terminal agent_end before the real one
#   FAKE_OMP_BAD_STATE=1       reply to get_state with a type-drifted payload
#                              ("model" a string, "dumpTools" a string). Models
#                              a future omp whose schema moved; decode must not
#                              raise, because it runs inside handle_cast/2.
#   FAKE_OMP_LOCAL_ONLY=1      answer prompts the way a local-only slash command
#                              does: agentInvoked:false and NO agent_end.
#
# Content extraction is the same deliberately crude sed as fake_cli.sh: it does
# not handle embedded quotes or backslashes in a prompt, so tests must not
# depend on round-tripping arbitrary prompt content through it.

SESSION_ID="${FAKE_OMP_SESSION_ID:-omp-session-$$}"

printf '{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2],"maxFrameBytes":1048576}\n'

field() {
  printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

while IFS= read -r line; do
  [ -z "$line" ] && continue

  id=$(field id "$line")
  type=$(field type "$line")

  case "$type" in
    get_state)
      if [ "${FAKE_OMP_BAD_STATE:-}" = "1" ]; then
        printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"sessionId":{"nested":1},"model":"fake-model","dumpTools":"read,write"}}\n' "$id"
      else
        printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"sessionId":"%s","sessionFile":"/tmp/%s.jsonl","model":{"id":"fake-model","provider":"fake","contextWindow":1000},"thinkingLevel":"off","dumpTools":[{"name":"read"},{"name":"write"}]}}\n' \
          "$id" "$SESSION_ID" "$SESSION_ID"
      fi
      ;;

    prompt)
      message=$(field message "$line")

      if [ "${FAKE_OMP_PROMPT_FAIL:-}" = "1" ]; then
        printf '{"id":"%s","type":"response","command":"prompt","success":false,"error":"rejected: %s","code":"session_busy"}\n' \
          "$id" "$message"
        continue
      fi

      if [ "${FAKE_OMP_LOCAL_ONLY:-}" = "1" ]; then
        printf '{"type":"command_output","output":"tool listing for %s"}\n' "$message"
        printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":false}}\n' "$id"
        continue
      fi

      printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"agentInvoked":true}}\n' "$id"
      printf '{"type":"agent_start"}\n'
      printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"echo:"}}\n'
      printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"echo:%s"}]}}\n' "$message"

      if [ "${FAKE_OMP_NONTERMINAL:-}" = "1" ]; then
        printf '{"type":"agent_end","messages":[],"isTerminal":false}\n'
      fi

      printf '{"type":"agent_end","isTerminal":true,"messages":[{"role":"user","content":[{"type":"text","text":"%s"}]},{"role":"assistant","content":[{"type":"text","text":"done:%s"}],"stopReason":"stop","duration":42,"usage":{"input":1,"output":2,"totalTokens":3,"cost":{"input":0.5,"output":0.25,"total":0.75}}}]}\n' \
        "$message" "$message"
      ;;

    *)
      printf '{"id":"%s","type":"response","command":"unknown","success":false,"error":"unsupported"}\n' "$id"
      ;;
  esac
done
