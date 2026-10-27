// Deterministic local provider: real native codemode/QuickJS and nested bash,
// no network model request or credentials. Loaded only by the isolated TUI test.
import {
  createFauxCore,
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "calm-native-api",
    provider: "calm-native",
    models: [{
      id: "fixture",
      name: "Local Calm fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 512,
    }],
    tokenSize: { min: 8, max: 8 },
  });
  faux.setResponses([
    fauxAssistantMessage([
      fauxToolCall("codemode", {
        code: 'const result = await tools.bash({command:"sleep 2; printf NATIVE_NESTED_OUTPUT"});\ntext(result);\nthrow new Error("NATIVE_CODEMODE_ERROR");',
      }, { id: "native-calm-call" }),
    ], { stopReason: "toolUse" }),
    fauxAssistantMessage([fauxText("NATIVE_CALM_FINAL\nThe local tool result remains in the session.")]),
  ]);
  pi.registerProvider("calm-native", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerCommand("native-calm-example", {
    description: "Run the local native-tool rendering fixture.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-native", "fixture");
      if (!model || !(await pi.setModel(model))) throw new Error("Local fixture model missing");
      await pi.sendUserMessage("NATIVE_CALM_PROMPT");
    },
  });
}
