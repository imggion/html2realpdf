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
  const previewHost = page.locator("#pdf-preview [data-html2realpdf-preview]");
  const previewToolbar = page.locator("#pdf-preview [data-html2realpdf-preview] .toolbar");
  const previewPages = page.locator("#pdf-preview [data-html2realpdf-preview] .pages");
  await expect(previewToolbar).toBeHidden();
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("0px");
  const hiddenNavigation = await page.evaluate(() => {
    const hostScroll = window.scrollY;
    window.__html2realpdfPreview.nextPage();
    return {
      currentPage: window.__html2realpdfPreview.currentPage,
      hostScrollBefore: hostScroll,
      hostScrollAfter: window.scrollY,
      changes: window.__html2realpdfPreviewPageChanges,
    };
  });
  expect(hiddenNavigation).toEqual({
    currentPage: 2,
    hostScrollBefore: hiddenNavigation.hostScrollBefore,
    hostScrollAfter: hiddenNavigation.hostScrollBefore,
    changes: [{ currentPage: 1, totalPages: 4 }, { currentPage: 2, totalPages: 4 }],
  });
  const directNavigation = await page.evaluate(() => {
    const preview = window.__html2realpdfPreview;
    const hostScroll = window.scrollY;
    preview.goToPage(-5);
    preview.goToPage(99);
    preview.goToPage(2);
    preview.goToPage(2);
    return {
      currentPage: preview.currentPage,
      hostScrollBefore: hostScroll,
      hostScrollAfter: window.scrollY,
      pageSequence: window.__html2realpdfPreviewPageChanges.map(({ currentPage }) => currentPage),
    };
  });
  expect(directNavigation).toEqual({
    currentPage: 2,
    hostScrollBefore: directNavigation.hostScrollBefore,
    hostScrollAfter: directNavigation.hostScrollBefore,
    pageSequence: [1, 2, 1, 4, 2],
  });
  await page.getByLabel("Padding (px)").fill("12");
  await page.getByLabel("Padding (px)").press("Tab");
  await expect.poll(() => previewPages.evaluate((element) => getComputedStyle(element).paddingLeft)).toBe("12px");
  await page.getByRole("button", { name: "Show toolbar", exact: true }).click();
  await expect(previewToolbar).toBeVisible();
  const previewSummary = previewHost.locator(".summary");
  const previousPage = previewHost.getByRole("button", { name: "Previous page" });
  const nextPage = previewHost.getByRole("button", { name: "Next page" });
  const navigationGroup = previewHost.locator(".navigation");
  const zoomGroup = previewHost.locator(".controls");
  await expect(previewSummary).toHaveText("Page 1 of 4");
  await expect(previousPage).toBeDisabled();
  await expect(nextPage).toBeEnabled();
  await expect(previousPage).toHaveAttribute("type", "button");
  await expect(nextPage).toHaveAttribute("type", "button");
  expect(await previousPage.evaluate((button) => button.tagName)).toBe("BUTTON");
  expect(await nextPage.evaluate((button) => button.tagName)).toBe("BUTTON");
  expect(await previousPage.boundingBox()).toMatchObject({ width: 44, height: 44 });
  expect(await nextPage.boundingBox()).toMatchObject({ width: 44, height: 44 });
  for (const button of [previousPage, nextPage]) {
    const icon = button.locator("svg");
    await expect(icon).toHaveCount(1);
    await expect(icon).toHaveAttribute("aria-hidden", "true");
    await expect(icon).toHaveAttribute("focusable", "false");
  }
  expect(await navigationGroup.evaluate((group) => group.parentElement?.className)).toBe("toolbar");
  expect(await zoomGroup.evaluate((group) => group.parentElement?.className)).toBe("toolbar");

  await page.keyboard.press("Tab");
  await nextPage.evaluate((button) => button.focus({ preventScroll: true }));
  await expect(nextPage).toBeFocused();
  await expect(nextPage).toHaveCSS("outline-style", "solid");
  await expect(nextPage).toHaveCSS("outline-width", "2px");

  await nextPage.click();
  await expect(previewSummary).toHaveText("Page 2 of 4");
  await expect.poll(() => page.evaluate(() => window.__html2realpdfPreviewPageChanges.length)).toBe(2);
  await previousPage.click();
  await expect(previewSummary).toHaveText("Page 1 of 4");
  await expect(previousPage).toBeDisabled();
  await page.evaluate(() => {
    window.__html2realpdfPreview.previousPage();
    window.__html2realpdfPreview.nextPage();
    window.__html2realpdfPreview.nextPage();
  });
  await expect(previewSummary).toHaveText("Page 3 of 4");
  await previewPages.evaluate((element) => { element.scrollTop = element.scrollHeight; });
  await expect(previewSummary).toHaveText("Page 4 of 4");
  await expect(nextPage).toBeDisabled();
  const lastPageState = await page.evaluate(async () => {
    const changesBeforeNoOp = window.__html2realpdfPreviewPageChanges.length;
    window.__html2realpdfPreview.nextPage();
    const scale = window.__html2realpdfPreview.currentScale;
    await window.__html2realpdfPreview.setScale(scale < 2.9 ? scale + 0.1 : scale - 0.1);
    return {
      currentPage: window.__html2realpdfPreview.currentPage,
      changesBeforeNoOp,
      changesAfterZoom: window.__html2realpdfPreviewPageChanges.length,
      pageSequence: window.__html2realpdfPreviewPageChanges.map(({ currentPage }) => currentPage),
    };
  });
  expect(lastPageState).toEqual({
    currentPage: 4,
    changesBeforeNoOp: 6,
    changesAfterZoom: 6,
    pageSequence: [1, 2, 1, 2, 3, 4],
  });
  await expect(previewSummary).toHaveText("Page 4 of 4");

  await page.evaluate(() => window.__html2realpdfShowSinglePagePreview());
  await expect(previewSummary).toHaveText("Page 1 of 1");
  await expect(previousPage).toBeDisabled();
  await expect(nextPage).toBeDisabled();
  expect(await page.evaluate(() => {
    window.__html2realpdfPreview.previousPage();
    window.__html2realpdfPreview.nextPage();
    return {
      currentPage: window.__html2realpdfPreview.currentPage,
      changes: window.__html2realpdfPreviewPageChanges,
    };
  })).toEqual({ currentPage: 1, changes: [{ currentPage: 1, totalPages: 1 }] });
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
  const customPageNavigation = page.getByRole("group", { name: "Custom page navigation" });
  await expect(customPageNavigation.getByText("Page 1 of 1")).toBeVisible();
  await expect(customPageNavigation.getByRole("button", { name: "Previous page" })).toBeDisabled();
  await expect(customPageNavigation.getByRole("button", { name: "Next page" })).toBeDisabled();
  const customPageNumber = customPageNavigation.getByLabel("Page number");
  await expect(customPageNumber).toHaveValue("1");
  await expect(customPageNavigation.getByRole("button", { name: "Go to page" })).toBeEnabled();
  await customPageNumber.fill("8");
  await customPageNumber.press("Enter");
  await expect(customPageNumber).toHaveValue("1");
  await expect(customPageNavigation.getByText("Page 1 of 1")).toBeVisible();
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

test("React custom page buttons stay synchronized with the PDF preview", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "The 30-page custom navigation test runs once to keep the release gate fast");
  test.setTimeout(180_000);
  const failures = collectPageFailures(page);
  await page.goto("http://127.0.0.1:4174");

  await page.getByLabel("Rendered document").selectOption("stress");
  await expect(page.getByText("Mounted the 30-page stress report. Render or benchmark it when ready.")).toBeVisible();
  await page.getByRole("button", { name: "Render and preview" }).click();
  await expect(page.getByText("Previewing 30 PDF page(s) inside the React app.")).toBeVisible({ timeout: 180_000 });

  const navigation = page.getByRole("group", { name: "Custom page navigation" });
  const previousPage = navigation.getByRole("button", { name: "Previous page" });
  const nextPage = navigation.getByRole("button", { name: "Next page" });
  const pageNumber = navigation.getByLabel("Page number");
  const goToPage = navigation.getByRole("button", { name: "Go to page" });
  const previewPages = page.locator("#react-pdf-preview .pages");

  await expect(navigation.getByText("Page 1 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("1");
  await expect(previousPage).toBeDisabled();
  await expect(nextPage).toBeEnabled();

  await nextPage.click();
  await expect(navigation.getByText("Page 2 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("2");
  await expect(previousPage).toBeEnabled();
  await previousPage.click();
  await expect(navigation.getByText("Page 1 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("1");

  await pageNumber.fill("12");
  await goToPage.click();
  await expect(navigation.getByText("Page 12 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("12");

  await pageNumber.fill("-5");
  await pageNumber.press("Enter");
  await expect(navigation.getByText("Page 1 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("1");

  await pageNumber.fill("99");
  await pageNumber.press("Enter");
  await expect(navigation.getByText("Page 30 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("30");
  await expect(nextPage).toBeDisabled();

  await previewPages.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(navigation.getByText("Page 30 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("30");
  await expect(nextPage).toBeDisabled();
  await previousPage.click();
  await expect(navigation.getByText("Page 29 of 30")).toBeVisible();
  await expect(pageNumber).toHaveValue("29");
  await expect(nextPage).toBeEnabled();
  expect(failures, failures.join("\n")).toEqual([]);
});
