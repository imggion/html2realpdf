/// <reference lib="webworker" />

/**
 * Module Worker protocol that owns a `WasmBridge` off the browser main thread.
 *
 * @packageDocumentation
 */

import { WasmBridge } from "./wasm.js";
import type { NormalizedPage } from "./page.js";
import type { CssProfile, FontRegistration, PdfMetadata } from "./types.js";
import type { SnapshotPageMarginBox, SnapshotPageRule } from "./snapshot.js";

/** Creates the single renderer context owned by this Worker. */
interface InitMessage {
  type: "init";
  wasmUrl: string;
  fonts: readonly FontRegistration[];
}

/** Requests one render and correlates its transferable result by `id`. */
interface RenderMessage {
  type: "render";
  id: number;
  html: string;
  page: NormalizedPage;
  metadata?: PdfMetadata;
  cssProfile?: CssProfile;
  marginBoxes?: readonly SnapshotPageMarginBox[];
  pageRules?: readonly SnapshotPageRule[];
}

const scope = self as unknown as DedicatedWorkerGlobalScope;
let bridgePromise: Promise<WasmBridge> | undefined;

// Initialization and renders share the same promise so early render requests
// wait for font registration instead of racing the native context.
scope.addEventListener("message", (event: MessageEvent<InitMessage | RenderMessage>) => {
  const message = event.data;
  if (message.type === "init") {
    bridgePromise = WasmBridge.create(message.wasmUrl, message.fonts);
    bridgePromise.then(
      () => scope.postMessage({ type: "ready" }),
      (error: unknown) => scope.postMessage({ type: "init-error", error: errorMessage(error) }),
    );
    return;
  }

  if (!bridgePromise) {
    scope.postMessage({ type: "render-error", id: message.id, error: "Worker is not initialized" });
    return;
  }

  bridgePromise.then((bridge) => bridge.render(message.html, message.page, message.metadata, message.cssProfile, message.marginBoxes, message.pageRules)).then(
    (result) => {
      scope.postMessage(
        { type: "render-result", id: message.id, bytes: result.bytes, pageCount: result.pageCount, diagnostics: result.diagnostics },
        [result.bytes.buffer],
      );
    },
    (error: unknown) => scope.postMessage({ type: "render-error", id: message.id, error: errorMessage(error) }),
  );
});

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
