# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# A handled completion stays dormant only for the exact task generation that
# was acknowledged. A changed status, turn, metadata, or pending steer wakes it.
fm_sup_task_signature() {  # <state> <task-id>
  local state=$1 id=$2 meta="$1/$2.meta" status="$1/$2.status" turn="$1/$2.turn-ended" sig
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -f "$status" ] && [ ! -L "$status" ] || return 1
  sig="$(cksum < "$meta")|$(cksum < "$status")" || return 1
  if [ -e "$turn" ] || [ -L "$turn" ]; then
    [ -f "$turn" ] && [ ! -L "$turn" ] || return 1
    sig="$sig|$(cksum < "$turn")" || return 1
  else
    sig="$sig|-"
  fi
  printf 'v1|%s\n' "$sig"
}

fm_sup_task_has_unhandled_event() {  # <state> <task-id>
  local state=$1 id=$2 msg window
  for msg in "$state/$id.inbox"/*.msg; do
    [ -e "$msg" ] || [ -L "$msg" ] || continue
    return 0
  done
  window=$(sed -n 's/^window=//p' "$state/$id.meta" 2>/dev/null | tail -1)
  [ -s "$state/.wake-queue" ] || return 1
  awk -F '\t' -v status="$id.status" -v turn="$id.turn-ended" -v window="$window" '
    $3 == "signal" && ($4 == status || $4 == turn) { found=1; exit }
    $3 == "stale" && window != "" && $4 == window { found=1; exit }
    END { exit !found }
  ' "$state/.wake-queue"
}

fm_sup_task_settled() {  # <state> <task-id>
  local state=$1 id=$2 receipt="$1/.supervision-settled/$2" current kind mode home crew_bin crew
  [ -d "$state/.supervision-settled" ] && [ ! -L "$state/.supervision-settled" ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  current=$(fm_sup_task_signature "$state" "$id") || return 1
  [ "$(cat "$receipt" 2>/dev/null)" = "$current" ] || return 1
  fm_sup_task_has_unhandled_event "$state" "$id" && return 1
  if [ "${FM_SUP_CYCLE_CACHE:-0}" = 1 ]; then
    case "${FM_SUP_CYCLE_SETTLED:-}" in
      *$'\n'"$id"$'\t'"$current"$'\n'*) return 0 ;;
    esac
  fi
  kind=$(sed -n 's/^kind=//p' "$state/$id.meta" | tail -1)
  if [ "$kind" = ship ] || { [ "$kind" = scout ] \
    && grep -Eq '^(window|terminal)=.+' "$state/$id.meta"; }; then
    mode=$(sed -n 's/^mode=//p' "$state/$id.meta" | tail -1)
    home=${FM_HOME:-${state%/state}}
    crew_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-crew-state.sh"
    [ -f "$crew_bin" ] || return 1
    crew=$(FM_CREW_STATE_NO_FORGE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$crew_bin" "$id" 2>/dev/null) || return 1
    case "$mode:$crew" in
      no-mistakes:'state: done · source: run-step · '*) ;;
      direct-PR:'state: done · '*|local-only:'state: done · '*) ;;
      direct-PR:'state: unknown · source: none · backend target gone:'*|local-only:'state: unknown · source: none · backend target gone:'*) ;;
      *:'state: done · '*) [ "$kind" = scout ] || return 1 ;;
      *:'state: unknown · source: none · backend target gone:'*) [ "$kind" = scout ] || return 1 ;;
      *) return 1 ;;
    esac
  fi
  if [ "${FM_SUP_CYCLE_CACHE:-0}" = 1 ]; then
    FM_SUP_CYCLE_SETTLED="${FM_SUP_CYCLE_SETTLED:-}"$'\n'"$id"$'\t'"$current"$'\n'
  fi
  return 0
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of task metadata without a matching settled receipt
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or a registered custom check
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_sup_task_settled "$state" "$id" && continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    if [ ! -e "$state/$id.check-trust" ]; then
      # A completed worker's PR poll is still a passive source of new events.
      if [ ! -e "$state/$id.pr-poll" ] || ! fm_sup_task_settled "$state" "$id"; then
        continue
      fi
    fi
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
