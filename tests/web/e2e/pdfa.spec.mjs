import { expect, test } from "@playwright/test";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { validateFiles } from "../../pdfa/verapdf.mjs";

test("PDF/A works on main thread and Worker with copied attachments and compatibility options", async ({ page, browserName }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json").then((r) => r.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const caller = new Uint8Array([99, 0, 255, 42, 88]);
    const outputs = [];
    const element = document.createElement("article");
    element.innerHTML = `<h1>Browser archive</h1><p>office caffè q́</p><p style="direction:rtl">مرحبا</p><svg width="220" height="80" viewBox="0 0 220 80"><rect width="220" height="80" fill="#bbddff"/><text x="12" y="35" font-size="16">SVG archive</text></svg><a href="https://example.com">Link</a>`;
    document.body.append(element);
    const options = { conformance: "pdfa-3u", cssProfile: "web", page: { margin: 20, unit: "pt" }, attachments: [{ name: "dati-è.bin", data: caller.subarray(1, 4) }] };
    try {
      for (const execution of ["main", "worker"]) {
        const renderer = await pkg.createRenderer({ execution });
        try {
          const pdf = await renderer.render({ current: element }, options);
          const bytes = pdf.toUint8Array();
          const task = pdfjs.getDocument({ data: bytes.slice() });
          const doc = await task.promise;
          const embedded = Object.values(await doc.getAttachments())[0];
          const text = (await (await doc.getPage(1)).getTextContent()).items.map((item) => item.str).join(" ");
          await doc.destroy();
          const second = await renderer.render("<p>After attachments</p>");
          const ordinary = new TextDecoder().decode(second.toUint8Array());
          second.dispose();
          let invalidRejected = false;
          try { await renderer.render(element, { ...options, attachments: [...options.attachments, ...options.attachments] }); } catch { invalidRejected = true; }
          outputs.push({ execution, bytes: Array.from(bytes), attachment: Array.from(embedded.content), filename: embedded.filename, text, ordinaryClean: !ordinary.includes("/EmbeddedFile") && !ordinary.includes("pdfaid:"), invalidRejected });
          pdf.dispose();
        } finally { renderer.dispose(); }
      }
      const compat = await pkg.default().set({ conformance: "pdfa-3u", metadata: { title: "Compat archive" }, attachments: options.attachments }).from("<p>Compatibility archive</p>").outputPdf("arraybuffer");
      return { outputs, caller: Array.from(caller), compat: Array.from(new Uint8Array(compat)) };
    } finally { element.remove(); }
  });
  expect(result.caller).toEqual([99, 0, 255, 42, 88]);
  const files = [];
  await mkdir(resolve("../../tmp/pdfa"), { recursive: true });
  for (const output of result.outputs) {
    expect(output.attachment).toEqual([0, 255, 42]);
    expect(output.filename).toBe("dati-è.bin");
    expect(output.text).toContain("office caffè q́");
    expect(output.text).toContain("SVG archive");
    expect(output.ordinaryClean).toBe(true);
    expect(output.invalidRejected).toBe(true);
    const file = resolve(`../../tmp/pdfa/browser-${browserName}-${output.execution}.pdf`);
    await writeFile(file, Buffer.from(output.bytes));
    files.push(file);
  }
  const compat = resolve(`../../tmp/pdfa/browser-${browserName}-compat.pdf`);
  await writeFile(compat, Buffer.from(result.compat));
  files.push(compat);
  // The external gate runs once; every engine still verifies extraction and ownership.
  if (browserName === "chromium") await validateFiles(files, "browser-validation.json");
});
