import { forwardRef, useEffect, useRef, useState } from "react";
import { createRenderer } from "@imggion/html2realpdf";
import {
  analyzePdf,
  createPdfArtifact,
  formatBytes,
  measure,
} from "../../benchmark/benchmark.js";

const wasmUrl = new URL("../../../bindings/js/dist/libhtml2realpdf.wasm", import.meta.url);
const pdfJsUrl = new URL("../../../bindings/js/dist/vendor/pdf.min.mjs", import.meta.url);
const pdfJsWorkerUrl = new URL("../../../bindings/js/dist/vendor/pdf.worker.min.mjs", import.meta.url);
const liveReportPage = { format: "a4", margin: [30, 36, 30, 36], unit: "pt" };
const stressReportPage = { format: "a4", margin: [28, 28, 28, 28], unit: "pt" };

let html2PdfJsPromise;
let pdfJsPromise;

const revenue = [42, 58, 51, 72, 84, 79, 96, 112, 108, 126, 139, 154];

function revenueChartSvg() {
  const min = Math.min(...revenue);
  const max = Math.max(...revenue);
  const points = revenue.map((value, index) => {
    const x = 22 + (index * 576) / (revenue.length - 1);
    const y = 142 - ((value - min) / (max - min)) * 118;
    return [x, y];
  });
  const line = points.map(([x, y], index) => `${index === 0 ? "M" : "L"}${x.toFixed(2)} ${y.toFixed(2)}`).join(" ");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 620 166">
    <rect width="620" height="166" fill="#f8fafc"/>
    <path d="M22 47 H598 M22 82 H598 M22 117 H598" fill="none" stroke="#dbeafe" stroke-width="1"/>
    <path d="${line} L598 154 L22 154 Z" fill="#2563eb" fill-opacity=".18"/>
    <path d="${line}" fill="none" stroke="#2563eb" stroke-width="4"/>
    <text x="590" y="22" text-anchor="end" font-size="13" fill="#1e3a8a">Revenue €154k</text>
  </svg>`;
}

function loadHtml2PdfJs() {
  html2PdfJsPromise ??= import("html2pdf.js").then((module) => {
    const html2pdf = module.default ?? module;
    if (typeof html2pdf !== "function") throw new Error("html2pdf.js did not expose its worker factory");
    return html2pdf;
  });
  return html2PdfJsPromise;
}

function loadPdfJs() {
  pdfJsPromise ??= import(/* @vite-ignore */ pdfJsUrl.href).then((pdfJs) => {
    pdfJs.GlobalWorkerOptions.workerSrc = pdfJsWorkerUrl.href;
    return pdfJs;
  });
  return pdfJsPromise;
}

function html2PdfJsOptions(page) {
  const [top, right, bottom, left] = page.margin;
  return {
    margin: [top, left, bottom, right],
    filename: "benchmark.pdf",
    image: { type: "jpeg", quality: 0.95 },
    html2canvas: { scale: 1, useCORS: true },
    jsPDF: { unit: "pt", format: page.format, orientation: page.orientation ?? "portrait" },
    pagebreak: { mode: ["css", "legacy"] },
    enableLinks: true,
  };
}

async function renderWithHtml2PdfJs(html2pdf, source, page) {
  const output = await html2pdf()
    .set(html2PdfJsOptions(page))
    .from(source)
    .outputPdf("arraybuffer");
  return new Uint8Array(output).slice();
}

function bytesToBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 16_384) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 16_384, bytes.length)));
  }
  return btoa(binary);
}

function RevenueChart() {
  const canvasRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context) return;

    context.clearRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = "#f8fafc";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.strokeStyle = "#dbeafe";
    context.lineWidth = 1;
    for (let row = 1; row < 4; row += 1) {
      const y = 12 + row * 35;
      context.beginPath();
      context.moveTo(22, y);
      context.lineTo(598, y);
      context.stroke();
    }

    const min = Math.min(...revenue);
    const max = Math.max(...revenue);
    context.beginPath();
    revenue.forEach((value, index) => {
      const x = 22 + (index * 576) / (revenue.length - 1);
      const y = 142 - ((value - min) / (max - min)) * 118;
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    context.lineTo(598, 154);
    context.lineTo(22, 154);
    context.closePath();
    context.fillStyle = "rgba(37, 99, 235, 0.18)";
    context.fill();

    context.beginPath();
    revenue.forEach((value, index) => {
      const x = 22 + (index * 576) / (revenue.length - 1);
      const y = 142 - ((value - min) / (max - min)) * 118;
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    context.strokeStyle = "#2563eb";
    context.lineWidth = 4;
    context.stroke();
  }, []);

  return <canvas ref={canvasRef} className="report-chart" width="620" height="166" aria-label="Revenue chart" />;
}

const ReportDocument = forwardRef(function ReportDocument({ customer, period, note, approved }, ref) {
  return (
    <article ref={ref} className="report-document">
      <header className="report-header">
        <p className="eyebrow">NORTHSTAR ANALYTICS · LIVE REACT REF</p>
        <h1>Executive performance report</h1>
        <p className="report-subtitle">{customer} · {period} · generated from the mounted component DOM</p>
      </header>

      <table className="kpi-table" aria-label="Key performance indicators">
        <tbody>
          <tr>
            <td><span className="kpi-label">Revenue</span><strong>€1.34M</strong><small className="positive">+18.2%</small></td>
            <td><span className="kpi-label">Orders</span><strong>18,492</strong><small className="positive">+11.6%</small></td>
            <td><span className="kpi-label">Margin</span><strong>32.8%</strong><small className="positive">+2.4 pt</small></td>
            <td><span className="kpi-label">Refunds</span><strong>1.9%</strong><small className="negative">-0.6 pt</small></td>
          </tr>
        </tbody>
      </table>

      <section className="report-section">
        <h2>Revenue trend</h2>
        <p>Monthly recognized revenue in thousands of euro. The live canvas is exported through the canvas-to-SVG adapter for native PDF output.</p>
        <RevenueChart />
      </section>

      <section className="report-section">
        <h2>Channel performance</h2>
        <table className="data-table">
          <thead><tr><th>Channel</th><th>Revenue</th><th>Orders</th><th>Conversion</th></tr></thead>
          <tbody>
            <tr><td>Organic search</td><td>€482,120</td><td>6,914</td><td>4.8%</td></tr>
            <tr><td>Paid social</td><td>€327,840</td><td>4,720</td><td>3.2%</td></tr>
            <tr><td>Email lifecycle</td><td>€289,330</td><td>4,152</td><td>7.6%</td></tr>
            <tr><td>Partnerships</td><td>€240,710</td><td>2,706</td><td>5.1%</td></tr>
          </tbody>
        </table>
      </section>

      <section className="report-section insight-section">
        <svg className="insight-icon" width="38" height="38" viewBox="0 0 38 38" aria-label="Insight">
          <circle cx="19" cy="19" r="18" fill="#dbeafe" />
          <path d="M12 24 L17 18 L21 21 L28 12" fill="none" stroke="#2563eb" strokeWidth="3" />
        </svg>
        <h2>Management note</h2>
        <p>{note}</p>
        <ul>
          <li>Protect margin while scaling the highest-converting lifecycle campaigns.</li>
          <li>Reallocate 8% of paid-social spend toward organic content production.</li>
        </ul>
        <p className="approval">{approved ? "Approved: figures reviewed" : "Pending: figures awaiting approval"}</p>
        <details>
          <summary>Confidential methodology note</summary>
          <p>This closed content must stay hidden in both the mounted component and its PDF snapshot.</p>
        </details>
      </section>

      <footer className="report-footer">
        <span>Northstar Analytics</span>
        <a href="https://example.com/reports/northstar">Open source dashboard</a>
      </footer>
    </article>
  );
});

const StressReportDocument = forwardRef(function StressReportDocument({ markup }, ref) {
  return <article ref={ref} className="stress-report-root" dangerouslySetInnerHTML={{ __html: markup }} />;
});

export function App() {
  const reportRef = useRef(null);
  const previewRef = useRef(null);
  const rendererRef = useRef(null);
  const pdfRef = useRef(null);
  const previewControllerRef = useRef(null);
  const pdfExportRef = useRef(null);
  const benchmarkArtifactsRef = useRef(new Map());
  const [customer, setCustomer] = useState("Acme Europe S.p.A.");
  const [period, setPeriod] = useState("Q2 2026");
  const [note, setNote] = useState("Growth remained broad-based, with email lifecycle producing the strongest conversion efficiency.");
  const [approved, setApproved] = useState(true);
  const [status, setStatus] = useState("Ready. Change the form, then render the mounted React ref.");
  const [rendering, setRendering] = useState(false);
  const [benchmarking, setBenchmarking] = useState(false);
  const [benchmarkStatus, setBenchmarkStatus] = useState("Benchmark the mounted report when you are ready.");
  const [benchmarkResults, setBenchmarkResults] = useState([]);
  const [documentMode, setDocumentMode] = useState("live");
  const [loadingStressReport, setLoadingStressReport] = useState(false);
  const [stressReportFixture, setStressReportFixture] = useState(null);

  useEffect(() => () => {
    previewControllerRef.current?.dispose();
    pdfRef.current?.dispose();
    rendererRef.current?.dispose();
    for (const artifact of benchmarkArtifactsRef.current.values()) artifact.dispose();
    benchmarkArtifactsRef.current.clear();
  }, []);

  function clearBenchmarkArtifacts() {
    for (const artifact of benchmarkArtifactsRef.current.values()) artifact.dispose();
    benchmarkArtifactsRef.current.clear();
  }

  function getDocumentProfile() {
    if (documentMode === "stress") {
      return {
        page: stressReportPage,
        filename: stressReportFixture?.filename ?? "northstar-30-page-stress-report",
        title: "Northstar 30-page enterprise stress report",
        expectedPages: stressReportFixture?.pageCount ?? 30,
      };
    }
    return {
      page: liveReportPage,
      filename: "northstar-react-ref-report",
      title: `${customer} ${period} performance report`,
      expectedPages: 1,
    };
  }

  async function changeDocumentMode(event) {
    const nextMode = event.target.value;
    setDocumentMode(nextMode);
    previewControllerRef.current?.dispose();
    previewControllerRef.current = null;
    pdfRef.current?.dispose();
    pdfRef.current = null;
    clearBenchmarkArtifacts();
    setBenchmarkResults([]);
    setStatus(nextMode === "stress" ? "Loading the 30-page mounted stress report..." : "Ready to render the live controlled report.");

    if (nextMode !== "stress" || stressReportFixture) return;
    setLoadingStressReport(true);
    try {
      const fixture = await import("../../benchmark/stress-report.js");
      setStressReportFixture({
        filename: fixture.STRESS_REPORT_FILENAME,
        pageCount: fixture.STRESS_REPORT_PAGE_COUNT,
        markup: `<style>${fixture.stressReportStyles}</style>${fixture.stressReportPagesHtml}`,
      });
      setStatus(`Mounted the ${fixture.STRESS_REPORT_PAGE_COUNT}-page stress report. Render or benchmark it when ready.`);
    } catch (error) {
      setStatus(`Stress report failed to load: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setLoadingStressReport(false);
    }
  }

  async function benchmarkHtml2RealPdf(pdfJs, profile) {
    let renderer;
    let coldPdf;
    let warmPdf;

    try {
      const cold = await measure(async () => {
        renderer = await createRenderer({ wasmUrl });
        return renderer.render(reportRef, {
          page: profile.page,
          layoutContext: "page",
          fallback: "error",
          canvasFallback: "error",
          canvasToSvg: ({ canvas }) => canvas.getAttribute("aria-label") === "Revenue chart" ? revenueChartSvg() : null,
        });
      });
      coldPdf = cold.value;
      coldPdf.toUint8Array();
      coldPdf.dispose();
      coldPdf = undefined;

      const warm = await measure(() => renderer.render(reportRef, {
        page: profile.page,
        layoutContext: "page",
        fallback: "error",
        canvasFallback: "error",
        canvasToSvg: ({ canvas }) => canvas.getAttribute("aria-label") === "Revenue chart" ? revenueChartSvg() : null,
      }));
      warmPdf = warm.value;
      if (warmPdf.diagnostics.some((diagnostic) => diagnostic.property === "border-spacing")) {
        throw new Error(`border-spacing emitted a diagnostic: ${JSON.stringify(warmPdf.diagnostics)}`);
      }
      const bytes = warmPdf.toUint8Array().slice();
      const analysis = await analyzePdf(bytes, pdfJs);
      const artifact = createPdfArtifact(bytes, `${profile.filename}-html2realpdf.pdf`);
      benchmarkArtifactsRef.current.set("html2realpdf", artifact);

      return {
        id: "html2realpdf",
        label: "html2realpdf",
        coldMs: cold.durationMs,
        warmMs: warm.durationMs,
        size: bytes.length,
        analysis,
        artifact,
      };
    } finally {
      coldPdf?.dispose();
      warmPdf?.dispose();
      renderer?.dispose();
    }
  }

  async function benchmarkHtml2PdfJs(html2pdf, pdfJs, profile) {
    const cold = await measure(() => renderWithHtml2PdfJs(html2pdf, reportRef.current, profile.page));
    const warm = await measure(() => renderWithHtml2PdfJs(html2pdf, reportRef.current, profile.page));
    const bytes = warm.value;
    const analysis = await analyzePdf(bytes, pdfJs);
    const artifact = createPdfArtifact(bytes, `${profile.filename}-html2pdfjs.pdf`);
    benchmarkArtifactsRef.current.set("html2pdfjs", artifact);

    return {
      id: "html2pdfjs",
      label: "html2pdf.js",
      coldMs: cold.durationMs,
      warmMs: warm.durationMs,
      size: bytes.length,
      analysis,
      artifact,
    };
  }

  async function benchmarkDocs() {
    if (!reportRef.current) {
      setBenchmarkStatus("The report ref is not mounted.");
      return;
    }
    if (documentMode === "stress" && !stressReportFixture) {
      setBenchmarkStatus("Wait for the 30-page stress report to finish loading.");
      return;
    }

    const profile = getDocumentProfile();
    setBenchmarking(true);
    setBenchmarkStatus("Loading html2pdf.js and the PDF analyzer...");
    setBenchmarkResults([]);
    clearBenchmarkArtifacts();
    document.documentElement.dataset.reactBenchmarkStatus = "running";

    try {
      const [html2pdf, pdfJs] = await Promise.all([loadHtml2PdfJs(), loadPdfJs()]);
      const results = [];
      for (const [id, label, benchmark] of [
        ["html2realpdf", "html2realpdf", () => benchmarkHtml2RealPdf(pdfJs, profile)],
        ["html2pdfjs", "html2pdf.js", () => benchmarkHtml2PdfJs(html2pdf, pdfJs, profile)],
      ]) {
        setBenchmarkStatus(`Rendering the mounted report with ${label}...`);
        try {
          results.push(await benchmark());
        } catch (error) {
          results.push({
            id,
            label,
            error: error instanceof Error ? error.message : String(error),
          });
        }
        setBenchmarkResults([...results]);
      }

      const successful = results.filter((result) => result.artifact);
      for (const result of successful) result.artifact.download();
      const pageMismatch = successful.find((result) => result.analysis.pageCount !== profile.expectedPages);
      document.documentElement.dataset.reactBenchmarkStatus = successful.length > 0 && !pageMismatch ? "complete" : "failed";
      setBenchmarkStatus(pageMismatch
        ? `${pageMismatch.label} produced ${pageMismatch.analysis.pageCount} pages; expected ${profile.expectedPages}.`
        : successful.length === 2
          ? "Benchmark complete. Both measured PDFs were downloaded."
          : `Benchmark finished with ${successful.length} successful engine(s); available PDFs were downloaded.`);
    } catch (error) {
      document.documentElement.dataset.reactBenchmarkStatus = "failed";
      setBenchmarkStatus(`Benchmark failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBenchmarking(false);
    }
  }

  function downloadBenchmarkResult(result) {
    result.artifact.download();
    setBenchmarkStatus(`Downloaded ${result.artifact.filename} from the measured bytes.`);
  }

  async function renderReport({ preview = false } = {}) {
    if (!reportRef.current) throw new Error("The report ref is not mounted");
    const profile = getDocumentProfile();
    setRendering(true);
    setStatus("Snapshotting the mounted React component...");
    try {
      rendererRef.current ??= await createRenderer({ wasmUrl });
      previewControllerRef.current?.dispose();
      pdfRef.current?.dispose();
      pdfRef.current = await rendererRef.current.render(reportRef, {
        page: profile.page,
        layoutContext: "page",
        metadata: { title: profile.title, author: "Northstar Analytics" },
        fallback: "error",
        canvasFallback: "error",
        canvasToSvg: ({ canvas }) => canvas.getAttribute("aria-label") === "Revenue chart" ? revenueChartSvg() : null,
      });
      if (pdfRef.current.diagnostics.some((diagnostic) => diagnostic.property === "border-spacing")) {
        throw new Error(`border-spacing emitted a diagnostic: ${JSON.stringify(pdfRef.current.diagnostics)}`);
      }
      const bytes = pdfRef.current.toUint8Array();
      pdfExportRef.current.setAttribute("data-pdf", bytesToBase64(bytes));
      setStatus(`Generated ${bytes.length.toLocaleString()} bytes across ${pdfRef.current.pageCount} page(s) from ref.current.`);
      if (preview) {
        previewControllerRef.current = await pdfRef.current.preview(previewRef.current, {
          initialScale: "fit-width",
          ariaLabel: "React ref PDF preview",
        });
        setStatus(`Previewing ${pdfRef.current.pageCount} PDF page(s) inside the React app.`);
      }
    } catch (error) {
      setStatus(`Render failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setRendering(false);
    }
  }

  function downloadReport() {
    if (!pdfRef.current) {
      setStatus("Render the React ref before downloading.");
      return;
    }
    pdfRef.current.download(`${getDocumentProfile().filename}.pdf`);
  }

  const busy = rendering || benchmarking || loadingStressReport;
  const liveControlsDisabled = busy || documentMode === "stress";

  return (
    <main className="app-shell">
      <header className="app-header">
        <p className="app-kicker">@imggion/html2realpdf · React integration QA</p>
        <h1>Mounted component versus real PDF</h1>
        <p>Edit controlled state, render the actual ref, and compare it with the in-page PDF canvas below.</p>
      </header>

      <section className="controls" aria-label="Live React state">
        <label className="wide-control">Rendered document<select value={documentMode} onChange={changeDocumentMode} disabled={busy}><option value="live">Live controlled report</option><option value="stress">30-page enterprise stress report</option></select></label>
        <label>Customer<input value={customer} onChange={(event) => setCustomer(event.target.value)} disabled={liveControlsDisabled} /></label>
        <label>Period<select value={period} onChange={(event) => setPeriod(event.target.value)} disabled={liveControlsDisabled}><option>Q1 2026</option><option>Q2 2026</option><option>Q3 2026</option></select></label>
        <label className="wide-control">Management note<textarea value={note} onChange={(event) => setNote(event.target.value)} rows="2" disabled={liveControlsDisabled} /></label>
        <label className="check-control"><input type="checkbox" checked={approved} onChange={(event) => setApproved(event.target.checked)} disabled={liveControlsDisabled} /> Approved</label>
        <div className="actions">
          <button type="button" onClick={() => renderReport()} disabled={busy}>Render ref</button>
          <button className="primary" type="button" onClick={() => renderReport({ preview: true })} disabled={busy}>Render and preview</button>
          <button type="button" onClick={downloadReport} disabled={busy}>Download</button>
          <button type="button" onClick={benchmarkDocs} disabled={busy}>{benchmarking ? "Benchmarking…" : "Benchmark docs"}</button>
        </div>
        <p className="status" aria-live="polite">{status}</p>
      </section>

      <section className="benchmark-panel" aria-labelledby="react-benchmark-title">
        <div>
          <p className="app-kicker">PDF benchmark</p>
          <h2 id="react-benchmark-title">Same mounted report, two renderers</h2>
          <p className="benchmark-note">First PDF includes renderer initialization; warm render reuses the initialized runtime. html2canvas uses scale 1. PDF.js distinguishes selectable text from image-only PDF pages.</p>
        </div>
        <p className="status" aria-live="polite">{benchmarkStatus}</p>
        {benchmarkResults.length > 0 ? (
          <div className="benchmark-table-scroll">
            <table className="benchmark-table" id="react-benchmark-results">
              <thead>
                <tr>
                  <th scope="col">Engine</th>
                  <th scope="col">First PDF</th>
                  <th scope="col">Warm render</th>
                  <th scope="col">File size</th>
                  <th scope="col">Pages</th>
                  <th scope="col">Content model</th>
                  <th scope="col">Output</th>
                </tr>
              </thead>
              <tbody>
                {benchmarkResults.map((result) => (
                  <tr
                    key={result.id}
                    data-engine={result.id}
                    data-status={result.error ? "failed" : "complete"}
                    data-classification={result.analysis?.contentModel}
                  >
                    <th scope="row">{result.label}</th>
                    <td data-metric="cold" data-value={result.error ? undefined : result.coldMs}>{result.error ? "—" : `${result.coldMs.toFixed(1)} ms`}</td>
                    <td data-metric="warm" data-value={result.error ? undefined : result.warmMs}>{result.error ? "—" : `${result.warmMs.toFixed(1)} ms`}</td>
                    <td data-metric="size" data-value={result.error ? undefined : result.size}>{result.error ? "—" : formatBytes(result.size)}</td>
                    <td data-metric="pages" data-value={result.error ? undefined : result.analysis.pageCount}>{result.error ? "—" : result.analysis.pageCount}</td>
                    <td className={result.error ? "benchmark-error" : undefined} title={result.analysis ? `${result.analysis.pageCount} page(s), ${result.analysis.textCharacters} text characters, ${result.analysis.imagePaints} image paints` : undefined}>
                      {result.error ? `Failed: ${result.error}` : result.analysis.contentModel}
                    </td>
                    <td>{result.artifact ? <button type="button" onClick={() => downloadBenchmarkResult(result)} disabled={benchmarking}>Download</button> : "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </section>

      <section className="comparison">
        <div>
          <h2>{documentMode === "stress" ? "Mounted 30-page React DOM" : "Mounted React DOM"}</h2>
          <div className="document-stage">
            {documentMode === "stress"
              ? stressReportFixture
                ? <StressReportDocument ref={reportRef} markup={stressReportFixture.markup} />
                : <p>Loading the stress report fixture...</p>
              : <ReportDocument ref={reportRef} customer={customer} period={period} note={note} approved={approved} />}
          </div>
        </div>
        <div>
          <h2>Generated PDF canvas</h2>
          <div ref={previewRef} className="preview-stage"><p>Click “Render and preview” to compare the generated pages here.</p></div>
        </div>
      </section>
      <textarea ref={pdfExportRef} id="react-pdf-export" hidden aria-hidden="true" readOnly />
    </main>
  );
}
