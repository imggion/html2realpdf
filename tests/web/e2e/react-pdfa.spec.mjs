import { expect, test } from "@playwright/test";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { getDocument } from "../../../bindings/js/node_modules/pdfjs-dist/legacy/build/pdf.mjs";
import { validateFiles } from "../../pdfa/verapdf.mjs";

const attachment = { name: "dati-è.bin", mimeType: "", buffer: Buffer.from([0, 255, 42, 13, 10, 0]) };

async function inspectPdf(bytes) {
  const document = await getDocument({ data: Uint8Array.from(bytes) }).promise;
  try {
    const metadata = (await document.getMetadata()).metadata;
    return {
      part: metadata?.get("pdfaid:part") ?? null,
      conformance: metadata?.get("pdfaid:conformance") ?? null,
      attachments: Object.values(await document.getAttachments() ?? {}).map((file) => ({
        name: file.filename,
        bytes: Buffer.from(file.content),
      })),
    };
  } finally {
    await document.destroy();
  }
}

async function renderPdf(page, preview = false) {
  await page.getByRole("button", { name: preview ? "Render and preview" : "Render ref", exact: true }).click();
  await expect(page.locator(".controls > .status")).toContainText(preview ? "Previewing" : "Generated");
  return Buffer.from(await page.locator("#react-pdf-export").getAttribute("data-pdf"), "base64");
}

test("React export switches compliance, embeds local files and clears stale downloads", async ({ page, browserName }) => {
  const failures = [];
  page.on("pageerror", (error) => failures.push(error.message));
  await page.goto("http://127.0.0.1:4174");
  const compliance = page.getByLabel("PDF compliance");
  const fileInput = page.getByLabel("Attachment (optional)");
  const relationship = page.getByLabel("Attachment relationship");
  const downloadButton = page.locator(".actions").getByRole("button", { name: "Download", exact: true });
  await expect(compliance).toHaveValue("none");
  await expect(relationship).toBeDisabled();
  await expect(downloadButton).toBeDisabled();

  await compliance.selectOption("pdfa-3u");
  const emptyArchive = await renderPdf(page);
  expect(await inspectPdf(emptyArchive)).toEqual({ part: "3", conformance: "U", attachments: [] });

  await fileInput.setInputFiles(attachment);
  await expect(downloadButton).toBeDisabled();
  await expect(page.locator("#react-pdf-export")).not.toHaveAttribute("data-pdf");
  await expect(page.locator(".attachment-summary")).toContainText("dati-è.bin · 6 B");
  await relationship.selectOption("Data");
  const archive = await renderPdf(page, true);
  expect(await inspectPdf(archive)).toEqual({ part: "3", conformance: "U", attachments: [{ name: attachment.name, bytes: attachment.buffer }] });
  expect(archive.toString("latin1")).toContain("/AFRelationship /Data");
  expect(archive.toString("latin1")).toContain("/Subtype /application#2Foctet-stream");
  await expect(page.locator("#react-pdf-preview canvas")).toHaveCount(1);
  const downloadPromise = page.waitForEvent("download");
  await downloadButton.click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("northstar-react-ref-report-pdfa-3u.pdf");
  expect((await readFile(await download.path())).equals(archive)).toBe(true);

  await relationship.selectOption("Supplement");
  await expect(downloadButton).toBeDisabled();
  await expect(page.locator("#react-pdf-preview canvas")).toHaveCount(0);
  await compliance.selectOption("none");
  const ordinary = await renderPdf(page);
  expect(await inspectPdf(ordinary)).toEqual({ part: null, conformance: null, attachments: [{ name: attachment.name, bytes: attachment.buffer }] });
  expect(ordinary.toString("latin1")).toContain("/AFRelationship /Supplement");

  await page.getByRole("button", { name: "Remove attachment" }).click();
  await expect(fileInput).toBeFocused();
  await expect(fileInput).toHaveValue("");
  await expect(relationship).toBeDisabled();
  await expect(downloadButton).toBeDisabled();
  expect(await inspectPdf(await renderPdf(page))).toEqual({ part: null, conformance: null, attachments: [] });

  // A failed local read must not leave the previous PDF available for download.
  await fileInput.setInputFiles(attachment);
  await page.evaluate(() => { File.prototype.arrayBuffer = async () => { throw new Error("Cannot read selected file"); }; });
  await page.getByRole("button", { name: "Render ref", exact: true }).click();
  await expect(page.locator(".controls > .status")).toContainText("Render failed: Cannot read selected file");
  await expect(downloadButton).toBeDisabled();
  await expect(compliance).toBeEnabled();
  expect(failures).toEqual([]);

  if (browserName === "chromium") {
    await mkdir(resolve("../../tmp/pdfa"), { recursive: true });
    const files = [resolve("../../tmp/pdfa/react-empty.pdf"), resolve("../../tmp/pdfa/react-attached.pdf")];
    await writeFile(files[0], emptyArchive);
    await writeFile(files[1], archive);
    await validateFiles(files, "react-validation.json");
  }
});

test("React benchmark applies export options to html2realpdf", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Benchmark and external validation run once");
  const downloads = [];
  page.on("download", (download) => downloads.push(download));
  await page.goto("http://127.0.0.1:4174");
  await page.getByLabel("PDF compliance").selectOption("pdfa-3u");
  await page.getByLabel("Attachment (optional)").setInputFiles(attachment);
  await page.getByRole("button", { name: "Benchmark docs" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-react-benchmark-status", "complete");
  await expect.poll(() => downloads.length).toBe(2);
  const native = downloads.find((download) => download.suggestedFilename() === "northstar-react-ref-report-pdfa-3u-html2realpdf.pdf");
  const raster = downloads.find((download) => download.suggestedFilename() === "northstar-react-ref-report-html2pdfjs.pdf");
  expect(native).toBeTruthy();
  expect(raster).toBeTruthy();
  const bytes = await readFile(await native.path());
  expect(await inspectPdf(bytes)).toEqual({ part: "3", conformance: "U", attachments: [{ name: attachment.name, bytes: attachment.buffer }] });
  expect(await inspectPdf(await readFile(await raster.path()))).toEqual({ part: null, conformance: null, attachments: [] });
  await expect(page.locator('#react-benchmark-results tr[data-engine="html2realpdf"]')).toContainText("PDF/A-3u · 1 attachment");
  const file = resolve("../../tmp/pdfa/react-benchmark.pdf");
  await mkdir(resolve("../../tmp/pdfa"), { recursive: true });
  await writeFile(file, bytes);
  await validateFiles([file], "react-benchmark-validation.json");
  await page.getByLabel("PDF compliance").selectOption("none");
  await expect(page.locator("#react-benchmark-results")).toHaveCount(0);
});
