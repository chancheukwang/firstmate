#!/usr/bin/env bash
# Record a handled, delivered task generation so preserved task evidence no
# longer creates model work. The wake-drain acknowledgement is the normal caller.
# A fresh status, turn, metadata, queued task wake, or steering message makes the
# receipt inert; task records and passive checks remain in place.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'usage: fm-supervision-settle.sh <task-id>' >&2; exit 2 ;; esac
[ "$#" -eq 1 ] || { echo 'usage: fm-supervision-settle.sh <task-id>' >&2; exit 2; }

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
value() { sed -n "s/^$1=//p" "$META" 2>/dev/null | tail -1; }
refuse() { printf 'fm-supervision-settle: %s\n' "$1" >&2; exit 1; }

BEFORE=$(fm_sup_task_signature "$STATE" "$ID") || refuse 'task metadata or status is missing or unsafe'
fm_sup_task_has_unhandled_event "$STATE" "$ID" && refuse 'a task wake or instruction remains unhandled'
fm_wake_signal_reported_current "$STATE" "$STATUS" || refuse 'the current status was not surfaced to supervision'

KIND=$(value kind)
MODE=$(value mode)
LINE=$(status_current_line "$STATUS" "$KIND")
[ "$(status_line_verb "$LINE")" = 'done' ] || refuse 'current task declaration is not done'

case "$KIND" in
  scout)
    # Scouts have no remote head. Their preserved report is delivery evidence.
    REPORT=$(printf '%s\n' "$LINE" | sed -n 's/.*report=\([^] ) ]*\).*/\1/p')
    case "$REPORT" in data/*) ;; *) refuse 'scout completion has no report path' ;; esac
    case "$REPORT" in *..*) refuse 'scout report path escapes the home' ;; esac
    [ -f "$FM_HOME/$REPORT" ] && [ ! -L "$FM_HOME/$REPORT" ] || refuse 'scout report is absent'
    ;;
  ship)
    case "$MODE" in
      no-mistakes)
        # A pre-validation done: line is a handoff, not the final result.
        CURRENT=$(FM_CREW_STATE_NO_FORGE=1 FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
          "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null) || refuse 'current pipeline state is unavailable'
        case "$CURRENT" in 'state: done · source: run-step · '*) ;; *) refuse 'pipeline or CI is not confirmed complete' ;; esac
        ;;
      direct-PR|local-only)
        WT=$(value worktree)
        PROJECT=$(value project)
        [ -n "$WT" ] && [ -d "$WT" ] || refuse 'ship worktree is unavailable'
        fm_dod_accept_ship_done "$KIND" "$MODE" "$WT" "$PROJECT" "$LINE" "$STATE" "$ID" "$META" >/dev/null \
          || refuse 'ship delivery cannot be verified outside its worktree'
        ;;
      *) refuse 'ship delivery mode is unknown' ;;
    esac
    ;;
  *) refuse 'only completed ship or scout workers may settle' ;;
esac

fm_wake_signal_reported_current "$STATE" "$STATUS" || refuse 'status changed before settlement'
[ "$(fm_sup_task_signature "$STATE" "$ID")" = "$BEFORE" ] || refuse 'task generation changed before settlement'
fm_sup_task_has_unhandled_event "$STATE" "$ID" && refuse 'a new task wake or instruction arrived'
DIR="$STATE/.supervision-settled"
[ ! -L "$DIR" ] || refuse 'receipt directory is a symbolic link'
mkdir -p "$DIR" || refuse 'could not create receipt directory'
[ -d "$DIR" ] && [ ! -L "$DIR" ] || refuse 'receipt directory is unsafe'
TMP=$(umask 077; mktemp "$DIR/.$ID.XXXXXX") || refuse 'could not create receipt'
if ! printf '%s\n' "$BEFORE" > "$TMP" || ! mv -f "$TMP" "$DIR/$ID"; then
  rm -f "$TMP"
  refuse 'could not persist receipt'
fi
if ! fm_sup_task_settled "$STATE" "$ID"; then
  rm -f "$DIR/$ID"
  refuse 'task resumed or current activity could not be verified'
fi
printf 'fm-supervision-settle: settled %s\n' "$ID"
