import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.route("**/*", (route) => {
    const url = new URL(route.request().url());
    return url.hostname === "127.0.0.1" || url.protocol === "data:" || url.protocol === "blob:"
      ? route.continue() : route.abort();
  });
  await page.goto("/tests/web/index.html");
});

test("resolver null denies image and background fetches under both resource policies", async ({ page }) => {
  const requests = [];
  const pixel = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64");
  await page.route("**/security-resource/*", (route) => {
    requests.push(new URL(route.request().url()).pathname);
    return route.fulfill({ contentType: "image/png", body: pixel });
  });
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json").then((response) => response.json());
    const { createRenderer } = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await createRenderer({ execution: "main" });
    const results = [];
    try {
      for (const kind of ["image", "background"]) {
        const source = (name) => kind === "image"
          ? `<p>safe</p><img width="1" height="1" src="/security-resource/${name}.png">`
          : `<p style="background-image:url('/security-resource/${name}.png')">safe</p>`;
        for (const resourcePolicy of ["error", "omit"]) {
          let calls = 0;
          let error = null;
          let diagnostics = [];
          try {
            const pdf = await renderer.render(source(`${kind}-${resourcePolicy}`), {
              cssProfile: "web", resourcePolicy,
              resourceResolver: async () => { calls++; return null; },
            });
            diagnostics = pdf.diagnostics;
            pdf.dispose();
          } catch (caught) { error = caught.name; }
          results.push({ kind, resourcePolicy, calls, error, diagnostics });
        }
        // No resolver retains the documented browser-fetch behavior.
        const pdf = await renderer.render(source(`${kind}-allowed`), { cssProfile: "web" });
        pdf.dispose();
      }
    } finally { renderer.dispose(); }
    return results;
  });
  for (const item of result) {
    expect(item.calls).toBe(1);
    if (item.resourcePolicy === "error") expect(item.error).toBe("ResourceLoadError");
    else {
      expect(item.error).toBeNull();
      expect(item.diagnostics.some((diagnostic) => diagnostic.code === "RESOURCE_OMITTED")).toBe(true);
    }
  }
  expect(requests.sort()).toEqual(["/security-resource/background-allowed.png", "/security-resource/image-allowed.png"]);
});

test("embedded SVG images and backgrounds bypass the resolver but retain SVG validation", async ({ page }) => {
  const results = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json").then((response) => response.json());
    const { createRenderer } = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await createRenderer({ execution: "main" });
    const results = [];
    try {
      for (const kind of ["image", "background"]) {
        let calls = 0;
        const options = { cssProfile: "web", resourceResolver: () => { calls++; return null; } };
        const source = (content) => {
          const url = `data:image/svg+xml;base64,${btoa(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20">${content}</svg>`)}`;
          return kind === "image" ? `<img src="${url}" width="40" height="20">`
            : `<div style="width:40px;height:20px;background-image:url('${url}')"></div>`;
        };
        const pdf = await renderer.render(source('<rect width="40" height="20" fill="#f59e0b"/>'), options);
        const output = new TextDecoder().decode(pdf.toUint8Array());
        const diagnostics = pdf.diagnostics;
        pdf.dispose();
        let unsupportedCode = "";
        try { await renderer.render(source('<foreignObject width="40" height="20">unsupported</foreignObject>'), options); }
        catch (error) { unsupportedCode = error.code; }
        results.push({ kind, calls, diagnostics, hasForm: output.includes("/Subtype /Form"), hasImage: output.includes("/Subtype /Image"), unsupportedCode });
      }
    } finally { renderer.dispose(); }
    return results;
  });
  for (const result of results) {
    expect(result.calls).toBe(0);
    expect(result.diagnostics).toEqual([]);
    expect(result.hasForm).toBe(true);
    expect(result.hasImage).toBe(false);
    expect(result.unsupportedCode).toBe("UNSUPPORTED_CSS");
  }
});

test("deep input is rejected without poisoning main-thread or Worker renderers", async ({ page }) => {
  const results = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json").then((response) => response.json());
    const { createRenderer } = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const results = [];
    for (const execution of ["main", "worker"]) {
      const renderer = await createRenderer({ execution });
      let message = "";
      try {
        try { await renderer.render("<div>".repeat(250) + "x" + "</div>".repeat(250)); }
        catch (error) { message = error.message; }
        const pdf = await renderer.render("<p>After rejected input</p>");
        results.push({ execution, message, pageCount: pdf.pageCount });
        pdf.dispose();
      } finally { renderer.dispose(); }
    }
    return results;
  });
  for (const result of results) {
    expect(result.message).toContain("DocumentTooDeep");
    expect(result.pageCount).toBe(1);
  }
});

test("fatal Worker failure rejects pending renders and replaces the default on the next call", async ({ page }) => {
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json").then((response) => response.json());
    const { renderPdf } = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const RealWorker = window.Worker;
    let created = 0;
    let terminated = 0;
    let attempts = 0;
    class TrappingWorker extends EventTarget {
      constructor(...args) {
        super();
        if (++created > 1) return new RealWorker(...args);
      }
      postMessage(message) {
        if (message.type === "init") queueMicrotask(() => this.dispatchEvent(new MessageEvent("message", { data: { type: "ready" } })));
        if (message.type === "render" && ++attempts === 2) {
          // An aborted/untracked request must still invalidate every pending render.
          queueMicrotask(() => this.dispatchEvent(new MessageEvent("message", {
            data: { type: "render-error", id: 9999, status: -23, error: "isolated test trap" },
          })));
        }
      }
      terminate() { terminated++; }
    }
    window.Worker = TrappingWorker;
    try {
      const failed = await Promise.allSettled([renderPdf("<p>one</p>"), renderPdf("<p>two</p>")]);
      const pdf = await renderPdf("<p>Fresh worker</p>");
      const pageCount = pdf.pageCount;
      pdf.dispose();
      return { failed: failed.map((item) => ({ status: item.status, code: item.reason?.status })), attempts, created, terminated, pageCount };
    } finally { window.Worker = RealWorker; }
  });
  expect(result).toEqual({
    failed: [{ status: "rejected", code: -23 }, { status: "rejected", code: -23 }],
    attempts: 2, created: 2, terminated: 1, pageCount: 1,
  });
});
