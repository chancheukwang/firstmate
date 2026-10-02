#!/usr/bin/env bash
# Public Pi extension events in an isolated primary home, with a stub catalog.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-main-routing)
REPO="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$REPO/.pi/extensions/lib" "$REPO/bin" "$HOME_DIR/state" "$HOME_DIR/config"
git -C "$REPO" init -q
cp "$ROOT/AGENTS.md" "$REPO/AGENTS.md"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$REPO/bin/"
cp "$ROOT/bin/fm-operational-input.sh" "$REPO/bin/"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$REPO/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$REPO/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-main-provider-cooldown.ts" "$REPO/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$REPO/.pi/extensions/lib/"
printf '#!/usr/bin/env bash\nexit 3\n' > "$REPO/bin/fm-sessionstart-run.sh"
chmod +x "$REPO/bin/fm-sessionstart-run.sh"
printf '#!/usr/bin/env bash\nprintf "supervision is off\\n" >&2\nexit 2\n' > "$REPO/bin/fm-turnend-guard.sh"
chmod +x "$REPO/bin/fm-turnend-guard.sh"
printf 'openai-codex/gpt-6-sol\nhigh\n' > "$HOME_DIR/config/pi-main-model"
export NODE_NO_WARNINGS=1

run_case() {
  local name=$1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$REPO" FM_MAIN_CASE="$name" \
    FM_MAIN_EXT="$REPO/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_COOLDOWN_EXT="$ROOT/.pi/extensions/lib/fm-main-provider-cooldown.ts" \
    node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { providerFailureCooldown, readProviderCooldown } = await import(pathToFileURL(process.env.FM_COOLDOWN_EXT).href);

const testCase = process.env.FM_MAIN_CASE;
assert.equal(providerFailureCooldown("usage limit resets in 5,185 minutes", null, 0)?.until, 5_185 * 60_000);
process.argv.push("fixture-script");
if (testCase === "operator") process.argv.push("--model", "splash/local");
if (testCase === "resume") process.argv.push("--continue");
if (testCase === "worker") process.env.FM_TASK_ID = "isolated-worker";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const { default: extension } = await import(pathToFileURL(process.env.FM_MAIN_EXT).href);
const handlers = new Map();
const selected = [];
const effort = [];
const notices = [];
const followups = [];
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  events: { emit() {} },
  async setModel(model) { selected.push(`${model.provider}/${model.id}`); ctx.model = model; return true; },
  setThinkingLevel(level) { effort.push(level); },
  async sendUserMessage(content) { followups.push(content); },
};
extension(pi);
const ctx = {
  model: { provider: "splash", id: "local" },
  modelRegistry: { find(provider, id) {
    if (testCase === "unavailable") return undefined;
    return { provider, id };
  } },
  sessionManager: { getSessionId() { return "isolated"; }, getHeader() { return { timestamp: "2020-01-01T00:00:00Z" }; } },
  ui: { notify(message) { notices.push(message); } },
};
await handlers.get("session_start")({ reason: "startup" }, ctx);
if (testCase === "default") {
  assert.deepEqual(selected, ["openai-codex/gpt-6-sol"]);
  assert.deepEqual(effort, ["high"]);
  await handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason: "error", errorMessage: "usage limit resets at 2099-01-01T00:00:00Z" }] }, ctx);
  const record = JSON.parse(readFileSync(`${process.env.FM_HOME}/state/.pi-main-provider-cooldown`, "utf8"))["openai-codex/gpt-6-sol"];
  assert.equal(record.reason, "quota");
  assert.ok(record.until >= Date.parse("2099-01-01T00:00:00Z"));
  assert.equal(readProviderCooldown(`${process.env.FM_HOME}/state/.pi-main-provider-cooldown`, { provider: "splash", id: "local" }), null);
  assert.equal(notices.length, 1);
  await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
  assert.equal(followups.length, 0, "turn-end guard bypassed the automatic provider cooldown");
  await handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason: "aborted" }] }, ctx);
  assert.ok(readProviderCooldown(`${process.env.FM_HOME}/state/.pi-main-provider-cooldown`, ctx.model),
    "cancelling a turn cleared an outage without a successful provider response");
  await handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason: "stop" }] }, ctx);
  assert.equal(JSON.parse(readFileSync(`${process.env.FM_HOME}/state/.pi-main-provider-cooldown`, "utf8"))["openai-codex/gpt-6-sol"], undefined);
  await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
  assert.equal(followups.length, 1, "healthy recovery did not restore the turn-end supervision guard");
} else if (testCase === "unavailable") {
  throw new Error("unavailable pin reached the model request path");
} else {
  assert.deepEqual(selected, []);
  assert.deepEqual(effort, []);
}
console.log(`ok - ${testCase}`);
JS
}

run_case default || fail "home pin and provider cooldown did not bind the Pi main runtime"
unavailable_out=$(run_case unavailable 2>&1) && fail "an unavailable pin did not stop Pi before a model request"
assert_contains "$unavailable_out" "absent from Pi's model catalog" \
  "an unavailable pin stopped Pi without an actionable diagnostic"
run_case operator || fail "an explicit operator model did not override the home pin"
run_case resume || fail "a restored Pi session lost its operator model choice"
run_case worker || fail "the home pin reached a task worker"
rm "$REPO/AGENTS.md"
run_case nonprimary || fail "the home pin reached Pi outside a Firstmate primary"
