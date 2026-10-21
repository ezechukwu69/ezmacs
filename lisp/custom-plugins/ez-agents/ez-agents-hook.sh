#!/bin/sh
# ez-agents-hook.sh EVENT
# Forwards a coding-agent hook payload (JSON on stdin) to the running Emacs.
# A no-op outside sessions started by ez-agents (EZ_AGENT_SESSION unset).
[ -n "$EZ_AGENT_SESSION" ] || { cat >/dev/null; exit 0; }
event="$1"
payload=$(cat | base64 | tr -d '\n')
client="${EZ_AGENT_EMACSCLIENT:-emacsclient}"
if [ -n "$EZ_AGENT_SOCKET" ]; then
  set -- -s "$EZ_AGENT_SOCKET"
else
  set --
fi
"$client" "$@" -e "(ez-agents-event \"$EZ_AGENT_SESSION\" \"$event\" \"$payload\")" >/dev/null 2>&1 &
exit 0
