// Token-free installed-Pi loader/component regression, invoked by the Calm suite.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const root = process.env.PI_PACKAGE_DIR;
const installed = (path) => import(pathToFileURL(`${root}/${path}`).href);
const { loadExtensions } = await installed("dist/core/extensions/loader.js");
const { ExtensionRunner } = await installed("dist/core/extensions/runner.js");
const { ToolExecutionComponent } = await installed("dist/modes/interactive/components/tool-execution.js");
const { initTheme, theme } = await installed("dist/modes/interactive/theme/theme.js");
const { createToolHtmlRenderer } = await installed("dist/core/export-html/tool-renderer.js");
const { createCodemodeToolDefinition } = await installed("dist/extensions/codemode/tool.js");
const { AgentSession } = await installed("dist/core/agent-session.js");
const { SessionManager } = await installed("dist/core/session-manager.js");
const { exportSessionForShare } = await installed("dist/modes/interactive/session-share.js");
const version = JSON.parse(readFileSync(`${root}/package.json`)).version;
initTheme("dark");

const args = { code: 'const result = await tools.bash({command:"echo NESTED"});\ntext(result);' };
const result = {
  content: [{ type: "text", text: "Script failed\nWall time 0.1 seconds\nOutput:\n" },
    { type: "text", text: "RESULT_MARKER\nScript error: ERROR_MARKER\n" + "more output\n".repeat(12) }],
  details: { calls: [
    { name: "bash", args: '{"command":"echo NESTED"}', status: "ok", durationMs: 12 },
    { name: "read", args: '{"path":"missing"}', status: "error", error: "NESTED_ERROR", durationMs: 3 },
  ] },
  isError: true,
};
const originalData = JSON.stringify({ args, result });
const stock = createCodemodeToolDefinition({ models: false });
const originalDefinition = { ...stock };
const snapshots = [];
const strip = (lines) => lines.join("\n").replace(/\x1b\[[\d;]*m/g, "");
const rowUi = { requestRender() {} };
const stockRow = new ToolExecutionComponent("codemode", "stock", args, {}, stock, rowUi, process.cwd());
stockRow.updateResult(result);
stockRow.setExpanded(true);
const stockText = strip(stockRow.render(100));
for (const marker of ["codemode", "tools.bash", "bash", "RESULT_MARKER", "ERROR_MARKER", "NESTED_ERROR"])
  assert.ok(stockText.includes(marker), `non-vacuous installed renderer baseline lacks ${marker}`);
snapshots.push(`STOCK EXPANDED\n${stockText}`);

for (const initiallyOn of [true, false]) {
  writeFileSync(`${process.env.FM_HOME}/config/calm`, initiallyOn ? "on\n" : "off\n");
  const loaded = await loadExtensions([process.env.EXT], process.cwd());
  assert.deepEqual(loaded.errors, [], `Pi ${version} loader errors`);
  const [extension] = loaded.extensions;
  assert.equal(loaded.extensions.length, 1);
  assert.equal(extension.tools.has("codemode"), false, "Calm must not register codemode execution");
  assert.equal(extension.commands.size, 1, "one /calm owner");
  const rows = [];
  let expanded = true;
  let terminalInput;
  const ui = {
    ...rowUi,
    getEditorText: () => "/export fixture.html",
    getToolsExpanded: () => expanded,
    setToolsExpanded(value) { expanded = value; for (const row of rows) row.setExpanded(value); },
    setHiddenThinkingLabel() {}, setStatus() {}, setWorkingVisible() {}, setWidget() {},
    onTerminalInput(handler) { terminalInput = handler; return () => {}; },
    notify(message) { throw new Error(message); },
  };
  loaded.runtime.getAllTools = () => [...extension.tools.values()].map(({ definition, sourceInfo }) => ({ name: definition.name, sourceInfo }));
  const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, process.cwd(), {}, {});
  const resolve = (name) => runner.resolveToolRenderers(name, () => name === "codemode" ? stock : undefined);
  assert.equal(resolve("unrelated"), undefined, "unrelated renderers pass through");
  const renderers = resolve("codemode");
  const makeRow = (id) => {
    const row = new ToolExecutionComponent("codemode", id, args, {}, renderers, ui, process.cwd());
    row.setExpanded(expanded);
    rows.push(row);
    return row;
  };
  // Restored rows capture their renderer before session_start, including an off start.
  const restored = makeRow(`restored-${initiallyOn}`);
  restored.updateResult(result);
  const capturedBeforeSessionStart = restored.render(100);
  if (initiallyOn) {
    snapshots.push(`CALM ON BEFORE SESSION_START\n${strip(capturedBeforeSessionStart)}`);
    assert.deepEqual(capturedBeforeSessionStart, [], `Pi ${version}: restored Calm codemode outer/source/nested/error chrome is visible`);
  } else {
    assert.equal(strip(capturedBeforeSessionStart), stockText);
  }
  for (const handler of extension.handlers.get("session_start") ?? []) await handler({ reason: "startup" }, { ui });
  const toggle = () => extension.commands.get("calm").handler("", { ui });
  if (!initiallyOn) await toggle();
  for (const row of rows) assert.deepEqual(row.render(100), [], "off-start captured rows hide on first activation");
  const streaming = makeRow(`stream-${initiallyOn}`);
  streaming.updateArgs({ code: "const partial =" });
  streaming.markExecutionStarted();
  streaming.setArgsComplete();
  streaming.updateResult({ ...result, details: { calls: [{ name: "bash", args: "{}", status: "running" }] } }, true);
  for (const width of [20, 100]) {
    for (const value of [false, true]) {
      streaming.setExpanded(value);
      assert.deepEqual(streaming.render(width), [], "streaming rows including nested running calls have zero height");
      streaming.invalidate();
      assert.deepEqual(streaming.render(width), [], "invalidation keeps rows hidden");
    }
  }
  streaming.updateArgs(args);
  streaming.updateResult(result);
  await toggle();
  assert.equal(expanded, true, "toggle preserves expansion setting");
  assert.equal(strip(restored.render(100)), stockText, "off restores complete native result and error");
  snapshots.push(`CALM OFF RESTORED\n${strip(restored.render(100))}`);
  for (const value of [false, true]) {
    restored.setExpanded(value);
    stockRow.setExpanded(value);
    assert.deepEqual(restored.render(100), stockRow.render(100), "stock rendering parity at both expansion levels");
  }
  await toggle();
  // /export and /share both use the same temporary stock-rendering window.
  const html = () => createToolHtmlRenderer({ getToolRenderers: resolve, theme, cwd: process.cwd() });
  const nativeHtml = createToolHtmlRenderer({ getToolRenderers: () => stock, theme, cwd: process.cwd() });
  const nativeCall = nativeHtml.renderCall("export", "codemode", args);
  const nativeResult = nativeHtml.renderResult("export", "codemode", result.content, result.details, true);
  terminalInput("\r");
  const exported = html();
  assert.equal(exported.renderCall("export", "codemode", args), nativeCall, "export call remains stock");
  assert.deepEqual(exported.renderResult("export", "codemode", result.content, result.details, true), nativeResult, "export collapsed/expanded result remains stock");
  // Simulate an on-screen update in the export window; the scheduled repaint must hide it again.
  restored.updateResult(result);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(restored.render(100), [], "export returns screen to zero height");
  // Direct SDK exports and delayed /share fallback have no active input window.
  // Exercise Pi's actual public export method, then decode the emitted artifact.
  const sm = SessionManager.create(process.cwd(), `${process.env.FM_HOME}/sessions`);
  sm.appendMessage({ role: "assistant", content: [{ type: "toolCall", id: "export", name: "codemode", arguments: args }], stopReason: "toolUse", timestamp: 1 });
  sm.appendMessage({ ...result, role: "toolResult", toolCallId: "export", toolName: "codemode", timestamp: 2 });
  let concurrentRow;
  const receiver = {
    sessionManager: sm, state: { systemPrompt: "test", tools: [stock] },
    settingsManager: { getTheme: () => "dark" }, _extensionRunner: runner,
    getToolDefinition: () => {
      if (!concurrentRow) {
        concurrentRow = makeRow("first-drawn-during-export");
        concurrentRow.updateResult(result);
      }
      return stock;
    },
  };
  const exportPath = `${process.env.FM_HOME}/direct-${initiallyOn}.html`;
  await AgentSession.prototype.exportToHtml.call(receiver, exportPath);
  const artifact = readFileSync(exportPath, "utf8");
  const payload = JSON.parse(Buffer.from(artifact.match(/<script id="session-data"[^>]*>([^<]+)<\/script>/)[1], "base64"));
  assert.equal(payload.renderedTools.export.callHtml, nativeCall);
  assert.equal(payload.renderedTools.export.resultHtmlExpanded, nativeResult.expanded);
  assert.deepEqual(restored.render(100), [], "direct export restores hidden screen");
  assert.deepEqual(concurrentRow.render(100), [], "a live row first drawn during export also hides afterward");
  await assert.rejects(AgentSession.prototype.exportToHtml.call(receiver, `${process.env.FM_HOME}/absent/file.html`));
  assert.deepEqual(restored.render(100), [], "failed export also restores hidden screen");
  const executed = await stock.execute("native-execute", { code: 'text("EXECUTE_MARKER")' });
  assert.ok(executed.content.some((block) => block.text === "EXECUTE_MARKER"), "native sandbox execution still runs under Calm");
  streaming.updateResult(executed);
  assert.deepEqual(streaming.render(100), [], "successful native execution also stays hidden");
  streaming.updateArgs({ code: null });
  assert.deepEqual(streaming.render(100), [], "invalid native call chrome stays hidden");
  const sharePath = `${process.env.FM_HOME}/share-${initiallyOn}.jsonl`;
  exportSessionForShare(sharePath, receiver);
  const sharedMessages = readFileSync(sharePath, "utf8").trim().split("\n").map(JSON.parse).filter((entry) => entry.type === "message");
  assert.deepEqual(sharedMessages.map((entry) => entry.message), sm.getEntries().filter((entry) => entry.type === "message").map((entry) => entry.message), "share serialization preserves original messages");
  assert.equal(JSON.stringify({ args, result }), originalData, "session/tool payloads unchanged");
  assert.deepEqual(stock, originalDefinition, "tool metadata, schemas, execution and renderer identities unchanged");
}

// Preserve another extension's next-renderer chain and its lastComponent identity.
const loaded = await loadExtensions([process.env.EXT], process.cwd());
assert.deepEqual(loaded.errors, []);
const extension = loaded.extensions[0];
const { Text } = await installed("node_modules/@earendil-works/pi-tui/dist/index.js");
const seen = [];
const downstream = {
  renderShell: "self",
  renderCall(_args, _theme, context) {
    seen.push(context.lastComponent);
    return context.lastComponent ?? new Text("DOWNSTREAM_CALL", 0, 0);
  },
  renderResult() { return new Text("DOWNSTREAM_RESULT", 0, 0); },
};
const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, process.cwd(), {}, {});
const chained = runner.resolveToolRenderers("codemode", () => downstream);
assert.notEqual(chained, downstream, "Calm should wrap rather than drop the downstream renderer");
assert.equal(runner.resolveToolRenderers("other", () => downstream), downstream);
// Use the same visibility module instance as the installed loader's extension.
const ui = {
  getToolsExpanded: () => false, setToolsExpanded() {}, setHiddenThinkingLabel() {},
  setStatus() {}, setWorkingVisible() {}, setWidget() {}, notify() {},
};
const row = new ToolExecutionComponent("codemode", "chain", args, {}, chained, rowUi, process.cwd());
assert.deepEqual(row.render(100), []);
await extension.commands.get("calm").handler("", { ui });
row.invalidate();
assert.ok(strip(row.render(100)).includes("DOWNSTREAM_CALL"));
const downstreamComponent = row.callRendererComponent;
row.invalidate();
assert.equal(seen.at(-1), downstreamComponent, "downstream component reused");
writeFileSync(`${process.env.FM_HOME}/rendered-rows.txt`, snapshots.join("\n\n"));
console.log(`ok - Pi ${version}: codemode on/off, pre-session restored, streaming, nested/error, expansion, renderer-chain, export and data/definition parity`);
