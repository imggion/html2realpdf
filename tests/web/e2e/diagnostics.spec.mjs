import { expect, test } from "@playwright/test";

test("public CSS policies return structured diagnostics or fail explicitly", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await pkg.createRenderer({ execution: "main" });
    const source = '<p id="diagnostic-target" style="filter:blur(2px);color:#123456">diagnostic</p>';

    const warned = await renderer.render(source, {
      cssProfile: "web",
      unsupportedCss: "warn",
      fallback: "error",
    });
    const warningDiagnostics = warned.diagnostics;
    warned.dispose();

    const ignored = await renderer.render(source, {
      cssProfile: "web",
      unsupportedCss: "ignore",
      fallback: "error",
    });
    const ignoredDiagnostics = ignored.diagnostics;
    ignored.dispose();

    let policyError = "";
    try {
      await renderer.render(source, {
        cssProfile: "web",
        unsupportedCss: "error",
        fallback: "error",
      });
    } catch (error) {
      policyError = error instanceof Error ? error.message : String(error);
    }

    let strictError = "";
    try {
      await renderer.render(source, { cssProfile: "strict" });
    } catch (error) {
      strictError = error instanceof Error ? error.message : String(error);
    }
    renderer.dispose();
    return { warningDiagnostics, ignoredDiagnostics, policyError, strictError };
  });

  expect(result.warningDiagnostics).toEqual([{
    code: "UNSUPPORTED_CSS_PROPERTY",
    severity: "warning",
    message: "Unsupported CSS property was omitted: filter",
    property: "filter",
    phase: "snapshot",
  }]);
  expect(result.ignoredDiagnostics).toEqual([]);
  expect(result.policyError).toContain("filter is outside the web CSS profile");
  expect(result.strictError).toContain("filter is outside the strict CSS profile");
});
