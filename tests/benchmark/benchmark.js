/** Measure one asynchronous render until its final value is available. */
export async function measure(operation) {
  const startedAt = performance.now();
  const value = await operation();
  return { durationMs: performance.now() - startedAt, value };
}

/** Format byte counts consistently across the native and React harnesses. */
export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1_000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${(bytes / 1_000).toFixed(1)} kB`;
  return `${(bytes / 1_000_000).toFixed(2)} MB`;
}

/**
 * Own a stable PDF download until the next benchmark run or page teardown.
 *
 * Keeping the object URL alive lets row downloads reuse the measured bytes
 * without running either renderer again.
 */
export function createPdfArtifact(bytes, filename) {
  const ownedBytes = bytes instanceof Uint8Array ? bytes.slice() : new Uint8Array(bytes);
  const url = URL.createObjectURL(new Blob([ownedBytes], { type: "application/pdf" }));
  let disposed = false;

  return {
    bytes: ownedBytes,
    filename,
    download() {
      if (disposed) throw new Error("This benchmark artifact has already been disposed");
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      anchor.hidden = true;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      URL.revokeObjectURL(url);
    },
  };
}

/**
 * Classify a generated file from PDF structure instead of its filename.
 *
 * Extractable text is treated as native/selectable content. A valid PDF with
 * no text and image-paint operators is classified as a raster image PDF.
 */
export async function analyzePdf(bytes, pdfJs) {
  const data = bytes instanceof Uint8Array ? bytes.slice() : new Uint8Array(bytes);
  const header = new TextDecoder().decode(data.subarray(0, 5));
  if (header !== "%PDF-") {
    return {
      valid: false,
      contentModel: "Invalid PDF",
      pageCount: 0,
      textCharacters: 0,
      imagePaints: 0,
      error: "Missing PDF header",
    };
  }

  const imageOperators = new Set([
    pdfJs.OPS.paintImageMaskXObject,
    pdfJs.OPS.paintImageXObject,
    pdfJs.OPS.paintInlineImageXObject,
    pdfJs.OPS.paintSolidColorImageMask,
  ]);
  const loadingTask = pdfJs.getDocument({ data });
  let documentProxy;

  try {
    documentProxy = await loadingTask.promise;
    let textCharacters = 0;
    let imagePaints = 0;

    for (let pageNumber = 1; pageNumber <= documentProxy.numPages; pageNumber += 1) {
      const page = await documentProxy.getPage(pageNumber);
      const [textContent, operatorList] = await Promise.all([
        page.getTextContent(),
        page.getOperatorList(),
      ]);
      for (const item of textContent.items) {
        if (typeof item.str === "string") textCharacters += item.str.replace(/\s/g, "").length;
      }
      for (const operator of operatorList.fnArray) {
        if (imageOperators.has(operator)) imagePaints += 1;
      }
      page.cleanup();
    }

    const contentModel = textCharacters > 0
      ? "Native/selectable PDF"
      : imagePaints > 0
        ? "Raster image PDF"
        : "PDF (unclassified)";

    return {
      valid: true,
      contentModel,
      pageCount: documentProxy.numPages,
      textCharacters,
      imagePaints,
    };
  } catch (error) {
    return {
      valid: false,
      contentModel: "Invalid PDF",
      pageCount: 0,
      textCharacters: 0,
      imagePaints: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  } finally {
    await documentProxy?.destroy();
    if (!documentProxy) await loadingTask.destroy();
  }
}
