export const REPORT360_FRAGMENTATION_PAGE = Object.freeze({
  width: 200,
  height: 120,
});

export const REPORT360_FRAGMENTATION_FIXTURE_HTML = `
  <style>
    .report360-regression, .report360-regression * { box-sizing: border-box; }
    .report360-regression { width: 200px; margin: 0; color: #172033; font-family: Noto Sans; font-size: 10px; line-height: 15px; }
    .report360-prefix { height: 35px; }
    .report360-legend { height: 15px; break-inside: avoid; break-after: avoid; }
    .report360-legend-items { display: flex; align-items: center; gap: 8px; }
    .report360-legend-item { display: inline-grid; grid-template-columns: 8px auto; align-items: center; column-gap: 4px; }
    .report360-legend-dot, .report360-status-dot { display: block; width: 8px; height: 8px; border-radius: 999px; }
    .report360-table-clip { overflow: hidden; border-radius: 6px; }
    .report360-table { width: 200px; border-collapse: collapse; }
    .report360-table thead tr { height: 20px; background: #47775c; color: #ffffff; }
    .report360-table th { padding: 2px 5px; text-align: left; }
    .report360-table td { height: auto; padding: 5px; }
    .report360-row-content { display: flex; min-height: 15px; align-items: center; }
    .report360-status { display: inline-flex; min-height: 15px; align-items: center; justify-content: center; }
    .report360-row-one { background: #e8eef5; }
    .report360-row-two { background: #f4eadf; }
    .report360-row-three { background: #e7f4ec; }
  </style>
  <div class="report360-prefix"></div>
  <section class="report360-legend">
    <div class="report360-legend-items">
      <span>LEGEND</span>
      <span class="report360-legend-item"><span class="report360-legend-dot" style="background:#20c56a"></span><span>Expressed</span></span>
      <span class="report360-status">N.R.</span>
    </div>
  </section>
  <div class="report360-table-clip">
    <table class="report360-table">
      <thead><tr><th>SUBDIMENSION</th><th style="width:50px">INDICATOR</th></tr></thead>
      <tbody>
        <tr class="report360-row-one"><td><div class="report360-row-content">ROW-1</div></td><td><span class="report360-status"><span class="report360-status-dot" style="background:#20c56a"></span></span></td></tr>
        <tr class="report360-row-two"><td><div class="report360-row-content">ROW-2</div></td><td><span class="report360-status">N.R.</span></td></tr>
        <tr class="report360-row-three"><td><div class="report360-row-content">ROW-3</div></td><td><span class="report360-status"><span class="report360-status-dot" style="background:#f0b400"></span></span></td></tr>
      </tbody>
    </table>
  </div>`;
