import { expect, test } from "@playwright/test";

function collectPageFailures(page) {
  const failures = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(message.text());
  });
  return failures;
}

test("browser harness passes structural, complex fixture, and PDF.js preview checks", async ({ page }) => {
  const failures = collectPageFailures(page);
  await page.goto("/tests/web/index.html");
  await page.getByRole("button", { name: "Run all browser tests" }).click();

  await expect.poll(
    () => page.locator("html").getAttribute("data-test-status"),
    { timeout: 120_000, message: "browser harness did not finish" },
  ).toMatch(/passed|failed/);

  const results = await page.locator("#test-results").innerText();
  expect(results).toContain("25 passed, 0 failed");
  expect(await page.locator("html").getAttribute("data-test-status"), results).toBe("passed");
  expect(failures, failures.join("\n")).toEqual([]);
});

test("mounted React ref renders controlled state into a real in-page PDF preview", async ({ page }) => {
  const failures = collectPageFailures(page);
  await page.goto("http://127.0.0.1:4174");

  const customer = "Browser E2E Customer S.p.A.";
  await page.getByLabel("Customer").fill(customer);
  await page.getByRole("button", { name: "Render and preview" }).click();
  await expect(page.getByText(/Previewing \d+ PDF page\(s\) inside the React app\./)).toBeVisible({ timeout: 120_000 });

  const encoded = await page.locator("#react-pdf-export").getAttribute("data-pdf");
  expect(encoded).toBeTruthy();
  expect(Buffer.from(encoded, "base64").subarray(0, 8).toString()).toBe("%PDF-1.7");
  await expect(page.locator("[data-html2realpdf-preview] canvas")).toHaveCount(1);
  await expect(page.getByText(customer).first()).toBeVisible();
  expect(failures, failures.join("\n")).toEqual([]);
});
