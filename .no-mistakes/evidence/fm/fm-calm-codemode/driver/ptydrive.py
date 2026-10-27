"""Drive real Pi in a 110x50 pty, render with pyte, capture text+HTML snapshots.
usage: ptydrive.py <outdir> <labdir> <script-json>
script: list of ["start"] | ["type", text] | ["key", raw] | ["wait", text, timeout] | ["waitgone"...] | ["sleep", s] | ["cap", name] | ["stop"]
"""
import os, sys, json, time, pty, fcntl, termios, struct, subprocess, threading, html, pyte
out, lab, script = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
os.makedirs(out, exist_ok=True)
PI = os.path.expanduser("~/.config/ai-proxy-uk/active/cli-us/claude-tools/pi")
COLS, ROWS = 110, 50
state = {}
log = open(os.path.join(out, "driver.log"), "a")
def L(*a): print(time.strftime("%H:%M:%S"), *a, file=log, flush=True)

def start():
    m, s = os.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    env = dict(os.environ, FM_HOME=f"{lab}/home", PI_CODING_AGENT_DIR=f"{lab}/agent", PI_OFFLINE="1", TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS))
    for k in ["NO_MISTAKES_GATE","FM_GATE_REFUSE_BYPASS","FM_ROOT_OVERRIDE","FM_STATE_OVERRIDE","FM_DATA_OVERRIDE","FM_CONFIG_OVERRIDE","FM_PROJECTS_OVERRIDE","TMUX"]: env.pop(k, None)
    def pre():
        os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    p = subprocess.Popen([PI, "--approve", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-extensions",
        "-e", "./.pi/extensions/fm-calm.ts", "-e", "./provider.ts", "-e", "builtin:codemode", "--tools", "read,bash,codemode",
        "--session", f"{lab}/s.jsonl"], cwd=f"{lab}/project", env=env, stdin=s, stdout=s, stderr=s, preexec_fn=pre, close_fds=True)
    os.close(s)
    screen = pyte.HistoryScreen(COLS, ROWS, history=2000); stream = pyte.ByteStream(screen)
    raw = open(os.path.join(out, f"raw-{len([k for k in state if k=='p'])}{int(time.time())}.bin"), "ab")
    lock = threading.Lock()
    def pump():
        while True:
            try: d = os.read(m, 65536)
            except OSError: break
            if not d: break
            raw.write(d); raw.flush()
            # answer cursor-position / device queries minimally
            with lock: stream.feed(d)
    t = threading.Thread(target=pump, daemon=True); t.start()
    state.update(p=p, m=m, screen=screen, lock=lock, t=t, rawpath=raw.name)

def lines():
    sc = state["screen"]
    with state["lock"]:
        hist = ["".join(c.data for c in (row[x] for x in range(COLS))).rstrip() for row in sc.history.top]
        cur = [l.rstrip() for l in sc.display]
    return hist, cur
def text(): h, c = lines(); return "\n".join(h + c)
def cap(name):
    h, c = lines()
    open(os.path.join(out, name + ".txt"), "w").write("\n".join(h + ["----- visible screen -----"] + c) + "\n")
    sc = state["screen"]; rows = []
    with state["lock"]:
        for y in range(ROWS):
            row = sc.buffer[y]; parts = []
            for x in range(COLS):
                ch = row[x]; fg = ch.fg if ch.fg != "default" else "d0d0d0"; bg = ch.bg if ch.bg != "default" else "1e1e1e"
                if ch.reverse: fg, bg = bg, fg
                def norm(c): return c if len(c)==6 and all(q in "0123456789abcdefABCDEF" for q in c) else {"black":"000000","red":"cd3131","green":"0dbc79","yellow":"e5e510","blue":"2472c8","magenta":"bc3fbc","cyan":"11a8cd","white":"e5e5e5","brightblack":"666666"}.get(c, "d0d0d0" if c==fg else "1e1e1e")
                parts.append(f'<span style="color:#{norm(fg)};background:#{norm(bg)};{"font-weight:bold;" if ch.bold else ""}">{html.escape(ch.data or " ")}</span>')
            rows.append("".join(parts))
    open(os.path.join(out, name + ".html"), "w").write(f'<html><body style="margin:0;background:#1e1e1e"><div style="font:13px/16px Menlo,monospace;white-space:pre;padding:6px">{chr(10).join(rows)}</div><div style="font:12px sans-serif;color:#888;padding:4px">{html.escape(os.path.basename(out))} / {name} (Pi pty 110x50, rendered via pyte)</div></body></html>')
    L("cap", name)
def send(b): os.write(state["m"], b)
def wait(t, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if t in text(): return True
        time.sleep(0.05)
    L("TIMEOUT", t); return False

ok = True
for step in script:
    op = step[0]; L("step", step)
    if op == "start": start()
    elif op == "type":
        for ch in step[1]: send(ch.encode()); time.sleep(0.02)
        time.sleep(0.2); send(b"\r")
    elif op == "key": send(step[1].encode())
    elif op == "wait": ok = wait(step[1], step[2] if len(step) > 2 else 30) and ok
    elif op == "sleep": time.sleep(step[1])
    elif op == "cap": cap(step[1])
    elif op == "stop":
        try: state["p"].wait(timeout=15)
        except subprocess.TimeoutExpired: state["p"].kill(); L("killed")
        L("exit", state["p"].returncode); state["t"].join(2); os.close(state["m"])
print("OK" if ok else "SOME_WAITS_TIMED_OUT")
