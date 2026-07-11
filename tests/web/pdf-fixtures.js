export const complexInvoiceHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    body { color:#172033; font-family:"Noto Sans",sans-serif; font-size:12px; }
    .header { background:#13213c; color:#ffffff; padding:24px; }
    .header-title { font-size:30px; font-weight:bold; margin:0 0 8px; }
    .header-subtitle { color:#b9c7e3; margin:0; }
    .meta { border-collapse:collapse; margin:24px 0; width:100%; }
    .meta td { border-bottom:1px solid #d8e0eb; padding:10px; width:50%; }
    .label { color:#64748b; font-size:10px; font-weight:bold; }
    .items { border-collapse:collapse; width:100%; }
    .items th { background:#1d4ed8; border:1px solid #1d4ed8; color:#ffffff; padding:10px; text-align:left; }
    .items td { border:1px solid #dbe3ee; padding:10px; }
    .alt td { background:#f4f7fb; }
    .amount { text-align:right; }
    .summary { border-collapse:collapse; margin:18px 0 0; width:100%; }
    .summary td { padding:8px 10px; }
    .summary-label { color:#52606d; text-align:right; width:78%; }
    .summary-value { text-align:right; }
    .grand-total td { background:#dcfce7; border-top:2px solid #16a34a; color:#14532d; font-size:15px; font-weight:bold; }
    .note { background:#eff6ff; border-left:4px solid #2563eb; margin-top:24px; padding:14px; }
    .terms-page { break-before:page; }
    .section-title { color:#1e3a8a; font-size:22px; margin:0 0 14px; }
    .schedule { border-collapse:collapse; width:100%; }
    .schedule th { background:#dbeafe; border:1px solid #93c5fd; color:#1e3a8a; padding:10px; text-align:left; }
    .schedule td { border:1px solid #bfdbfe; padding:10px; }
    .status-paid { background:#dcfce7; color:#166534; font-weight:bold; }
    .status-due { background:#fef3c7; color:#92400e; font-weight:bold; }
    .legal { color:#64748b; font-size:10px; line-height:1.6; margin-top:24px; }
  </style>
</head>
<body>
  <div class="header">
    <p class="header-title">Northstar Studio - Invoice</p>
    <p class="header-subtitle">Product design and engineering engagement</p>
  </div>
  <table class="meta">
    <tr>
      <td><span class="label">BILLED TO</span><br><strong>Acme Industries Ltd.</strong><br>42 Market Street<br>London EC2A 4BX</td>
      <td><span class="label">INVOICE</span><br><strong>NS-2026-041</strong><br><span class="label">ISSUED</span><br>11 July 2026</td>
    </tr>
  </table>
  <table class="items">
    <thead><tr><th>Description</th><th>Qty</th><th>Rate</th><th class="amount">Amount</th></tr></thead>
    <tbody>
      <tr><td>Discovery and product strategy</td><td>24 h</td><td>€120</td><td class="amount">€2,880</td></tr>
      <tr class="alt"><td>Design system architecture</td><td>36 h</td><td>€120</td><td class="amount">€4,320</td></tr>
      <tr><td>Dashboard UX and interaction design</td><td>42 h</td><td>€120</td><td class="amount">€5,040</td></tr>
      <tr class="alt"><td>Frontend implementation</td><td>80 h</td><td>€135</td><td class="amount">€10,800</td></tr>
      <tr><td>Accessibility audit and remediation</td><td>18 h</td><td>€125</td><td class="amount">€2,250</td></tr>
      <tr class="alt"><td>Performance profiling</td><td>16 h</td><td>€135</td><td class="amount">€2,160</td></tr>
      <tr><td>Cross-browser QA</td><td>20 h</td><td>€110</td><td class="amount">€2,200</td></tr>
      <tr class="alt"><td>Release documentation</td><td>10 h</td><td>€95</td><td class="amount">€950</td></tr>
    </tbody>
  </table>
  <table class="summary">
    <tr><td class="summary-label">Subtotal</td><td class="summary-value">€30,600</td></tr>
    <tr><td class="summary-label">Service credit</td><td class="summary-value">- €1,500</td></tr>
    <tr><td class="summary-label">VAT 20%</td><td class="summary-value">€5,820</td></tr>
    <tr class="grand-total"><td class="summary-label">Total due</td><td class="summary-value">€34,920</td></tr>
  </table>
  <p class="note"><strong>Payment reference:</strong> NS-2026-041. Please use the invoice number in the bank transfer description.</p>

  <div class="terms-page">
    <h1 class="section-title">Payment schedule and terms</h1>
    <table class="schedule">
      <thead><tr><th>Milestone</th><th>Due date</th><th>Amount</th><th>Status</th></tr></thead>
      <tbody>
        <tr><td>Project commencement</td><td>15 May 2026</td><td>€10,000</td><td class="status-paid">Paid</td></tr>
        <tr><td>Design approval</td><td>20 June 2026</td><td>€10,000</td><td class="status-paid">Paid</td></tr>
        <tr><td>Production delivery</td><td>25 July 2026</td><td>€14,920</td><td class="status-due">Due</td></tr>
      </tbody>
    </table>
    <div class="legal">
      <p><strong>Bank details:</strong> Example Bank PLC - IBAN GB12 EXAM 1234 5678 9012 34 - SWIFT EXAMGB2L.</p>
      <p>Payment is due within 14 calendar days. Late balances may incur interest at the statutory commercial rate. Deliverables remain licensed for evaluation until the final balance has cleared.</p>
      <p>Questions regarding this invoice can be sent to billing@northstar.example. Thank you for choosing Northstar Studio.</p>
    </div>
  </div>
</body>
</html>`;

export const analyticsReportHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    body { color:#172033; font-family:"Noto Sans",sans-serif; font-size:11px; }
    .cover { background:#10243e; color:#ffffff; padding:30px; }
    .eyebrow { color:#7dd3fc; font-size:10px; font-weight:bold; letter-spacing:1px; }
    .title { font-size:30px; margin:8px 0; }
    .subtitle { color:#cbd5e1; font-size:14px; }
    .kpis { border-collapse:collapse; margin:24px 0; width:100%; }
    .kpis td { border:1px solid #dbe3ee; padding:14px; width:25%; }
    .kpi-label { color:#64748b; font-size:9px; font-weight:bold; }
    .kpi-value { color:#0f172a; font-size:21px; font-weight:bold; }
    .positive { color:#15803d; }
    .negative { color:#be123c; }
    .section-title { color:#1e3a8a; font-size:20px; margin:22px 0 10px; }
    .chart-shell { background:#f8fafc; border:1px solid #dbe3ee; padding:14px; }
    .data { border-collapse:collapse; margin-top:16px; width:100%; }
    .data th { background:#1e3a8a; border:1px solid #1e3a8a; color:#ffffff; padding:9px; text-align:left; }
    .data td { border:1px solid #dbe3ee; padding:9px; }
    .row-good td { background:#f0fdf4; }
    .row-watch td { background:#fffbeb; }
    .page-break { break-before:page; }
    .insight { background:#ecfeff; border-left:4px solid #0891b2; padding:12px; }
    .appendix { color:#475569; font-size:10px; line-height:1.6; }
  </style>
</head>
<body>
  <div class="cover">
    <p class="eyebrow">QUARTERLY BUSINESS REVIEW</p>
    <h1 class="title">Northstar Commerce Analytics</h1>
    <p class="subtitle">Executive performance report - Q2 2026</p>
  </div>
  <table class="kpis">
    <tr>
      <td><span class="kpi-label">NET REVENUE</span><br><span class="kpi-value">€4.82M</span><br><span class="positive">+18.4% YoY</span></td>
      <td><span class="kpi-label">GROSS MARGIN</span><br><span class="kpi-value">64.2%</span><br><span class="positive">+3.1 pts</span></td>
      <td><span class="kpi-label">ACTIVE CUSTOMERS</span><br><span class="kpi-value">28,640</span><br><span class="positive">+11.8%</span></td>
      <td><span class="kpi-label">CHURN</span><br><span class="kpi-value">2.7%</span><br><span class="negative">+0.3 pts</span></td>
    </tr>
  </table>
  <h2 class="section-title">Revenue trend</h2>
  <div class="chart-shell">
    <svg width="680" height="250" viewBox="0 0 680 250" aria-label="Quarterly revenue bar chart">
      <rect width="680" height="250" fill="#f8fafc"/>
      <line x1="58" y1="210" x2="650" y2="210" stroke="#94a3b8" stroke-width="1"/>
      <line x1="58" y1="40" x2="58" y2="210" stroke="#94a3b8" stroke-width="1"/>
      <rect x="95" y="128" width="72" height="82" fill="#93c5fd"/>
      <rect x="215" y="108" width="72" height="102" fill="#60a5fa"/>
      <rect x="335" y="84" width="72" height="126" fill="#3b82f6"/>
      <rect x="455" y="52" width="72" height="158" fill="#1d4ed8"/>
      <text x="112" y="232" font-size="13" fill="#475569">Q3 25</text>
      <text x="232" y="232" font-size="13" fill="#475569">Q4 25</text>
      <text x="352" y="232" font-size="13" fill="#475569">Q1 26</text>
      <text x="472" y="232" font-size="13" fill="#475569">Q2 26</text>
      <text x="106" y="116" font-size="13" fill="#1e3a8a">€3.42M</text>
      <text x="226" y="96" font-size="13" fill="#1e3a8a">€3.77M</text>
      <text x="346" y="72" font-size="13" fill="#1e3a8a">€4.11M</text>
      <text x="466" y="40" font-size="13" fill="#1e3a8a">€4.82M</text>
    </svg>
  </div>
  <p class="insight"><strong>Executive insight:</strong> Revenue acceleration was driven by enterprise expansion and a 9% increase in average order value.</p>

  <div class="page-break">
    <h1 class="section-title">Regional performance</h1>
    <table class="data">
      <thead><tr><th>Region</th><th>Revenue</th><th>YoY growth</th><th>Gross margin</th><th>Signal</th></tr></thead>
      <tbody>
        <tr class="row-good"><td>United Kingdom</td><td>€1.54M</td><td>+22.6%</td><td>66.8%</td><td>Strong</td></tr>
        <tr class="row-good"><td>DACH</td><td>€1.21M</td><td>+19.4%</td><td>65.1%</td><td>Strong</td></tr>
        <tr><td>France</td><td>€0.86M</td><td>+13.2%</td><td>62.7%</td><td>Stable</td></tr>
        <tr class="row-watch"><td>Southern Europe</td><td>€0.71M</td><td>+8.1%</td><td>59.9%</td><td>Watch</td></tr>
        <tr><td>Nordics</td><td>€0.50M</td><td>+16.7%</td><td>64.5%</td><td>Stable</td></tr>
      </tbody>
    </table>
    <h2 class="section-title">Customer mix</h2>
    <div class="chart-shell">
      <svg width="680" height="220" viewBox="0 0 680 220" aria-label="Customer segment stacked bar chart">
        <rect width="680" height="220" fill="#f8fafc"/>
        <rect x="70" y="58" width="270" height="64" fill="#1d4ed8"/>
        <rect x="340" y="58" width="190" height="64" fill="#0ea5e9"/>
        <rect x="530" y="58" width="90" height="64" fill="#67e8f9"/>
        <text x="165" y="95" font-size="16" fill="#ffffff">Enterprise 45%</text>
        <text x="365" y="95" font-size="16" fill="#ffffff">Mid-market 32%</text>
        <text x="542" y="95" font-size="14" fill="#164e63">SMB 15%</text>
        <text x="70" y="160" font-size="13" fill="#475569">Enterprise expansion revenue increased 28% quarter over quarter.</text>
        <text x="70" y="185" font-size="13" fill="#475569">Remaining 8%: partners and marketplace channels.</text>
      </svg>
    </div>
  </div>

  <div class="page-break appendix">
    <h1 class="section-title">Appendix and methodology</h1>
    <p><strong>Revenue recognition:</strong> Net revenue excludes VAT, refunds, marketplace fees, and promotional credits. Subscription revenue is recognized daily over the contracted service period.</p>
    <p><strong>Customer definitions:</strong> Active customers completed at least one paid transaction during the trailing 90-day period. Churn represents customers becoming inactive during the quarter divided by active customers at quarter start.</p>
    <p><strong>Data quality:</strong> Figures reconcile to the management ledger as of 8 July 2026. Currency conversion uses the European Central Bank monthly average rate for each transaction month.</p>
    <table class="data">
      <thead><tr><th>Metric</th><th>Source</th><th>Refresh cadence</th><th>Owner</th></tr></thead>
      <tbody>
        <tr><td>Revenue and margin</td><td>Finance warehouse</td><td>Daily</td><td>Finance Operations</td></tr>
        <tr><td>Customer activity</td><td>Product analytics</td><td>Hourly</td><td>Data Platform</td></tr>
        <tr><td>Regional attribution</td><td>Billing profile</td><td>Daily</td><td>Commercial Analytics</td></tr>
      </tbody>
    </table>
  </div>
</body>
</html>`;

export const roundedOperationsReportHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    body { color:#172033; font-family:"Noto Sans",sans-serif; font-size:11px; }
    .hero { background:#0f2f4f; border:2px solid #0f2f4f; border-radius:20px; color:#ffffff; padding:24px; }
    .eyebrow { color:#7dd3fc; font-size:9px; font-weight:bold; letter-spacing:1px; margin:0; }
    .hero-title { font-size:28px; margin:7px 0; }
    .hero-copy { color:#dbeafe; margin:0; }
    .kpis { border-collapse:separate; margin:20px 0; width:100%; }
    .kpis td { background:#eff6ff; border:1px solid #bfdbfe; border-radius:12px; padding:12px; width:25%; }
    .kpi-label { color:#64748b; font-size:8px; font-weight:bold; letter-spacing:0.8px; }
    .kpi-value { color:#0f172a; font-size:19px; font-weight:bold; }
    .positive { color:#15803d; font-weight:bold; }
    .section-title { color:#153e75; font-size:19px; margin:20px 0 9px; }
    .table-shell { background:#f8fafc; border:2px solid #cbd5e1; border-radius:18px; padding:7px; }
    .rounded-table { border-collapse:separate; width:100%; }
    .rounded-table th { background:#1d4ed8; border:1px solid #1d4ed8; border-radius:8px; color:#ffffff; padding:9px; text-align:left; }
    .rounded-table td { background:#ffffff; border:1px solid #dbe3ee; border-radius:8px; padding:9px; }
    .good { background:#dcfce7; border:1px solid #86efac; border-radius:10px; color:#166534; font-weight:bold; padding:6px; }
    .watch { background:#fef3c7; border:1px solid #fcd34d; border-radius:10px; color:#92400e; font-weight:bold; padding:6px; }
    .risk { background:#ffe4e6; border:1px solid #fda4af; border-radius:10px; color:#9f1239; font-weight:bold; padding:6px; }
    .callout { background:#ecfeff; border:2px solid #67e8f9; border-radius:16px; margin-top:18px; padding:14px; }
    .page-break { break-before:page; }
    .detail-title { color:#0f2f4f; font-size:24px; margin:0 0 5px; }
    .detail-copy { color:#64748b; margin:0 0 18px; }
    .owner { color:#475569; font-size:10px; }
  </style>
</head>
<body>
  <div class="hero">
    <p class="eyebrow">OPERATIONS CONTROL ROOM</p>
    <h1 class="hero-title">Service delivery health</h1>
    <p class="hero-copy">Rounded tables and status surfaces rendered as native PDF curves.</p>
  </div>

  <table class="kpis"><tr>
    <td><span class="kpi-label">SLA COMPLIANCE</span><br><span class="kpi-value">98.7%</span><br><span class="positive">+1.2 pts</span></td>
    <td><span class="kpi-label">OPEN INCIDENTS</span><br><span class="kpi-value">14</span><br>3 high priority</td>
    <td><span class="kpi-label">AVG RESPONSE</span><br><span class="kpi-value">7m 42s</span><br><span class="positive">-18%</span></td>
    <td><span class="kpi-label">DEPLOY SUCCESS</span><br><span class="kpi-value">96.4%</span><br>1 rollback</td>
  </tr></table>

  <h2 class="section-title">Regional service matrix</h2>
  <div class="table-shell">
    <table class="rounded-table">
      <thead><tr><th>Region</th><th>Availability</th><th>Latency</th><th>Incidents</th><th>Signal</th></tr></thead>
      <tbody>
        <tr><td>Western Europe</td><td>99.98%</td><td>84 ms</td><td>2</td><td><span class="good">Healthy</span></td></tr>
        <tr><td>North America</td><td>99.95%</td><td>112 ms</td><td>4</td><td><span class="good">Healthy</span></td></tr>
        <tr><td>Asia Pacific</td><td>99.72%</td><td>186 ms</td><td>6</td><td><span class="watch">Watch</span></td></tr>
        <tr><td>South America</td><td>98.91%</td><td>241 ms</td><td>2</td><td><span class="risk">At risk</span></td></tr>
      </tbody>
    </table>
  </div>
  <div class="callout"><strong>Executive action:</strong> Add one edge location in Sao Paulo and complete the APAC database replica migration before the next traffic peak.</div>

  <div class="page-break">
    <h1 class="detail-title">Incident response register</h1>
    <p class="detail-copy">Detailed ownership, customer impact, and next-action tracking.</p>
    <div class="table-shell">
      <table class="rounded-table">
        <thead><tr><th>ID</th><th>Service</th><th>Impact</th><th>Owner</th><th>Status</th></tr></thead>
        <tbody>
          <tr><td>INC-2407</td><td>Checkout API</td><td>Elevated p95 latency</td><td>Payments</td><td><span class="watch">Monitoring</span></td></tr>
          <tr><td>INC-2411</td><td>Search index</td><td>7% stale results</td><td>Discovery</td><td><span class="good">Resolved</span></td></tr>
          <tr><td>INC-2414</td><td>Webhook relay</td><td>Delivery delay</td><td>Platform</td><td><span class="risk">Investigating</span></td></tr>
          <tr><td>INC-2418</td><td>Analytics export</td><td>Partial CSV output</td><td>Data</td><td><span class="good">Resolved</span></td></tr>
          <tr><td>INC-2420</td><td>Identity sync</td><td>Slow provisioning</td><td>Identity</td><td><span class="watch">Mitigated</span></td></tr>
        </tbody>
      </table>
    </div>
    <h2 class="section-title">Follow-up owners</h2>
    <table class="kpis"><tr>
      <td><span class="kpi-label">PLATFORM</span><br><span class="kpi-value">3</span><br><span class="owner">Actions due</span></td>
      <td><span class="kpi-label">PAYMENTS</span><br><span class="kpi-value">2</span><br><span class="owner">Actions due</span></td>
      <td><span class="kpi-label">DATA</span><br><span class="kpi-value">1</span><br><span class="owner">Action due</span></td>
      <td><span class="kpi-label">IDENTITY</span><br><span class="kpi-value">1</span><br><span class="owner">Action due</span></td>
    </tr></table>
  </div>
</body>
</html>`;

export const presentationDeckHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    body { color:#14213d; font-family:"Noto Sans",sans-serif; font-size:14px; }
    .slide { background:#f8fafc; border:2px solid #dbe3ee; border-radius:24px; box-sizing:border-box; height:680px; padding:34px; break-after:page; }
    .slide-last { break-after:auto; }
    .slide-dark { background:#10243e; border-color:#10243e; color:#ffffff; }
    .eyebrow { color:#38bdf8; font-size:11px; font-weight:bold; letter-spacing:1.2px; margin:0; }
    .cover-title { font-size:46px; line-height:1.05; margin:68px 0 18px; }
    .cover-copy { color:#cbd5e1; font-size:18px; line-height:1.5; width:720px; }
    .cover-chip { background:#164e63; border:1px solid #22d3ee; border-radius:16px; color:#cffafe; display:inline-block; margin-top:46px; padding:10px 16px; }
    .slide-number { color:#94a3b8; font-size:10px; margin-top:72px; text-align:right; }
    .slide-title { color:#0f2f4f; font-size:30px; margin:4px 0 8px; }
    .slide-subtitle { color:#64748b; margin:0 0 22px; }
    .metric-table, .columns, .compare, .roadmap { border-collapse:separate; width:100%; }
    .metric-table td { background:#ffffff; border:2px solid #dbeafe; border-radius:16px; padding:18px; width:25%; }
    .metric-label { color:#64748b; font-size:9px; font-weight:bold; letter-spacing:0.8px; }
    .metric-value { color:#0f172a; font-size:27px; font-weight:bold; }
    .up { color:#15803d; font-weight:bold; }
    .down { color:#be123c; font-weight:bold; }
    .columns { margin-top:22px; }
    .columns td { vertical-align:top; width:50%; }
    .card { background:#ffffff; border:2px solid #dbe3ee; border-radius:18px; padding:18px; }
    .card-blue { background:#eff6ff; border-color:#93c5fd; }
    .card-cyan { background:#ecfeff; border-color:#67e8f9; }
    .card h2 { color:#153e75; font-size:20px; margin:0 0 10px; }
    .bar-label { color:#475569; font-size:11px; margin:10px 0 4px; }
    .bar-track { background:#e2e8f0; border:1px solid #cbd5e1; border-radius:9px; height:18px; padding:2px; }
    .bar-92 { background:#2563eb; border-radius:6px; height:12px; width:92%; }
    .bar-76 { background:#0ea5e9; border-radius:6px; height:12px; width:76%; }
    .bar-61 { background:#14b8a6; border-radius:6px; height:12px; width:61%; }
    .compare th { background:#1e3a8a; border:1px solid #1e3a8a; border-radius:10px; color:#ffffff; padding:11px; text-align:left; }
    .compare td { background:#ffffff; border:1px solid #dbe3ee; border-radius:10px; padding:11px; }
    .winner { background:#dcfce7; border:1px solid #86efac; border-radius:8px; color:#166534; font-weight:bold; padding:5px; }
    .roadmap td { background:#ffffff; border:2px solid #dbe3ee; border-radius:16px; padding:15px; width:25%; }
    .phase { color:#2563eb; font-size:10px; font-weight:bold; }
    .phase-title { color:#0f172a; font-size:17px; font-weight:bold; margin:6px 0; }
    .closing { background:#dbeafe; border:2px solid #60a5fa; border-radius:22px; margin-top:26px; padding:24px; text-align:center; }
    .closing strong { color:#1e3a8a; font-size:24px; }
  </style>
</head>
<body>
  <section class="slide slide-dark">
    <p class="eyebrow">NORTHSTAR PRODUCT STRATEGY</p>
    <h1 class="cover-title">From operational data<br>to confident decisions</h1>
    <p class="cover-copy">A four-slide landscape PDF that behaves like a presentation deck while preserving selectable text, vector surfaces, and live links.</p>
    <span class="cover-chip">Executive review - Q3 2026</span>
    <p class="slide-number">01 / 04</p>
  </section>

  <section class="slide">
    <p class="eyebrow">PERFORMANCE SNAPSHOT</p>
    <h1 class="slide-title">Momentum is strong and broad-based</h1>
    <p class="slide-subtitle">Commercial efficiency improved across every core acquisition channel.</p>
    <table class="metric-table"><tr>
      <td><span class="metric-label">ARR</span><br><span class="metric-value">€12.8M</span><br><span class="up">+24% YoY</span></td>
      <td><span class="metric-label">NET RETENTION</span><br><span class="metric-value">118%</span><br><span class="up">+6 pts</span></td>
      <td><span class="metric-label">PIPELINE</span><br><span class="metric-value">€6.4M</span><br><span class="up">+31%</span></td>
      <td><span class="metric-label">CHURN</span><br><span class="metric-value">2.1%</span><br><span class="down">-0.5 pts</span></td>
    </tr></table>
    <table class="columns"><tr>
      <td><div class="card card-blue"><h2>Execution confidence</h2><p class="bar-label">Product roadmap</p><div class="bar-track"><div class="bar-92"></div></div><p class="bar-label">Enterprise readiness</p><div class="bar-track"><div class="bar-76"></div></div><p class="bar-label">International rollout</p><div class="bar-track"><div class="bar-61"></div></div></div></td>
      <td><div class="card card-cyan"><h2>What changed</h2><p><strong>1.</strong> Sales cycle shortened by 12 days.</p><p><strong>2.</strong> Expansion revenue reached 42% of new ARR.</p><p><strong>3.</strong> Support response improved by 18%.</p></div></td>
    </tr></table>
    <p class="slide-number">02 / 04</p>
  </section>

  <section class="slide">
    <p class="eyebrow">STRATEGIC CHOICE</p>
    <h1 class="slide-title">Prioritize the enterprise workflow</h1>
    <p class="slide-subtitle">The opportunity scores highest on revenue quality, defensibility, and customer pull.</p>
    <table class="compare">
      <thead><tr><th>Dimension</th><th>Enterprise workflow</th><th>SMB automation</th><th>Marketplace</th></tr></thead>
      <tbody>
        <tr><td>12-month revenue</td><td>€4.8M</td><td>€2.1M</td><td>€1.7M</td></tr>
        <tr><td>Gross margin</td><td>72%</td><td>68%</td><td>54%</td></tr>
        <tr><td>Customer evidence</td><td><span class="winner">Strong</span></td><td>Moderate</td><td>Early</td></tr>
        <tr><td>Defensibility</td><td><span class="winner">High</span></td><td>Medium</td><td>Low</td></tr>
        <tr><td>Recommendation</td><td><span class="winner">Invest now</span></td><td>Maintain</td><td>Explore</td></tr>
      </tbody>
    </table>
    <div class="closing"><strong>Decision:</strong> allocate 60% of incremental product capacity to enterprise workflow depth.</div>
    <p class="slide-number">03 / 04</p>
  </section>

  <section class="slide slide-last">
    <p class="eyebrow">90-DAY PLAN</p>
    <h1 class="slide-title">Move from decision to measurable delivery</h1>
    <p class="slide-subtitle">Four phases, one accountable outcome: five enterprise design partners live by October.</p>
    <table class="roadmap"><tr>
      <td><span class="phase">WEEKS 1-2</span><p class="phase-title">Align</p><p>Confirm scope, success metrics, and design partners.</p></td>
      <td><span class="phase">WEEKS 3-5</span><p class="phase-title">Prototype</p><p>Validate permissions, audit logs, and approval flows.</p></td>
      <td><span class="phase">WEEKS 6-9</span><p class="phase-title">Build</p><p>Ship the core workflow behind controlled rollout flags.</p></td>
      <td><span class="phase">WEEKS 10-13</span><p class="phase-title">Scale</p><p>Measure adoption and prepare general availability.</p></td>
    </tr></table>
    <div class="closing"><strong>Northstar outcome:</strong><br>€1.2M qualified expansion pipeline influenced by the first release.</div>
    <p class="slide-number">04 / 04</p>
  </section>
</body>
</html>`;
