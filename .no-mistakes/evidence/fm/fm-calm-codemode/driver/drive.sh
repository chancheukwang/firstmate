#!/bin/bash
# usage: drive.sh <label> <ext-src-dir(with fm-calm.ts + lib/)> <mode regular|fullscreen> <calm-start on|off>
set -u
LABEL=$1; SRC=$2; MODE=$3; START=$4
EV=/Users/cheukwangchan/.no-mistakes/evidence/01M5Y39B2SJW77T1FHDVNRNF5P
WT=/Users/cheukwangchan/.no-mistakes/worktrees/0ff1b1154e2f/01M5Y39B2SJW77T1FHDVNRNF5P
PI="$HOME/.config/ai-proxy-uk/active/cli-us/claude-tools/pi"
SOCK=fm-lab; S=main
F=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$F/tmux"; export TMUX_TMPDIR="$F/tmux"; unset TMUX
mkdir -p "$F/project/.pi/extensions/lib" "$F/agent" "$F/home/config"
cp "$SRC/fm-calm.ts" "$F/project/.pi/extensions/"; cp "$SRC"/lib/*.ts "$F/project/.pi/extensions/lib/"
cp "$WT/tests/assets/fm-calm-codemode-provider.ts" "$F/project/provider.ts"
echo "$START" > "$F/home/config/calm"
printf '{"tuiMode":"%s","hideThinkingBlock":true}\n' "$MODE" > "$F/agent/settings.json"
OUT=$EV/$LABEL; mkdir -p "$OUT"
CMD="cd '$F/project' && env FM_HOME='$F/home' PI_CODING_AGENT_DIR='$F/agent' PI_OFFLINE=1 '$PI' --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e ./.pi/extensions/fm-calm.ts -e ./provider.ts -e builtin:codemode --tools read,bash,codemode --session '$F/s.jsonl'; echo PI_EXIT=\$?; sleep 30"
cap(){ tmux -L $SOCK capture-pane -p -t $S -S -600 > "$OUT/$1.txt"; tmux -L $SOCK capture-pane -e -p -t $S -S -600 > "$OUT/$1.ansi"; }
waitfor(){ for i in $(seq 1 200); do tmux -L $SOCK capture-pane -p -t $S -S -600 | grep -Fq "$1" 2>/dev/null && return 0; sleep 0.1; done; echo "TIMEOUT waiting for $1"; return 1; }
keys(){ tmux -L $SOCK send-keys -t $S -l "$1"; tmux -L $SOCK send-keys -t $S Enter; }
start(){ tmux -L $SOCK new-session -d -s $S -x 110 -y 50 "$CMD"; waitfor provider.ts; }
start
keys /native-calm-example
waitfor NATIVE_CALM_PROMPT; sleep 0.8; cap 1-streaming
waitfor NATIVE_CALM_FINAL; sleep 0.5; cap 2-settled
keys /calm; sleep 1; cap 3-after-first-toggle
keys /calm; sleep 1; cap 4-after-second-toggle
tmux -L $SOCK send-keys -t $S C-o; sleep 1; cap 5-ctrl-o
tmux -L $SOCK send-keys -t $S C-o; sleep 0.5
echo "calm file now: $(cat $F/home/config/calm)" > "$OUT/calm-state.txt"
keys "/export $F/export.html"; sleep 2; cap 6-after-export
[ -f "$F/export.html" ] && cp "$F/export.html" "$OUT/export.html"
keys /quit; waitfor PI_EXIT=; cap 7-exit
tmux -L $SOCK kill-session -t $S
start; waitfor NATIVE_CALM_FINAL; sleep 0.8; cap 8-restored
keys /quit; waitfor PI_EXIT=
tmux -L $SOCK kill-server
cp "$F/s.jsonl" "$OUT/session.jsonl"
rm -rf "$F"
echo done "$OUT"
