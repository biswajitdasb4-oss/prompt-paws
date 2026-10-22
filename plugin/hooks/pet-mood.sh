#!/bin/sh
# Prompt Paws hook for Claude Code: tells the desktop panda what each Claude session is doing.
# Run by the prompt-paws plugin (plugin/hooks/hooks.json) as:  pet-mood.sh <state>
#   thinking | typing | searching | working | needs_you | ready | notify | end
# Writes ~/.promptpaws/sessions/<session id> = "<state> <unix time> <project folder>"
# (needs_you and ready add a second line "<tty> <app id>").
# "notify" (Notification hook) becomes needs_you or ready from the notification type.
# Prints nothing and always exits 0, so it can never block or change Claude.
exec 2>/dev/null
input=""
[ -t 0 ] || input=$(cat)

# First "key": "value" pair in the hook's JSON (top-level keys come before tool input).
field() {
  printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 |
    sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

state=${1:-working}
if [ "$state" = notify ]; then
  case $(field notification_type) in
    permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input) state=needs_you ;;
    idle_prompt) state=ready ;;
    *) exit 0 ;;
  esac
fi

# Subagents share the session: only their questions for you change the pet.
[ -n "$(field agent_id)" ] && [ "$state" != needs_you ] && exit 0

sid=$(field session_id | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || sid=manual
dir="$HOME/.promptpaws/sessions"
mkdir -p "$dir"
if [ "$state" = end ]; then
  rm -f "$dir/$sid"
  exit 0
fi
project=$(field cwd)
project=${project##*/}

# Needs you or your turn: also note where Claude runs ("<tty> <app id>", "-" if unknown), so a click on
# the pet can bring that Terminal tab to the front. The first process up the chain with a terminal is Claude.
where=""
if [ "$state" = needs_you ] || [ "$state" = ready ]; then
  tty=- pid=$PPID n=0
  while [ $n -lt 5 ] && [ "${pid:-0}" -gt 1 ]; do
    set -- $(ps -o tty=,ppid= -p "$pid" 2>/dev/null)
    case $1 in ttys*) tty=$1; break ;; esac
    pid=$2 n=$((n + 1))
  done
  where="$tty ${__CFBundleIdentifier:--}"
fi

{
  printf '%s %s %s\n' "$state" "$(date +%s)" "${project:-Claude}"
  if [ -n "$where" ]; then printf '%s\n' "$where"; fi
} > "$dir/$sid.$$" && mv -f "$dir/$sid.$$" "$dir/$sid"
exit 0
