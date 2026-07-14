export const STRESS_REPORT_PAGE_COUNT = 30;
export const STRESS_REPORT_FILENAME = "northstar-30-page-stress-report";

const regions = ["Western Europe", "North America", "Asia Pacific", "Nordics", "Southern Europe", "Latin America"];
const products = ["Atlas Platform", "Beacon Commerce", "Cirrus Data", "Drift Mobile", "Ember Identity", "Flux Automation"];
const owners = ["Commercial", "Finance", "Operations", "Platform", "Data", "Security"];

export const stressReportStyles = `
  .stress-report-root { background:#ffffff; color:#172033; font-family:"Noto Sans",Arial,sans-serif; font-size:12px; margin:0; padding:0; }
  .stress-page { background:#ffffff; box-sizing:border-box; min-height:940px; margin:0 auto; padding:28px 30px; width:700px; break-after:page; page-break-after:always; }
  .stress-page:last-child { break-after:auto; page-break-after:auto; }
  .stress-cover { background:#10243e; color:#ffffff; }
  .stress-header { border-bottom:2px solid #2563eb; margin-bottom:10px; padding-bottom:7px; }
  .stress-header table { border-collapse:collapse; width:100%; }
  .stress-header td { border:0; padding:0; }
  .stress-kicker { color:#2563eb; font-size:9px; font-weight:bold; letter-spacing:1.1px; margin:0; text-transform:uppercase; }
  .stress-cover .stress-kicker { color:#67e8f9; }
  .stress-title { color:#0f172a; font-size:22px; line-height:1.1; margin:4px 0; }
  .stress-cover .stress-title { color:#ffffff; font-size:42px; margin-top:58px; width:560px; }
  .stress-subtitle { color:#64748b; font-size:10px; margin:0; }
  .stress-cover .stress-subtitle { color:#cbd5e1; font-size:17px; line-height:1.5; width:540px; }
  .stress-page-number { color:#64748b; font-size:9px; text-align:right; white-space:nowrap; }
  .stress-cover .stress-page-number { color:#94a3b8; }
  .stress-kpis { border-collapse:separate; border-spacing:5px; margin:7px -5px 9px; table-layout:fixed; width:calc(100% + 10px); }
  .stress-kpis td { background:#eff6ff; border:1px solid #bfdbfe; border-radius:9px; padding:7px; vertical-align:top; width:25%; }
  .stress-kpi-label { color:#64748b; font-size:8px; font-weight:bold; letter-spacing:.7px; }
  .stress-kpi-value { color:#0f172a; font-size:17px; font-weight:bold; line-height:1.15; }
  .stress-positive { color:#15803d; font-size:9px; font-weight:bold; }
  .stress-negative { color:#be123c; font-size:9px; font-weight:bold; }
  .stress-section-title { color:#153e75; font-size:14px; margin:8px 0 5px; }
  .stress-copy { color:#475569; line-height:1.4; margin:4px 0 7px; }
  .stress-callout { background:#ecfeff; border-left:4px solid #0891b2; color:#164e63; line-height:1.35; margin-top:7px; padding:7px 9px; }
  .stress-warning { background:#fffbeb; border-left-color:#d97706; color:#78350f; }
  .stress-chart { background:#f8fafc; border:1px solid #dbe3ee; border-radius:10px; padding:6px; }
  .stress-chart svg { display:block; height:160px; width:100%; }
  .stress-data { border-collapse:collapse; table-layout:fixed; width:100%; }
  .stress-data th { background:#1e3a8a; border:1px solid #1e3a8a; color:#ffffff; font-size:8px; line-height:1.2; padding:4px 5px; text-align:left; }
  .stress-data td { border:1px solid #dbe3ee; font-size:8px; line-height:1.2; padding:4px 5px; vertical-align:top; }
  .stress-data tbody tr:nth-child(even) td { background:#f8fafc; }
  .stress-status-good { color:#15803d; font-weight:bold; }
  .stress-status-watch { color:#b45309; font-weight:bold; }
  .stress-status-risk { color:#be123c; font-weight:bold; }
  .stress-columns { border-collapse:separate; border-spacing:10px 0; margin:0 -10px; table-layout:fixed; width:calc(100% + 20px); }
  .stress-columns > tbody > tr > td { border:0; padding:0 10px; vertical-align:top; width:50%; }
  .stress-card { background:#f8fafc; border:1px solid #dbe3ee; border-radius:10px; min-height:116px; padding:9px; }
  .stress-card h3 { color:#153e75; font-size:11px; margin:0 0 5px; }
  .stress-card p, .stress-card li { color:#475569; font-size:8px; line-height:1.35; }
  .stress-card ul { margin:4px 0; padding-left:15px; }
  .stress-footer { border-top:1px solid #dbe3ee; color:#64748b; font-size:8px; margin-top:8px; padding-top:5px; }
  .stress-footer table { border-collapse:collapse; width:100%; }
  .stress-footer td { border:0; padding:0; }
  .stress-footer td:last-child { text-align:right; }
  .stress-cover-art { margin-top:54px; }
  .stress-cover-note { color:#94a3b8; font-size:10px; margin-top:42px; }
  .stress-legend { color:#64748b; font-size:9px; margin-top:5px; }
  .stress-method { background:#f8fafc; border:1px solid #dbe3ee; border-radius:10px; margin:9px 0; padding:10px 12px; }
  .stress-method strong { color:#153e75; }
`;

function lineChartSvg(seed, label) {
  const points = Array.from({ length: 10 }, (_, index) => {
    const x = 42 + index * 61;
    const value = 44 + ((seed * 17 + index * 23 + index * index * 3) % 108);
    const y = 176 - value;
    return [x, y, value];
  });
  const line = points.map(([x, y], index) => `${index === 0 ? "M" : "L"}${x} ${y}`).join(" ");
  const area = `${line} L591 186 L42 186 Z`;
  const dots = points.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="4" fill="#1d4ed8"/>`).join("");
  return `<svg viewBox="0 0 630 215" role="img" aria-label="${label}">
    <defs><linearGradient id="area-${seed}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2563eb" stop-opacity=".35"/><stop offset="1" stop-color="#2563eb" stop-opacity=".04"/></linearGradient></defs>
    <rect width="630" height="215" rx="8" fill="#f8fafc"/>
    <path d="M42 46 H606 M42 92 H606 M42 138 H606 M42 186 H606" fill="none" stroke="#dbeafe" stroke-width="1"/>
    <path d="${area}" fill="url(#area-${seed})"/>
    <path d="${line}" fill="none" stroke="#1d4ed8" stroke-width="4"/>
    ${dots}
    <text x="42" y="205" font-size="10" fill="#64748b">Jan</text><text x="570" y="205" font-size="10" fill="#64748b">Oct</text>
    <text x="596" y="20" text-anchor="end" font-size="11" fill="#1e3a8a">${label}</text>
  </svg>`;
}

function barChartSvg(seed, label) {
  const bars = Array.from({ length: 7 }, (_, index) => {
    const height = 48 + ((seed * 29 + index * 31) % 108);
    const x = 48 + index * 78;
    const y = 182 - height;
    const color = index % 3 === 0 ? "#0ea5e9" : index % 3 === 1 ? "#2563eb" : "#14b8a6";
    return `<rect x="${x}" y="${y}" width="48" height="${height}" rx="5" fill="${color}"/><text x="${x + 24}" y="198" text-anchor="middle" font-size="9" fill="#64748b">S${index + 1}</text>`;
  }).join("");
  return `<svg viewBox="0 0 630 215" role="img" aria-label="${label}">
    <rect width="630" height="215" rx="8" fill="#f8fafc"/>
    <path d="M34 40 H608 M34 88 H608 M34 136 H608 M34 182 H608" fill="none" stroke="#dbeafe" stroke-width="1"/>
    ${bars}
    <text x="598" y="20" text-anchor="end" font-size="11" fill="#1e3a8a">${label}</text>
  </svg>`;
}

function processDiagramSvg(seed) {
  const stages = ["Acquire", "Validate", "Transform", "Score", "Publish"];
  const nodes = stages.map((stage, index) => {
    const x = 46 + index * 122;
    const fill = index <= seed % stages.length ? "#dbeafe" : "#f1f5f9";
    return `<rect x="${x}" y="68" width="94" height="58" rx="12" fill="${fill}" stroke="#2563eb" stroke-width="2"/><text x="${x + 47}" y="102" text-anchor="middle" font-size="11" fill="#153e75">${stage}</text>`;
  }).join("");
  const arrows = Array.from({ length: 4 }, (_, index) => {
    const x = 140 + index * 122;
    return `<path d="M${x} 97 H${x + 22} M${x + 15} 89 L${x + 23} 97 L${x + 15} 105" fill="none" stroke="#0891b2" stroke-width="2"/>`;
  }).join("");
  return `<svg viewBox="0 0 650 190" role="img" aria-label="Data processing flow diagram">
    <rect width="650" height="190" rx="8" fill="#f8fafc"/>
    ${nodes}${arrows}
    <circle cx="325" cy="154" r="8" fill="#14b8a6"/><text x="340" y="158" font-size="10" fill="#475569">Automated control checkpoint ${seed + 1}</text>
  </svg>`;
}

function ringChartSvg(seed) {
  const primary = 52 + (seed * 7) % 28;
  const secondary = 100 - primary;
  return `<svg viewBox="0 0 300 215" role="img" aria-label="Portfolio allocation ring chart">
    <rect width="300" height="215" rx="8" fill="#f8fafc"/>
    <circle cx="112" cy="104" r="62" fill="none" stroke="#dbeafe" stroke-width="28"/>
    <path d="M112 42 A62 62 0 1 1 55 128" fill="none" stroke="#2563eb" stroke-width="28"/>
    <circle cx="112" cy="104" r="34" fill="#ffffff"/>
    <text x="112" y="101" text-anchor="middle" font-size="22" font-weight="bold" fill="#153e75">${primary}%</text>
    <text x="112" y="118" text-anchor="middle" font-size="9" fill="#64748b">CORE</text>
    <rect x="205" y="72" width="12" height="12" fill="#2563eb"/><text x="224" y="82" font-size="10" fill="#475569">Core ${primary}%</text>
    <rect x="205" y="101" width="12" height="12" fill="#dbeafe"/><text x="224" y="111" font-size="10" fill="#475569">Growth ${secondary}%</text>
  </svg>`;
}

function dataRows(seed, count = 8) {
  return Array.from({ length: count }, (_, index) => {
    const region = regions[(seed + index) % regions.length];
    const product = products[(seed * 2 + index) % products.length];
    const revenue = 180 + ((seed * 83 + index * 47) % 720);
    const margin = 42 + ((seed * 11 + index * 7) % 31);
    const growth = -3 + ((seed * 13 + index * 9) % 28);
    const status = growth > 15 ? ["Strong", "stress-status-good"] : growth > 5 ? ["Watch", "stress-status-watch"] : ["Risk", "stress-status-risk"];
    return `<tr><td>${region}</td><td>${product}</td><td>€${revenue}k</td><td>${margin}%</td><td>${growth > 0 ? "+" : ""}${growth}%</td><td class="${status[1]}">${status[0]}</td></tr>`;
  }).join("");
}

function incidentRows(seed) {
  return Array.from({ length: 9 }, (_, index) => {
    const severity = (seed + index) % 4 === 0 ? ["High", "stress-status-risk"] : (seed + index) % 3 === 0 ? ["Medium", "stress-status-watch"] : ["Low", "stress-status-good"];
    const owner = owners[(seed + index) % owners.length];
    return `<tr><td>INC-${2400 + seed * 9 + index}</td><td>${products[(seed + index) % products.length]}</td><td class="${severity[1]}">${severity[0]}</td><td>${owner}</td><td>${18 + ((seed * 7 + index * 13) % 160)} min</td><td>${index % 2 === 0 ? "Resolved" : "Monitoring"}</td></tr>`;
  }).join("");
}

function pageHeader(pageNumber, title, subtitle) {
  return `<header class="stress-header"><table><tr><td><p class="stress-kicker">Northstar enterprise intelligence</p><h1 class="stress-title">${title}</h1><p class="stress-subtitle">${subtitle}</p></td><td class="stress-page-number">PAGE ${String(pageNumber).padStart(2, "0")} / ${STRESS_REPORT_PAGE_COUNT}</td></tr></table></header>`;
}

function pageFooter(pageNumber, section) {
  return `<footer class="stress-footer"><table><tr><td>Confidential - Northstar consolidated operating review</td><td>${section} - ${String(pageNumber).padStart(2, "0")}</td></tr></table></footer>`;
}

function kpiTable(seed) {
  const values = [
    ["NET REVENUE", `€${(4.2 + (seed % 9) * .37).toFixed(2)}M`, `+${8 + seed % 17}.4% YoY`, "stress-positive"],
    ["GROSS MARGIN", `${58 + seed % 12}.2%`, `+${1 + seed % 4}.1 pts`, "stress-positive"],
    ["ACTIVE ACCOUNTS", `${24 + seed % 18},${String(120 + seed * 17).padStart(3, "0")}`, `+${5 + seed % 12}.8%`, "stress-positive"],
    ["RISK EXPOSURE", `${2 + seed % 6}.7%`, `+${seed % 4}.2 pts`, "stress-negative"],
  ];
  return `<table class="stress-kpis"><tr>${values.map(([label, value, delta, deltaClass]) => `<td><span class="stress-kpi-label">${label}</span><br><span class="stress-kpi-value">${value}</span><br><span class="${deltaClass}">${delta}</span></td>`).join("")}</tr></table>`;
}

function dashboardPage(pageNumber) {
  const seed = pageNumber - 1;
  return `<section class="stress-page">${pageHeader(pageNumber, `Executive dashboard ${pageNumber - 1}`, "Consolidated performance, forward indicators, and management actions")}
    ${kpiTable(seed)}
    <h2 class="stress-section-title">Ten-month performance trajectory</h2>
    <div class="stress-chart">${lineChartSvg(seed, `${regions[seed % regions.length]} revenue index`)}</div>
    <table class="stress-columns"><tr><td><div class="stress-card"><h3>Management interpretation</h3><p>Demand remains broad-based across enterprise and mid-market accounts. Expansion revenue offset a measured slowdown in new-logo conversion.</p><ul><li>Protect renewal coverage above 92%.</li><li>Move capacity toward the highest-margin programs.</li><li>Review exposure weekly.</li></ul></div></td><td><div class="stress-card"><h3>Decision register</h3><table class="stress-data"><tbody><tr><td>Pricing review</td><td class="stress-status-good">Approved</td></tr><tr><td>Capacity plan</td><td class="stress-status-watch">In review</td></tr><tr><td>Risk reserve</td><td class="stress-status-risk">Escalated</td></tr></tbody></table></div></td></tr></table>
    ${pageFooter(pageNumber, "Executive dashboard")}</section>`;
}

function marketPage(pageNumber) {
  const seed = pageNumber - 1;
  return `<section class="stress-page">${pageHeader(pageNumber, `${regions[seed % regions.length]} market report`, "Revenue, product mix, conversion, margin, and commercial outlook")}
    <div class="stress-chart">${barChartSvg(seed, "Segment revenue and contribution margin")}</div>
    <h2 class="stress-section-title">Regional performance matrix</h2>
    <table class="stress-data"><thead><tr><th>Region</th><th>Product</th><th>Revenue</th><th>Margin</th><th>Growth</th><th>Signal</th></tr></thead><tbody>${dataRows(seed)}</tbody></table>
    <p class="stress-callout"><strong>Commercial signal:</strong> Enterprise expansion remains the most efficient growth lever. Local teams should pair renewal activity with product adoption workshops and margin guardrails.</p>
    <table class="stress-columns"><tr><td><div class="stress-card"><h3>Upside case</h3><p>Stronger partner activation could add 4.2 points of annual growth without increasing acquisition cost.</p></div></td><td><div class="stress-card"><h3>Downside case</h3><p>Currency pressure and delayed procurement cycles could move €0.6M into the following quarter.</p></div></td></tr></table>
    ${pageFooter(pageNumber, "Market performance")}</section>`;
}

function operationsPage(pageNumber) {
  const seed = pageNumber - 1;
  return `<section class="stress-page">${pageHeader(pageNumber, `Operations and reliability review`, `Control cycle ${pageNumber - 1}: throughput, incidents, ownership, and remediation`)}
    ${kpiTable(seed)}
    <h2 class="stress-section-title">Automated control flow</h2>
    <div class="stress-chart">${processDiagramSvg(seed)}</div>
    <h2 class="stress-section-title">Incident response register</h2>
    <table class="stress-data"><thead><tr><th>ID</th><th>Service</th><th>Severity</th><th>Owner</th><th>Response</th><th>Status</th></tr></thead><tbody>${incidentRows(seed)}</tbody></table>
    <p class="stress-callout stress-warning"><strong>Required action:</strong> Complete the replica failover rehearsal and close high-severity corrective actions before the next traffic event.</p>
    ${pageFooter(pageNumber, "Operations")}</section>`;
}

function portfolioPage(pageNumber) {
  const seed = pageNumber - 1;
  return `<section class="stress-page">${pageHeader(pageNumber, `Portfolio and product intelligence`, "Allocation, adoption, customer outcomes, and investment choices")}
    <table class="stress-columns"><tr><td><div class="stress-chart">${ringChartSvg(seed)}</div></td><td><div class="stress-card"><h3>Investment thesis</h3><p>Core platform work protects reliability and gross margin. Growth allocation focuses on automation, analytics, and identity workflows with proven expansion demand.</p><ul><li>Fund common platform primitives.</li><li>Retire low-adoption variants.</li><li>Measure outcome realization.</li></ul></div></td></tr></table>
    <h2 class="stress-section-title">Product scorecard</h2>
    <table class="stress-data"><thead><tr><th>Product</th><th>ARR</th><th>Adoption</th><th>NPS</th><th>Reliability</th><th>Owner</th></tr></thead><tbody>${Array.from({ length: 9 }, (_, index) => `<tr><td>${products[(seed + index) % products.length]}</td><td>€${220 + ((seed * 41 + index * 67) % 790)}k</td><td>${48 + ((seed + index * 9) % 49)}%</td><td>${31 + ((seed * 3 + index * 5) % 38)}</td><td>${99 + ((seed + index) % 9) / 100}%</td><td>${owners[(seed + index) % owners.length]}</td></tr>`).join("")}</tbody></table>
    <h2 class="stress-section-title">Adoption trend</h2>
    <div class="stress-chart">${lineChartSvg(seed + 30, "Weekly active teams")}</div>
    ${pageFooter(pageNumber, "Portfolio")}</section>`;
}

function financePage(pageNumber) {
  const seed = pageNumber - 1;
  return `<section class="stress-page">${pageHeader(pageNumber, `Financial control and scenario report`, "Plan, actuals, cash profile, risk sensitivity, and forecast confidence")}
    ${kpiTable(seed)}
    <table class="stress-columns"><tr><td><div class="stress-chart">${barChartSvg(seed + 20, "Plan versus actual")}</div></td><td><div class="stress-card"><h3>Forecast bridge</h3><table class="stress-data"><tbody><tr><td>Opening forecast</td><td>€5.42M</td></tr><tr><td>Volume</td><td class="stress-status-good">+€0.38M</td></tr><tr><td>Mix</td><td class="stress-status-good">+€0.14M</td></tr><tr><td>FX impact</td><td class="stress-status-risk">-€0.21M</td></tr><tr><td>Closing forecast</td><td><strong>€5.73M</strong></td></tr></tbody></table></div></td></tr></table>
    <h2 class="stress-section-title">Cost center detail</h2>
    <table class="stress-data"><thead><tr><th>Cost center</th><th>Budget</th><th>Actual</th><th>Variance</th><th>Run rate</th><th>Owner</th></tr></thead><tbody>${Array.from({ length: 10 }, (_, index) => { const budget = 140 + ((seed * 31 + index * 43) % 520); const variance = -12 + ((seed * 7 + index * 5) % 31); return `<tr><td>${owners[(seed + index) % owners.length]} ${index + 1}</td><td>€${budget}k</td><td>€${Math.round(budget * (1 + variance / 100))}k</td><td class="${variance > 8 ? "stress-status-risk" : variance < 0 ? "stress-status-good" : "stress-status-watch"}">${variance > 0 ? "+" : ""}${variance}%</td><td>€${Math.round(budget / 12)}k/mo</td><td>${owners[(seed + index + 2) % owners.length]}</td></tr>`; }).join("")}</tbody></table>
    <p class="stress-callout"><strong>Finance recommendation:</strong> Preserve the contingency reserve until renewal concentration falls below the policy threshold.</p>
    ${pageFooter(pageNumber, "Finance")}</section>`;
}

function coverPage() {
  return `<section class="stress-page stress-cover"><p class="stress-kicker">2026 enterprise operating review</p><h1 class="stress-title">Northstar consolidated intelligence report</h1><p class="stress-subtitle">A 30-page benchmark document combining selectable text, dense tables, vector charts, process diagrams, financial reports, and technical drawings.</p>
    <div class="stress-cover-art"><svg viewBox="0 0 640 260" role="img" aria-label="Abstract enterprise network drawing"><rect width="640" height="260" rx="24" fill="#163354"/><path d="M72 174 C160 42 266 222 354 91 S520 52 586 154" fill="none" stroke="#38bdf8" stroke-width="8"/><circle cx="72" cy="174" r="17" fill="#38bdf8"/><circle cx="226" cy="139" r="17" fill="#67e8f9"/><circle cx="354" cy="91" r="17" fill="#2dd4bf"/><circle cx="484" cy="82" r="17" fill="#14b8a6"/><circle cx="586" cy="154" r="17" fill="#0d9488"/><path d="M92 213 H548" stroke="#476581" stroke-width="1"/><text x="92" y="238" font-size="12" fill="#cbd5e1">Growth</text><text x="286" y="238" font-size="12" fill="#cbd5e1">Operations</text><text x="493" y="238" font-size="12" fill="#cbd5e1">Outcomes</text></svg></div>
    <p class="stress-cover-note">Prepared for renderer performance and structural PDF verification - deterministic fixture - A4 portrait</p><p class="stress-page-number">PAGE 01 / ${STRESS_REPORT_PAGE_COUNT}</p></section>`;
}

function methodologyPage() {
  return `<section class="stress-page">${pageHeader(30, "Methodology, controls, and data lineage", "Definitions, reconciliation policy, refresh cadence, and document coverage")}
    <p class="stress-copy">This deterministic benchmark combines representative enterprise reporting structures without external network resources. Every chart is inline SVG, every table is native HTML, and all narrative content remains available for PDF text extraction.</p>
    ${["Revenue and margin", "Customer activity", "Operational reliability", "Portfolio adoption", "Risk and forecast"].map((title, index) => `<div class="stress-method"><strong>${index + 1}. ${title}</strong><br>Source systems are reconciled to the management ledger, normalized to the reporting currency, and checked against completeness, freshness, and ownership controls.</div>`).join("")}
    <h2 class="stress-section-title">Coverage inventory</h2>
    <table class="stress-data"><thead><tr><th>Content</th><th>Representation</th><th>Expected PDF model</th><th>Verification</th></tr></thead><tbody><tr><td>Narrative and labels</td><td>HTML and SVG text</td><td>Selectable text</td><td>PDF.js extraction</td></tr><tr><td>Charts and drawings</td><td>Inline SVG paths and shapes</td><td>Vector Form XObjects</td><td>Operator inspection</td></tr><tr><td>Dense reports</td><td>HTML tables</td><td>Native lines and text</td><td>Page and text checks</td></tr><tr><td>Pagination</td><td>Explicit page breaks</td><td>Exactly 30 A4 pages</td><td>PDF.js page count</td></tr></tbody></table>
    <p class="stress-callout"><strong>Benchmark contract:</strong> both engines receive the same source and page profile. Rendering ends when final PDF bytes are available; classification and downloads occur afterward.</p>
    ${pageFooter(30, "Methodology")}</section>`;
}

const patternedPages = Array.from({ length: STRESS_REPORT_PAGE_COUNT - 2 }, (_, index) => {
  const pageNumber = index + 2;
  switch (index % 5) {
    case 0: return dashboardPage(pageNumber);
    case 1: return marketPage(pageNumber);
    case 2: return operationsPage(pageNumber);
    case 3: return portfolioPage(pageNumber);
    default: return financePage(pageNumber);
  }
});

export const stressReportPagesHtml = `${coverPage()}${patternedPages.join("")}${methodologyPage()}`;

export const thirtyPageStressReportHtml = `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"></head>
<body><main class="stress-report-root"><style>${stressReportStyles}</style>${stressReportPagesHtml}</main></body>
</html>`;
