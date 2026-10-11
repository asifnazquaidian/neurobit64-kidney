// Long runs of the software model: what the chip reports in every condition.
// node summary.js   -> design/results/model_summary.txt and .json
'use strict';
const fs = require('fs'), path = require('path');
const C = require('./nb64_common.js'), M = require('./nb64_kidney_model.js');
const rows = [], L = ['NeuroBit64-Kidney, software model', '', 'A. All conditions, 16.4 s of model time (values of the last 256-tick epoch; flags over the last 12 s)', '',
  'cond  condition                            brain chip  working  filtration %  per nephron Hz  renin %  flags raised (% of reports)'];
for (const link of [0, 1]) for (let cond = 0; cond < 8; cond++) {
  const nb = link ? new C.NeuroBit64S({ lif: 1, leak: 2, tsel: 4 }) : null;
  const c = new M.Chip({ cond, link, nb }); c.run(16384);
  const fr = c.frames.slice(256), share = (bit) => Math.round(100 * fr.filter((p) => (p[2] >> bit) & 1).length / fr.length);
  const r = { condition: cond, name: c.K.name, brain_chip: link ? 'connected' : 'none', working_nephrons: c.active, filtration_percent: c.gfr,
    per_nephron_hz: c.active ? +(c.rate / c.active / 0.256).toFixed(1) : 0, renin_percent: Math.round((c.rlev >> 4) / 2.55),
    flags_percent_of_reports: Object.fromEntries(M.FLAGS.slice(0, 7).map((n, i) => [n, share(i)]).filter(([, v]) => v > 0)), abnormal_percent: share(7) };
  rows.push(r);
  L.push(`${cond}     ${r.name.padEnd(35)}  ${r.brain_chip.padEnd(10)}  ${String(r.working_nephrons).padStart(7)}  ${String(r.filtration_percent).padStart(11)}  ${String(r.per_nephron_hz).padStart(14)}  ${String(r.renin_percent).padStart(7)}  ${Object.entries(r.flags_percent_of_reports).map(([k, v]) => `${k} ${v}`).join(', ') || 'none'}`);
}
L.push('', 'B. Healthy kidney at fixed perfusion pressure (8.2 s each)', '', 'pressure mmHg  filtration %  per nephron Hz  renin %');
const resp = [];
for (const P of [50, 60, 70, 80, 90, 100, 110, 120, 140, 160, 180, 200]) {
  const c = new M.Chip({ cond: 0, keepFrames: false }); c.setPressure(P); c.pin = P; c.run(8192);
  const r = { pressure: P, filtration_percent: c.gfr, per_nephron_hz: +(c.rate / c.active / 0.256).toFixed(1), renin_percent: Math.round((c.rlev >> 4) / 2.55) };
  resp.push(r); L.push(`${String(P).padStart(9)}      ${String(r.filtration_percent).padStart(8)}  ${String(r.per_nephron_hz).padStart(14)}  ${String(r.renin_percent).padStart(7)}`);
}
const out = path.join(__dirname, '..', 'results');
fs.writeFileSync(path.join(out, 'model_summary.json'), JSON.stringify({ conditions: rows, pressure_response: resp }, null, 2));
fs.writeFileSync(path.join(out, 'model_summary.txt'), L.join('\n') + '\n'); console.log(L.join('\n'));
