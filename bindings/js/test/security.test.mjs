import assert from "node:assert/strict";
import test from "node:test";
import { deflateSync } from "node:zlib";
import { createBridge } from "../../../tests/pdfa/helpers.mjs";
import { normalizePage } from "../dist/page.js";
import { WASM_TRAP_STATUS, WasmBridge } from "../dist/wasm.js";

function png(width, height, pixels, colorType = 6) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    const result = Buffer.alloc(data.length + 12);
    result.writeUInt32BE(data.length);
    body.copy(result, 4);
    result.writeUInt32BE((crc ^ 0xffffffff) >>> 0, result.length - 4);
    return result;
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = colorType;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header), chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0)),
  ]).toString("base64");
}

test("input limits return ordinary errors and preserve the WASM renderer", async () => {
  const bridge = await createBridge();
  const page = normalizePage();
  const variables = ["--x0:1px", ...Array.from({ length: 18 }, (_, i) => `--x${i + 1}:var(--x${i}) var(--x${i})`)];
  const image = (data) => `<img width="1" height="1" src="data:image/png;base64,${data}">`;
  const rejected = [
    ["<div>".repeat(250) + "x" + "</div>".repeat(250), /DocumentTooDeep/],
    [`<div style="${variables.join(";")};width:var(--x18)">x</div>`, /CssExpansionLimitExceeded/],
    [image(png(1, 1, Buffer.alloc(8 * 1024 * 1024))), /InvalidPng/],
    [image(png(4097, 4096, Buffer.alloc(5))), /ImageTooLarge/],
    [image(png(0xffffffff, 0xffffffff, Buffer.alloc(4), 2)), /ImageTooLarge/],
  ];
  try {
    for (const profile of ["document", "web"]) {
      for (const [html, expected] of rejected) {
        const before = bridge.exports.memory.buffer.byteLength;
        assert.throws(() => bridge.render(html, page, undefined, profile), expected);
        assert.ok(bridge.exports.memory.buffer.byteLength - before < 16 * 1024 * 1024, "Rejection must precede large memory growth");
        assert.equal(bridge.render("<p>Still usable</p>", page, undefined, profile).pageCount, 1);
      }
      const atLimit = "<div>".repeat(64) + "x" + "</div>".repeat(64);
      assert.equal(bridge.render(atLimit, page, undefined, profile).pageCount, 1);
      assert.equal(bridge.render("<span>x</span>".repeat(250), page, undefined, profile).pageCount, 1);
    }
  } finally { bridge.dispose(); }
});

for (const operation of ["alloc", "render_html_to_pdf_with_context_json_options", "pdf_result_free", "free"]) {
  test(`a trap during ${operation} discards WASM without calling it again`, async () => {
    const bridge = await createBridge();
    const original = bridge.exports;
    const trap = new WebAssembly.RuntimeError("isolated test trap");
    let trapped = false;
    let callsAfterTrap = 0;
    bridge.exports = Object.fromEntries(Object.entries(original).map(([name, value]) => [name, typeof value === "function" ? (...args) => {
      if (trapped) callsAfterTrap++;
      if (name === operation) {
        trapped = true;
        throw trap;
      }
      return value(...args);
    } : value]));
    assert.throws(() => bridge.render("<p>Test</p>", normalizePage()), (error) => {
      assert.equal(error.status, WASM_TRAP_STATUS);
      assert.equal(error.cause, trap);
      return true;
    });
    assert.throws(() => bridge.render("<p>Again</p>", normalizePage()), /disposed/);
    bridge.dispose();
    assert.equal(callsAfterTrap, 0, "Even cleanup must not re-enter a trapped instance");
  });
}

test("font initialization traps also discard the instance without cleanup calls", async () => {
  const instantiate = WebAssembly.instantiateStreaming;
  try {
    for (const operation of ["alloc", "pdf_context_register_font", "free"]) {
      let trapped = false;
      let callsAfterTrap = 0;
      const exports = {
        html2realpdf_abi_version: () => 2, pdf_context_create: () => 1,
        alloc: () => 16, free() {}, pdf_context_free() {}, pdf_context_register_font: () => 0,
        memory: new WebAssembly.Memory({ initial: 1 }),
      };
      for (const [name, value] of Object.entries(exports)) {
        if (typeof value !== "function") continue;
        exports[name] = (...args) => {
          if (trapped) callsAfterTrap++;
          if (name === operation) {
            trapped = true;
            throw new WebAssembly.RuntimeError("isolated font trap");
          }
          return value(...args);
        };
      }
      WebAssembly.instantiateStreaming = async () => ({ instance: { exports } });
      await assert.rejects(WasmBridge.create("data:application/wasm;base64,AA==", [{ family: "Test", data: new Uint8Array([1]) }]),
        (error) => error.status === WASM_TRAP_STATUS);
      assert.equal(callsAfterTrap, 0);
    }
  } finally { WebAssembly.instantiateStreaming = instantiate; }
});
