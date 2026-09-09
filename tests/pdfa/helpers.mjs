import { readFile } from "node:fs/promises";
import { WasmBridge } from "../../bindings/js/dist/wasm.js";

export async function createBridge(fonts = []) {
  const bytes = await readFile(new URL("../../bindings/js/dist/libhtml2realpdf.wasm", import.meta.url));
  return WasmBridge.create(`data:application/wasm;base64,${bytes.toString("base64")}`, fonts);
}

/** The native HTML boundary accepts validated SVG resources rather than DOM nodes. */
export function materializeFixtureSvg(html) {
  return html.replace(/<svg\b[\s\S]*?<\/svg>/g, (svg) => `<img style="width:100%;height:160px" src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}">`);
}
