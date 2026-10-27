#!/bin/bash
# usage: run.sh <label> <src-dir> <regular|fullscreen> <on|off>
set -u
LABEL=$1; SRC=$2; MODE=$3; START=$4
EV=/Users/cheukwangchan/.no-mistakes/evidence/01M5Y39B2SJW77T1FHDVNRNF5P
WT=/Users/cheukwangchan/.no-mistakes/worktrees/0ff1b1154e2f/01M5Y39B2SJW77T1FHDVNRNF5P
F=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$F/project/.pi/extensions/lib" "$F/agent" "$F/home/config"
cp "$SRC/fm-calm.ts" "$F/project/.pi/extensions/"; cp "$SRC"/lib/*.ts "$F/project/.pi/extensions/lib/"
cp "$WT/tests/assets/fm-calm-codemode-provider.ts" "$F/project/provider.ts"
echo "$START" > "$F/home/config/calm"
printf '{"tuiMode":"%s","hideThinkingBlock":true}\n' "$MODE" > "$F/agent/settings.json"
OUT=$EV/$LABEL; rm -rf "$OUT"; mkdir -p "$OUT"
SCRIPT=$(python3 -I -c '
import json,sys; lab=sys.argv[1]
s=[["start"],["wait","provider.ts",60],["sleep",1],["cap","0-startup"],["type","/native-calm-example"],["wait","NATIVE_CALM_PROMPT"],["sleep",0.8],["cap","1-streaming"],
["wait","NATIVE_CALM_FINAL"],["sleep",0.8],["cap","2-settled"],["type","/calm"],["sleep",1.2],["cap","3-calm-toggled"],
["key","\x0f"],["sleep",1.2],["cap","4-toggled-ctrl-o"],["key","\x0f"],["sleep",0.5],["type","/calm"],["sleep",1.2],["cap","5-toggled-back"],
["type","/export "+lab+"/export.html"],["sleep",3],["cap","6-after-export"],["type","/quit"],["stop"],
["start"],["wait","NATIVE_CALM_FINAL",60],["sleep",1.5],["cap","7-restored"],["type","/quit"],["stop"]]
print(json.dumps(s))' "$F")
"$TMPDIR/fmlab-venv/bin/python" -I "$EV/driver/ptydrive.py" "$OUT" "$F" "$SCRIPT"
echo "calm pref at end: $(cat $F/home/config/calm)" > "$OUT/calm-pref.txt"
[ -f "$F/export.html" ] && cp "$F/export.html" "$OUT/export.html"
cp "$F/s.jsonl" "$OUT/session.jsonl" 2>/dev/null
rm -rf "$F"
