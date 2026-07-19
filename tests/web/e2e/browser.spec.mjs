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
  expect(results).toContain("24 passed, 0 failed");
  expect(await page.locator("html").getAttribute("data-test-status"), results).toBe("passed");
  const previewHost = page.locator("#pdf-preview [data-html2realpdf-preview]");
  const previewToolbar = page.locator("#pdf-preview [data-html2realpdf-preview] .toolbar");
  const previewPages = page.locator("#pdf-preview [data-html2realpdf-preview] .pages");
  await expect(previewToolbar).toBeHidden();
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("0px");
  await page.getByLabel("Padding (px)").fill("12");
  await page.getByLabel("Padding (px)").press("Tab");
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("12px");
  await page.getByRole("button", { name: "Show toolbar", exact: true }).click();
  await expect(previewToolbar).toBeVisible();
  await page.emulateMedia({ colorScheme: "light" });
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(255, 255, 255, 0.96)");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(24, 32, 42, 0.96)");
  const themeToggle = page.getByRole("button", { name: "Toggle dark mode" });
  await expect(themeToggle).toHaveAttribute("aria-pressed", "true");
  await themeToggle.click();
  expect(await previewHost.getAttribute("data-theme")).toBe("light");
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(255, 255, 255, 0.96)");
  await expect(themeToggle).toHaveAttribute("aria-pressed", "false");
  await themeToggle.click();
  expect(await previewHost.getAttribute("data-theme")).toBe("dark");
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(24, 32, 42, 0.96)");
  await expect(themeToggle).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "Hide toolbar", exact: true }).click();
  await expect(previewToolbar).toBeHidden();
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
  const previewHost = page.locator("#react-pdf-preview > [data-html2realpdf-preview]");
  const previewToolbar = previewHost.locator(".toolbar");
  const previewPages = previewHost.locator(".pages");
  await expect(previewHost.locator("canvas")).toHaveCount(1);
  await expect(previewToolbar).toBeVisible();
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("28px");
  await page.getByLabel("Padding (px)").fill("12");
  await page.getByLabel("Padding (px)").press("Tab");
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("12px");
  await page.getByRole("button", { name: "Hide toolbar", exact: true }).click();
  await expect(previewToolbar).toBeHidden();
  await page.getByRole("button", { name: "Show toolbar", exact: true }).click();
  await expect(previewToolbar).toBeVisible();
  await expect(page.getByText(customer).first()).toBeVisible();
  await expect(previewHost).toHaveAttribute("data-theme", "light");
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(255, 255, 255, 0.96)");
  await page.emulateMedia({ colorScheme: "dark" });
  expect(failures, failures.join("\n")).toEqual([]);
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(255, 255, 255, 0.96)");
  const themeToggle = page.getByRole("button", { name: "Toggle dark mode" });
  await expect(themeToggle).toHaveAttribute("aria-pressed", "false");
  await expect(themeToggle.locator(".theme-icon-sun")).toBeVisible();
  await expect(themeToggle.locator(".theme-icon-moon")).toBeHidden();
  await themeToggle.click();
  expect(await previewHost.getAttribute("data-theme")).toBe("dark");
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(24, 32, 42, 0.96)");
  await expect(themeToggle).toHaveAttribute("aria-pressed", "true");
  await expect(themeToggle.locator(".theme-icon-moon")).toBeVisible();
  await expect(themeToggle.locator(".theme-icon-sun")).toBeHidden();
  await themeToggle.click();
  expect(await previewHost.getAttribute("data-theme")).toBe("light");
  await expect(previewToolbar).toHaveCSS("background-color", "rgba(255, 255, 255, 0.96)");
  await expect(themeToggle).toHaveAttribute("aria-pressed", "false");
  expect(failures, failures.join("\n")).toEqual([]);
});
