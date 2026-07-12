import { forwardRef, useEffect, useRef, useState } from "react";
import { createRenderer } from "@imggion/html2realpdf";

const wasmUrl = new URL("../../../bindings/js/dist/libhtml2realpdf.wasm", import.meta.url);

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

export function App() {
  const reportRef = useRef(null);
  const previewRef = useRef(null);
  const rendererRef = useRef(null);
  const pdfRef = useRef(null);
  const previewControllerRef = useRef(null);
  const pdfExportRef = useRef(null);
  const [customer, setCustomer] = useState("Acme Europe S.p.A.");
  const [period, setPeriod] = useState("Q2 2026");
  const [note, setNote] = useState("Growth remained broad-based, with email lifecycle producing the strongest conversion efficiency.");
  const [approved, setApproved] = useState(true);
  const [status, setStatus] = useState("Ready. Change the form, then render the mounted React ref.");
  const [rendering, setRendering] = useState(false);

  useEffect(() => () => {
    previewControllerRef.current?.dispose();
    pdfRef.current?.dispose();
    rendererRef.current?.dispose();
  }, []);

  async function renderReport({ preview = false } = {}) {
    if (!reportRef.current) throw new Error("The report ref is not mounted");
    setRendering(true);
    setStatus("Snapshotting the mounted React component...");
    try {
      rendererRef.current ??= await createRenderer({ wasmUrl });
      previewControllerRef.current?.dispose();
      pdfRef.current?.dispose();
      pdfRef.current = await rendererRef.current.render(reportRef, {
        page: { format: "a4", margin: [30, 36, 30, 36], unit: "pt" },
        metadata: { title: `${customer} ${period} performance report`, author: "Northstar Analytics" },
        fallback: "error",
        canvasFallback: "error",
        canvasToSvg: ({ canvas }) => canvas.getAttribute("aria-label") === "Revenue chart" ? revenueChartSvg() : null,
      });
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
    pdfRef.current.download("northstar-react-ref-report.pdf");
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <p className="app-kicker">@imggion/html2realpdf · React integration QA</p>
        <h1>Mounted component versus real PDF</h1>
        <p>Edit controlled state, render the actual ref, and compare it with the in-page PDF canvas below.</p>
      </header>

      <section className="controls" aria-label="Live React state">
        <label>Customer<input value={customer} onChange={(event) => setCustomer(event.target.value)} /></label>
        <label>Period<select value={period} onChange={(event) => setPeriod(event.target.value)}><option>Q1 2026</option><option>Q2 2026</option><option>Q3 2026</option></select></label>
        <label className="wide-control">Management note<textarea value={note} onChange={(event) => setNote(event.target.value)} rows="2" /></label>
        <label className="check-control"><input type="checkbox" checked={approved} onChange={(event) => setApproved(event.target.checked)} /> Approved</label>
        <div className="actions">
          <button type="button" onClick={() => renderReport()} disabled={rendering}>Render ref</button>
          <button className="primary" type="button" onClick={() => renderReport({ preview: true })} disabled={rendering}>Render and preview</button>
          <button type="button" onClick={downloadReport} disabled={rendering}>Download</button>
        </div>
        <p className="status" aria-live="polite">{status}</p>
      </section>

      <section className="comparison">
        <div>
          <h2>Mounted React DOM</h2>
          <div className="document-stage"><ReportDocument ref={reportRef} customer={customer} period={period} note={note} approved={approved} /></div>
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
