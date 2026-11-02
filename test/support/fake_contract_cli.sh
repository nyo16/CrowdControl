#!/usr/bin/env bash
# A stand-in Claude Code binary for `mix crowd_control.contract` tests.
#
# It answers just enough of the CLI's surface for the contract task:
#   --version           prints "$FAKE_CONTRACT_VERSION (Claude Code)"
#   --help              lists every flag in $FAKE_CONTRACT_FLAGS (space separated)
#   --print <hidden>    a bare hidden flag from $FAKE_CONTRACT_HIDDEN gets the
#                       parser's "argument missing" error; anything else that is
#                       not a known flag gets "unknown option"
#   stream-json mode    answers `initialize` and `interrupt` control requests
#
# Behaviour knobs (environment):
#   FAKE_CONTRACT_VERSION        version to report (default 2.1.292)
#   FAKE_CONTRACT_FLAGS          flags --help lists (default: none)
#   FAKE_CONTRACT_HIDDEN         hidden flags that take an operand
#                                (default: --permission-prompt-tool)
#   FAKE_CONTRACT_PENDING_INSIDE=1  put pending_permission_requests inside
#                                `response` instead of at envelope level

version="${FAKE_CONTRACT_VERSION:-2.1.292}"
hidden="${FAKE_CONTRACT_HIDDEN:---permission-prompt-tool}"

case " $* " in
  *" --version "*)
    echo "$version (Claude Code)"
    exit 0
    ;;
  *" --help "*)
    echo "Usage: claude [options] [command] [prompt]"
    echo
    echo "Options:"
    for flag in $FAKE_CONTRACT_FLAGS; do
      echo "  $flag <value>    fake help text"
    done
    exit 0
    ;;
esac

# `claude --print <flag>` with nothing after the flag: the parser's verdict.
if [ "$#" -eq 2 ] && [ "$1" = "--print" ]; then
  for flag in $hidden; do
    if [ "$2" = "$flag" ]; then
      echo "Error: option '$flag <value>' argument missing" >&2
      exit 1
    fi
  done
  echo "error: unknown option '$2'" >&2
  exit 1
fi

case " $* " in
  *" --input-format stream-json "*) ;;
  *)
    echo "error: fake contract CLI only speaks stream-json" >&2
    exit 1
    ;;
esac

while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')

  case "$line" in
    *'"subtype":"initialize"'*)
      if [ "${FAKE_CONTRACT_PENDING_INSIDE:-}" = "1" ]; then
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"session_state":"idle","pending_permission_requests":[]}}}\n' "$id"
      else
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"session_state":"idle"},"pending_permission_requests":[],"pending_user_dialog_requests":[]}}\n' "$id"
      fi
      ;;
    *'"subtype":"interrupt"'*)
      printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"still_queued":[]}}}\n' "$id"
      ;;
    *)
      printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Unsupported control request subtype"}}\n' "$id"
      ;;
  esac
done
