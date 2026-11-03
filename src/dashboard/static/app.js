/* Telco Churn Analytics: a small SPA, data comes from /api/* (the mart views). */
(() => {
  'use strict';

  const PAGES = {
    explore: { title: 'Churn explorer', crumb: 'Analysis', render: renderExplore, fit: true },
    whatif: { title: 'What-if Scenario', crumb: 'Analysis', render: renderWhatif, fit: true },
    quality: { title: 'Data Quality', crumb: 'Operations', render: renderQuality },
  };

  const state = { page: null, cache: {}, charts: {}, meta: null };

  /* ---------- helpers ---------- */
  const nf = (d) => new Intl.NumberFormat('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });
  const fmt = {
    int: (v) => nf(0).format(v),
    usd: (v) => '$' + nf(0).format(v),
    usd2: (v) => '$' + nf(2).format(v),
    usdK: (v) => '$' + nf(1).format(v / 1000) + 'K',
    pct: (v, d = 1) => nf(d).format(v * 100) + '%',
    pp: (v, d = 2) => (v >= 0 ? '+' : '-') + nf(d).format(Math.abs(v * 100)) + ' pts',
    num: (v, d = 2) => nf(d).format(v),
  };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const $ = (sel, root = document) => root.querySelector(sel);
  const sum = (arr, f) => arr.reduce((a, r) => a + f(r), 0);
  const ICON = {
    up: '<svg viewBox="0 0 24 24"><path d="M12 19V5m-6 6 6-6 6 6" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    down: '<svg viewBox="0 0 24 24"><path d="M12 5v14m6-6-6 6-6-6" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    bulb: '<svg viewBox="0 0 24 24" width="18" height="18"><path d="M9 18h6m-5 3h4M12 3a6 6 0 0 0-3.5 10.9c.6.4 1 1.1 1 1.8V16h5v-.3c0-.7.4-1.4 1-1.8A6 6 0 0 0 12 3z" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    download: '<svg viewBox="0 0 24 24" width="15" height="15"><path d="M12 4v11m-5-5 5 5 5-5M5 20h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  };

  async function api(name, params) {
    const key = name + (params ? JSON.stringify(params) : '');
    if (!state.cache[key]) {
      const qs = params ? '?' + new URLSearchParams(params) : '';
      state.cache[key] = fetch(`/api/${name}${qs}`).then((r) => {
        if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
        return r.json();
      }).catch((e) => { delete state.cache[key]; throw e; });
    }
    return state.cache[key];
  }

  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg; el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 2200);
  }

  function badge(kind, text, icon) {
    return `<span class="badge ${kind}">${icon ? ICON[icon] : ''}${esc(text)}</span>`;
  }

  function kpiCard(label, value, foot) {
    return `<div class="card kpi"><div class="kpi-label">${esc(label)}</div>
      <div class="kpi-value num">${value}</div><div class="kpi-foot">${foot || ''}</div></div>`;
  }

  function insight(title, bullets) {
    return `<div class="insight">${ICON.bulb}<div><b>${title}</b>
      ${bullets && bullets.length ? `<ul>${bullets.map((b) => `<li>${b}</li>`).join('')}</ul>` : ''}</div></div>`;
  }

  function cardHtml(id, title, sub, extraClass = '', right = '') {
    return `<div class="card"><div class="card-head"><div><h3 class="card-title" id="${id}-title">${title}</h3>
      <div class="card-sub">${sub}</div></div>${right}</div><div class="chart ${extraClass}" id="${id}"></div></div>`;
  }

  /* ---------- ECharts: shared style (light axes, thin grid, theme-aware tooltip) ---------- */
  function baseOption() {
    const text2 = css('--text-2'), text3 = css('--text-3'), border = css('--border');
    return {
      animationDuration: 350,
      textStyle: { fontFamily: 'Inter, system-ui, sans-serif', color: text2 },
      grid: { left: 8, right: 16, top: 36, bottom: 8, containLabel: true },
      tooltip: {
        trigger: 'axis', confine: true,
        backgroundColor: css('--surface'), borderColor: border, borderWidth: 1,
        textStyle: { color: css('--text'), fontSize: 12 },
        extraCssText: 'box-shadow:0 6px 18px rgba(0,0,0,.12);border-radius:8px;padding:8px 10px;',
        axisPointer: { type: 'line', lineStyle: { color: css('--border-strong') } },
      },
      legend: { top: 0, left: 0, icon: 'roundRect', itemWidth: 10, itemHeight: 10, textStyle: { color: text2, fontSize: 12 } },
      _axis: {
        axisLine: { lineStyle: { color: border } }, axisTick: { show: false },
        axisLabel: { color: text3, fontSize: 11 }, splitLine: { lineStyle: { color: border, type: [3, 3] } },
      },
    };
  }

  function axis(extra) { return Object.assign({}, baseOption()._axis, extra); }

  function mountChart(id, option) {
    const el = document.getElementById(id);
    if (!el) return null;
    if (state.charts[id]) state.charts[id].dispose();
    const chart = echarts.init(el, null, { renderer: 'svg' });
    const base = baseOption(); delete base._axis;
    chart.setOption(Object.assign(base, option));
    state.charts[id] = chart;
    return chart;
  }

  function disposeCharts() {
    Object.values(state.charts).forEach((c) => c.dispose());
    state.charts = {};
  }

  function tipRow(color, label, value) {
    return `<div style="display:flex;gap:10px;justify-content:space-between;align-items:center">
      <span style="display:flex;align-items:center;gap:6px">${color ? `<span style="width:8px;height:8px;border-radius:2px;background:${color}"></span>` : ''}${esc(label)}</span>
      <b style="font-variant-numeric:tabular-nums">${value}</b></div>`;
  }

  /* ---------- Explore page: fits one screen; details open on demand ---------- */
  const PRESETS = [
    { label: 'Whole company', filters: {} },
    { label: 'High-risk group', hint: 'month-to-month · Fiber · manual payment', filters: { contract: ['Month-to-month'], internet: ['Fiber optic'], payment_type: ['Manual'] } },
    { label: 'First-year customers', hint: 'tenure 0-12 months', filters: { tenure: ['0-12 months'] } },
    { label: 'Fiber customers', filters: { internet: ['Fiber optic'] } },
    { label: 'No add-on services', hint: 'has internet, 0 add-ons', filters: { addons: ['0'] } },
    { label: 'Long-term contracts', hint: 'one or two years', filters: { contract: ['One year', 'Two year'] } },
  ];
  const MAIN_FACTORS = ['contract', 'internet', 'tenure', 'addons', 'payment_type', 'tech_support'];
  const SHORT_LABEL = { contract: 'Contract', internet: 'Internet', tenure: 'Tenure', addons: 'Add-ons',
    payment_type: 'Payment', tech_support: 'Tech support' };
  const VALUE_LABEL = {
    'No internet service': 'No internet', 'No phone service': 'No phone', 'Fiber optic': 'Fiber',
    'Bank transfer (automatic)': 'Bank transfer (auto)', 'Credit card (automatic)': 'Credit card (auto)',
  };
  const MIN_GROUP = 30;          // options smaller than this swing too much: shown faded, not ranked
  const MIN_GROUP_SMALL = 5;     // if the selected group is tiny, lower the bar so there is still a hint, with a small-sample warning
  // A churner's tenure stops at the exit month while active customers keep ageing, so churn by tenure band
  // is biased towards short tenure. Tenure stays a filter but is not ranked; the retention curve answers "when".
  const RANK_EXCLUDED = ['tenure'];

  function valueLabel(factor, v) {
    if (factor === 'addons') return v === 'No internet service' ? 'No internet' : `${v} add-on${v === '1' ? '' : 's'}`;
    if (factor === 'internet' && v === 'No') return 'No internet';
    return VALUE_LABEL[v] || v;
  }

  const ex = { filters: {}, catalog: null, ctrl: null, timer: null, last: null, popFactor: null };
  const normalize = (f) => Object.keys(f).sort().reduce((o, k) => (o[k] = [...f[k]].sort(), o), {});

  function filtersFromHash() {
    const q = location.hash.split('?')[1];
    if (!q) return {};
    try { return JSON.parse(decodeURIComponent(new URLSearchParams(q).get('f') || '{}')); } catch (e) { return {}; }
  }
  function syncHash() {
    const target = '#explore' + (Object.keys(ex.filters).length ? '?f=' + encodeURIComponent(JSON.stringify(ex.filters)) : '');
    if (location.hash !== target) history.replaceState(null, '', target);
  }

  function toggleValue(factor, value) {
    const cur = new Set(ex.filters[factor] || []);
    cur.has(value) ? cur.delete(value) : cur.add(value);
    if (cur.size) ex.filters[factor] = [...cur]; else delete ex.filters[factor];
    onFiltersChanged();
  }

  function onFiltersChanged() {
    syncHash();
    drawFilterBar();
    if (ex.popFactor) drawPopover();
    clearTimeout(ex.timer);
    ex.timer = setTimeout(refreshExplore, 120);   // merge quick successive clicks into one request
  }

  async function renderExplore(root) {
    if (location.hash.includes('?')) ex.filters = filtersFromHash();
    syncHash();
    ex.catalog = ex.catalog || await api('factors');
    // Each chart answers exactly one question: line 1 is the question, line 2 the answer computed from the filtered data.
    const viz = (id, question, cls) => `<div class="card viz ${cls}"><div class="viz-head"><div class="viz-q">
      <h3 class="viz-title" id="${id}-title">${question}</h3><div class="viz-answer" id="${id}-hint"></div></div></div>
      <div class="chart fill" id="${id}"></div></div>`;
    root.innerHTML = `
      <div class="card filterbar">
        <select class="input select" id="exPreset" aria-label="Saved views"></select>
        <div class="pills" id="exPills"></div>
        <div class="spacer"></div>
        <button class="btn ghost no-print" id="exClear" type="button">Clear filters</button>
        <button class="btn primary no-print" id="exCustomers" type="button" title="Preview the customer list for these filters, then download CSV">${ICON.download}View &amp; download CSV</button>
      </div>
      <div class="narrative" id="exHeadline"></div>
      <div class="report">
        <div class="kpi-row" id="exKpis"></div>
        ${viz('ex-churn', 'Is the churn rate rising or falling?', 'v-trend')}
        ${viz('ex-mrr', 'Is recurring revenue on target?', 'v-mrr')}
        <div class="card viz v-factors">
          <div class="viz-head"><div class="viz-q"><h3 class="viz-title">Which factor makes the biggest difference?</h3>
            <div class="viz-answer" id="exTopAnswer"></div></div></div>
          <div class="active-filters" id="exActive"></div>
          <div class="top-factors" id="exTop"></div>
          <button class="btn block no-print" id="exAll" type="button">See every option of every factor</button>
        </div>
        ${viz('ex-contract', 'Which contract type churns most?', 'v-b1')}
        ${viz('ex-retention', 'When do new customers leave?', 'v-b2')}
        ${viz('ex-internet', 'Where do churned customers come from?', 'v-b3')}
      </div>`;
    ['ex-churn', 'ex-mrr', 'ex-contract', 'ex-retention', 'ex-internet'].forEach((id) => mountChart(id, {}));
    // Power BI-style cross-filtering: click a bar to filter on that value, click again to remove it.
    [['ex-contract', 'contract'], ['ex-internet', 'internet']].forEach(([id, key]) => {
      state.charts[id].on('click', (p) => { if (p.data && p.data.raw) toggleValue(key, p.data.raw); });
    });
    $('#exPreset').addEventListener('change', (e) => {
      if (e.target.value === '') return;
      ex.filters = JSON.parse(JSON.stringify(PRESETS[+e.target.value].filters));
      onFiltersChanged();
    });
    $('#exPills').addEventListener('click', (e) => {
      const rm = e.target.closest('[data-rm]');
      if (rm) { delete ex.filters[rm.dataset.rm]; onFiltersChanged(); return; }
      const b = e.target.closest('button[data-pop]');
      if (b) openPopover(b.dataset.pop, b);
    });
    $('#exClear').addEventListener('click', () => { ex.filters = {}; onFiltersChanged(); });
    // Always open the preview before downloading, so the user sees exactly which rows will be exported.
    $('#exCustomers').addEventListener('click', openCustomerList);
    $('#exAll').addEventListener('click', openAllFactors);
    const toggleFromEl = (e) => {
      const v = e.target.closest('[data-f]');
      if (v) toggleValue(v.dataset.f, v.dataset.v);
    };
    $('#exTop').addEventListener('click', toggleFromEl);
    $('#exActive').addEventListener('click', toggleFromEl);
    drawFilterBar();
    await refreshExplore();
  }

  function drawFilterBar() {
    const sel = $('#exPreset');
    if (!sel) return;
    const match = PRESETS.findIndex((p) => JSON.stringify(normalize(p.filters)) === JSON.stringify(normalize(ex.filters)));
    sel.innerHTML = `<option value="" ${match < 0 ? 'selected' : ''}>${match < 0 ? 'Custom filters' : 'Saved views'}</option>`
      + PRESETS.map((p, i) => `<option value="${i}" ${i === match ? 'selected' : ''} title="${esc(p.hint || '')}">${esc(p.label)}</option>`).join('');
    const pill = (key, label) => {
      const vals = ex.filters[key] || [];
      // One value shows its name, several show a count: buttons keep a stable width and the bar never scrolls.
      const text = vals.length === 1 ? valueLabel(key, vals[0]) : vals.length ? `${vals.length} selected` : '';
      const full = vals.map((v) => valueLabel(key, v)).join(', ');
      return `<span class="pill ${vals.length ? 'on' : ''}" title="${esc(full || 'All')}"><button type="button" data-pop="${key}" aria-haspopup="true">
        <span class="pill-k">${esc(label)}${text ? ':' : ''}</span> ${esc(text)} <span class="caret">▾</span></button>${vals.length ? `<button type="button" class="pill-x" data-rm="${key}" aria-label="Remove filter ${esc(label)}">✕</button>` : ''}</span>`;
    };
    const others = ex.catalog.filter((c) => !MAIN_FACTORS.includes(c.key));
    const otherActive = others.filter((c) => ex.filters[c.key]).length;
    $('#exPills').innerHTML = MAIN_FACTORS.map((k) => pill(k, SHORT_LABEL[k])).join('')
      + `<span class="pill ${otherActive ? 'on' : ''}"><button type="button" data-pop="__other" aria-haspopup="true"><span class="pill-k">More${otherActive ? ':' : ''}</span> ${otherActive ? `${otherActive} active` : ''} <span class="caret">▾</span></button></span>`;
  }

  /* Value picker popover: shows each option's churn rate in the current context. */
  function openPopover(key, anchor) {
    ex.popFactor = key;
    let pop = $('#popover');
    if (!pop) {
      pop = Object.assign(document.createElement('div'), { id: 'popover', className: 'popover' });
      document.body.appendChild(pop);
      pop.addEventListener('change', (e) => { const c = e.target.closest('input[data-f]'); if (c) toggleValue(c.dataset.f, c.dataset.v); });
      document.addEventListener('mousedown', (e) => { if (ex.popFactor && !pop.contains(e.target) && !e.target.closest('[data-pop]')) closePopover(); });
    }
    const r = anchor.getBoundingClientRect();
    pop.style.top = `${r.bottom + 6 + window.scrollY}px`;
    pop.style.left = `${Math.min(r.left + window.scrollX, window.innerWidth - 340)}px`;
    pop.classList.add('open');
    drawPopover();
  }
  function closePopover() { ex.popFactor = null; $('#popover')?.classList.remove('open'); }

  function drawPopover() {
    const pop = $('#popover');
    if (!pop || !ex.popFactor) return;
    const byKey = {};
    (ex.last?.breakdown || []).forEach((b) => ((byKey[b.factor_key] = byKey[b.factor_key] || {})[b.value] = b));
    const factors = ex.popFactor === '__other' ? ex.catalog.filter((c) => !MAIN_FACTORS.includes(c.key))
      : ex.catalog.filter((c) => c.key === ex.popFactor);
    pop.innerHTML = factors.map((f) => `<div class="pop-group"><div class="pop-title">${esc(f.label)}</div>
      ${f.values.map((v) => {
        const b = (byKey[f.key] || {})[v.value];
        const rate = b && b.customers ? b.churners / b.customers : null;
        const on = (ex.filters[f.key] || []).includes(v.value);
        return `<label class="pop-row"><input type="checkbox" data-f="${esc(f.key)}" data-v="${esc(v.value)}" ${on ? 'checked' : ''}>
          <span>${esc(valueLabel(f.key, v.value))}</span>
          <span class="muted num">${b ? fmt.int(b.customers) + ' customers' : '0 customers'}</span>
          <b class="num">${rate == null ? '–' : fmt.pct(rate)}</b></label>`;
      }).join('')}</div>`).join('') + '<div class="pop-foot muted">Right column: share churned within the 24-month window, given the other filters.</div>';
  }

  async function refreshExplore() {
    if (ex.ctrl) ex.ctrl.abort();
    ex.ctrl = new AbortController();
    $('#page-explore')?.classList.add('loading');
    try {
      const res = await fetch('/api/explore', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filters: ex.filters }), signal: ex.ctrl.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      ex.last = await res.json();
      drawExplore(ex.last);
      if (ex.popFactor) drawPopover();
    } catch (e) {
      if (e.name !== 'AbortError') { toast('Could not load data'); console.error(e); }
    } finally {
      $('#page-explore')?.classList.remove('loading');
    }
  }

  function factorImpacts(d, minGroup = MIN_GROUP) {
    const byFactor = {};
    d.breakdown.forEach((b) => (byFactor[b.factor_key] = byFactor[b.factor_key] || []).push(b));
    return ex.catalog.map((f) => {
      const rows = (byFactor[f.key] || []).slice().sort((a, b) => a.value_sort - b.value_sort)
        .map((r) => ({ ...r, rate: r.churners / r.customers }));
      // "No internet service" under internet-dependent factors only repeats the Internet factor, so it is not ranked.
      const big = rows.filter((r) => r.customers >= minGroup && !(f.key !== 'internet' && r.value === 'No internet service'))
        .sort((a, b) => b.rate - a.rate);
      return { f, rows, hi: big[0], lo: big[big.length - 1], spread: big.length >= 2 ? big[0].rate - big[big.length - 1].rate : 0 };
    }).sort((a, b) => b.spread - a.spread);
  }

  /* Small SVG sparkline for KPI cards: shows the trend shape only; the exact value is the big number. */
  function sparkline(values, color) {
    const v = values.map((x) => (x == null ? null : +x));
    const nums = v.filter((x) => x != null);
    if (nums.length < 2) return '';
    const min = Math.min(...nums), max = Math.max(...nums), span = max - min || 1;
    const W = 120, H = 34, pad = 3;
    const pts = v.map((x, i) => (x == null ? null : [(i / (v.length - 1)) * W, H - pad - ((x - min) / span) * (H - 2 * pad)]));
    const line = pts.filter(Boolean).map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');
    const first = pts.find(Boolean), last = [...pts].reverse().find(Boolean);
    return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true">
      <path d="${line} L${last[0].toFixed(1)},${H} L${first[0].toFixed(1)},${H} Z" fill="${color}" opacity=".12"/>
      <path d="${line}" fill="none" stroke="${color}" stroke-width="1.6" vector-effect="non-scaling-stroke"/>
      <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="2.4" fill="${color}"/></svg>`;
  }

  function kpiSpark(label, value, delta, foot, spark) {
    return `<div class="card kpi kpi-spark">
      <div class="kpi-top"><span class="kpi-label">${esc(label)}</span>${delta || ''}</div>
      <div class="kpi-mid"><span class="kpi-value num">${value}</span>${spark || ''}</div>
      <div class="kpi-foot">${foot || ''}</div></div>`;
  }

  function drawExplore(d) {
    const k = d.kpi;
    const filtered = Object.keys(ex.filters).length > 0;
    const selRate = k.sel_customers ? k.sel_churners / k.sel_customers : 0;
    const allRate = k.all_churners / k.all_customers;
    const selMonthly = k.sel_customer_months ? k.sel_churners / k.sel_customer_months : 0;
    const selMrr = k.sel_mrr || 0;
    const selLoss = selMrr * selMonthly;
    const lift = allRate ? selRate / allRate : 0;
    const rank = (min) => factorImpacts(d, min).filter((i) => i.spread > 0 && !(ex.filters[i.f.key] || []).length && !RANK_EXCLUDED.includes(i.f.key));
    let ranked = rank(MIN_GROUP);
    const smallSample = !ranked.length;
    if (smallSample) ranked = rank(MIN_GROUP_SMALL);
    const top = ranked[0];

    // One line summarising the group size; detailed answers live in each chart and are not repeated here.
    const who = filtered ? `Group of ${fmt.int(k.sel_customers)} customers` : 'Whole company';
    $('#exHeadline').innerHTML = `${ICON.bulb}<span>${who}: <b>${fmt.pct(selRate)}</b> churned within the 24-month window${filtered ? `, <b>${fmt.num(lift, lift >= 1 ? 1 : 2)}x</b> the overall rate (${fmt.pct(allRate)})` : ''}. <span class="muted">Cards: ${d.trend[d.trend.length - 1].year_month} vs the previous month.</span></span>`
      + (k.sel_customers < 100 ? badge('warn', 'small sample') : '');

    const t = d.trend, last = t[t.length - 1], prev = t[t.length - 2];
    const rate = (r) => (r.sel_customers ? r.sel_churners / r.sel_customers : null);
    const deltaBadge = (cur, before, { pp = false, upIsBad = false } = {}) => {
      if (cur == null || before == null || (!pp && !before)) return '';
      const diff = pp ? cur - before : cur / before - 1;
      const bad = upIsBad ? diff > 0 : diff < 0;
      const sign = diff >= 0 ? '+' : '−';
      const text = pp ? `${sign}${fmt.num(Math.abs(diff) * 100, 2)} pts` : `${sign}${fmt.pct(Math.abs(diff), 1)}`;
      const flat = Math.abs(diff) < (pp ? 0.00005 : 0.0005);   // below display rounding counts as unchanged
      return badge(flat ? 'neutral' : bad ? 'bad' : 'good', text, flat ? null : diff >= 0 ? 'up' : 'down');
    };
    /*
      Five cards, one template: value = latest month, badge = change vs the previous month (coloured by meaning:
      customers/MRR/ARPU up is good; churn rate/MRR lost up is bad), sparkline = 24 months of the same metric,
      footer = vs the whole company (when filtered) or vs target / average (whole company).
    */
    const s1 = css('--series-1'), crit = css('--critical'), s2 = css('--series-2');
    const arpu = (r) => (r.sel_customers ? r.sel_mrr / r.sel_customers : null);
    const allRateLast = last.all_customers ? last.all_churners / last.all_customers : 0;
    const avgSelRate = sum(t, (r) => r.sel_churners) / Math.max(1, sum(t, (r) => r.sel_customers));
    $('#exKpis').innerHTML = [
      kpiSpark('Customers', fmt.int(last.sel_customers), deltaBadge(last.sel_customers, prev.sel_customers),
        filtered ? `${fmt.pct(last.sel_customers / last.all_customers)} of all customers` : `24 months: ${fmt.int(k.all_customers)} billed customers`,
        sparkline(t.map((r) => r.sel_customers), s1)),
      kpiSpark('Churn rate (monthly)', rate(last) == null ? '–' : fmt.pct(rate(last), 2), deltaBadge(rate(last), rate(prev), { pp: true, upIsBad: true }),
        filtered ? `Company ${fmt.pct(allRateLast, 2)} · group avg ${fmt.pct(avgSelRate, 2)}` : `Target ${fmt.pct(last.churn_rate_target || 0, 2)} · avg ${fmt.pct(avgSelRate, 2)}`,
        sparkline(t.map(rate), crit)),
      kpiSpark('MRR', fmt.usd(last.sel_mrr), deltaBadge(last.sel_mrr, prev.sel_mrr),
        filtered ? `${fmt.pct(last.all_mrr ? last.sel_mrr / last.all_mrr : 0)} of company MRR` : `Target ${fmt.usd(last.mrr_target_usd || 0)}`,
        sparkline(t.map((r) => r.sel_mrr), s1)),
      kpiSpark('MRR lost to churn', fmt.usd(last.sel_mrr_lost), deltaBadge(last.sel_mrr_lost, prev.sel_mrr_lost, { upIsBad: true }),
        `Expected ${fmt.usd(selLoss)}/month · 24 months ${fmt.usd(sum(t, (r) => r.sel_mrr_lost))}`,
        sparkline(t.map((r) => r.sel_mrr_lost), s2)),
      kpiSpark('ARPU', arpu(last) == null ? '–' : fmt.usd2(arpu(last)), deltaBadge(arpu(last), arpu(prev)),
        filtered ? `Company ${fmt.usd2(last.all_customers ? last.all_mrr / last.all_customers : 0)}` : `Start of window ${fmt.usd2(arpu(t[0]) || 0)}`,
        sparkline(t.map(arpu), s1)),
    ].join('');

    // "Filtering" row inside the panel: remove a filter right here instead of finding its button in the bar.
    const active = Object.entries(ex.filters).flatMap(([f, vs]) => vs.map((v) => ({ f, v })));
    $('#exActive').innerHTML = active.length
      ? `<span class="muted">Filtering:</span>${active.map(({ f, v }) => `<button type="button" class="chip on" data-f="${esc(f)}" data-v="${esc(v)}"
          title="Remove filter ${esc(valueLabel(f, v))}">${esc(valueLabel(f, v))} ✕</button>`).join('')}`
      : '<span class="muted">Click a tile or a bar to filter; click again to remove.</span>';

    const opt = (i, r, kind) => `
      <button type="button" class="tf-opt ${kind}" data-f="${esc(i.f.key)}" data-v="${esc(r.value)}"
        title="Filter: ${esc(i.f.label)} = ${esc(valueLabel(i.f.key, r.value))}">
        <span class="tf-main"><span class="tf-name">${esc(valueLabel(i.f.key, r.value))}</span><b class="num">${fmt.pct(r.rate)}</b></span>
        <span class="tf-bar"><i style="width:${Math.max(2, 100 * r.rate).toFixed(1)}%"></i></span>
        <span class="tf-meta"><span class="num">${fmt.int(r.customers)} customers</span><span class="tf-add">＋ Filter</span></span>
      </button>`;
    $('#exTop').innerHTML = ranked.length ? (smallSample ? `<p class="tf-note">${badge('warn', 'Small sample')} Every option has fewer than ${MIN_GROUP} customers.</p>` : '')
      + '<div class="tf-cols"><span>▲ Churns most</span><span>▼ Churns least</span></div>' + ranked.map((i) => `
      <div class="tf">
        <div class="tf-head"><b>${esc(i.f.label)}</b><span class="tf-gap">gap ${fmt.num(i.spread * 100, 0)} pts</span></div>
        <div class="tf-opts">${opt(i, i.hi, 'hi')}${opt(i, i.lo, 'lo')}</div>
      </div>`).join('') : '<p class="muted">Group too small to split further. Remove a filter.</p>';
    $('#exTop').scrollTop = 0;
    $('#exTopAnswer').innerHTML = top
      ? `<b>${esc(top.f.label)}</b>: ${esc(valueLabel(top.f.key, top.hi.value))} ${fmt.pct(top.hi.rate)} vs ${esc(valueLabel(top.f.key, top.lo.value))} ${fmt.pct(top.lo.rate)}.`
      : 'Group too small to split further.';

    drawChurnChart(d, filtered);
    drawMrrChart(d, filtered);
    drawFactorBars(d, 'ex-contract', 'contract', allRate, 'h');
    drawRetention(d, filtered);
    drawChurnMixDonut(d, 'ex-internet', 'internet');
    resizeChartsSoon();
  }

  // Chart frames stretch to the remaining page height, so they must be re-measured after the content above has rendered.
  function resizeChartsSoon() { requestAnimationFrame(() => Object.values(state.charts).forEach((c) => c.resize())); }

  function drawChurnChart(d, filtered) {
    const chart = state.charts['ex-churn'];
    if (!chart) return;
    const s1 = css('--series-1'), muted = css('--text-3'), neutral = css('--neutral-mark');
    const months = d.trend.map((t) => t.year_month);
    const sel = d.trend.map((t) => (t.sel_customers ? t.sel_churners / t.sel_customers : null));
    const peakIdx = sel.reduce((bi, v, i) => (v != null && (bi < 0 || v > sel[bi]) ? i : bi), -1);
    const avgRate = sum(d.trend, (t) => t.sel_churners) / Math.max(1, sum(d.trend, (t) => t.sel_customers));
    const lastRate = sel[sel.length - 1];
    const mm = (m) => `${m.slice(5)}/${m.slice(0, 4)}`;
    // The event month comes from /api/meta (src/config.py); a peak up to two months later is attributed to it.
    const priceEvent = state.meta && state.meta.price_event_month;
    const monthNo = (m) => +m.slice(0, 4) * 12 + +m.slice(5, 7);
    const afterEvent = (m) => !!priceEvent && monthNo(m) >= monthNo(priceEvent) && monthNo(m) - monthNo(priceEvent) <= 2;
    $('#ex-churn-hint').innerHTML = peakIdx >= 0
      ? `Peak <b>${fmt.pct(sel[peakIdx], 1)}</b> (${mm(months[peakIdx])}${afterEvent(months[peakIdx]) ? ', after the Fiber price increase' : ''}); `
        + `latest month <b>${lastRate == null ? '–' : fmt.pct(lastRate, 1)}</b> vs an average of ${fmt.pct(avgRate, 1)}.`
      : '';
    const series = [{ name: filtered ? 'Selected group' : 'Whole company', type: 'line', data: sel, symbol: 'circle', symbolSize: 5, showSymbol: false,
      lineStyle: { width: 2.5, color: s1 }, itemStyle: { color: s1 },
      areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: s1 + '40' }, { offset: 1, color: s1 + '05' }]) },
      markLine: priceEvent ? { silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' },
        label: { formatter: 'Fiber price increase', color: muted, fontSize: 10, position: 'insideEndTop' }, data: [{ xAxis: priceEvent }] } : undefined,
      markPoint: peakIdx < 0 ? undefined : { symbol: 'circle', symbolSize: 8, itemStyle: { color: s1, borderColor: css('--surface'), borderWidth: 2 },
        label: { formatter: fmt.pct(sel[peakIdx], 1), position: 'top', color: css('--text'), fontSize: 11, fontWeight: 600 },
        data: [{ coord: [months[peakIdx], sel[peakIdx]] }] } }];
    series.push(filtered
      ? { name: 'Whole company', type: 'line', data: d.trend.map((t) => t.all_churners / t.all_customers), showSymbol: false,
          lineStyle: { width: 1.8, color: neutral }, itemStyle: { color: neutral } }
      : { name: 'Target', type: 'line', step: 'middle', data: d.trend.map((t) => t.churn_rate_target), showSymbol: false,
          lineStyle: { width: 1.8, type: 'dashed', color: muted }, itemStyle: { color: muted } });
    chart.setOption({
      legend: { ...baseOption().legend, top: 0, right: 0, left: 'auto', data: series.map((s) => s.name) },
      grid: { left: 4, right: 8, top: 26, bottom: 0, containLabel: true },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false, axisLabel: { ...axis().axisLabel, formatter: (v) => v.slice(2).replace('-', '/') } }),
      // Leave headroom so the peak label does not overlap the legend.
      yAxis: axis({ type: 'value', max: (v) => Math.ceil(v.max * 1.22 * 50) / 50, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, Math.round(v * 1000) % 10 ? 1 : 0) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const t = d.trend[ps[0].dataIndex];
        return `<b>${t.year_month}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? '–' : fmt.pct(p.value, 2))).join('')
          + (t.sel_customers ? tipRow(null, 'Churned / customers in group', `${fmt.int(t.sel_churners)}/${fmt.int(t.sel_customers)}`) : '');
      } },
      series,
    }, true);
  }

  function drawMrrChart(d, filtered) {
    const chart = state.charts['ex-mrr'];
    if (!chart) return;
    const s1 = css('--series-1'), muted = css('--text-3');
    const months = d.trend.map((t) => t.year_month);
    const lastMrr = d.trend[d.trend.length - 1].sel_mrr, firstMrr = d.trend[0].sel_mrr;
    const lastRow = d.trend[d.trend.length - 1];
    $('#ex-mrr-title').textContent = filtered ? 'How much revenue does this group bring?' : 'Is recurring revenue on target?';
    $('#ex-mrr-hint').innerHTML = filtered
      ? `<b>${fmt.usd(lastMrr)}</b>/month, ${fmt.pct(lastRow.all_mrr ? lastMrr / lastRow.all_mrr : 0)} of company MRR; ${firstMrr ? `${lastMrr >= firstMrr ? 'up' : 'down'} ${fmt.pct(Math.abs(lastMrr / firstMrr - 1), 1)} since the start of the window` : ''}.`
      : `On target in <b>${d.trend.filter((t) => t.sel_mrr >= t.mrr_target_usd).length}/${d.trend.length}</b> months; latest month ${lastMrr >= lastRow.mrr_target_usd ? 'above' : 'below'} target by <b>${fmt.pct(Math.abs(lastMrr / lastRow.mrr_target_usd - 1), 1)}</b>.`;
    const series = [{ name: 'MRR', type: 'bar', barMaxWidth: 14, data: d.trend.map((t) => t.sel_mrr),
      itemStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: s1 }, { offset: 1, color: s1 + '99' }]), borderRadius: [3, 3, 0, 0] } }];
    if (!filtered) series.push({ name: 'Target', type: 'line', data: d.trend.map((t) => t.mrr_target_usd), showSymbol: false,
      lineStyle: { width: 1.8, type: 'dashed', color: muted }, itemStyle: { color: muted } });
    chart.setOption({
      legend: { ...baseOption().legend, top: 0, right: 0, left: 'auto', data: series.map((s) => s.name) },
      grid: { left: 4, right: 8, top: 26, bottom: 0, containLabel: true },
      xAxis: axis({ type: 'category', data: months, axisLabel: { ...axis().axisLabel, formatter: (v) => v.slice(2).replace('-', '/') } }),
      yAxis: axis({ type: 'value', scale: !filtered, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.usdK(v) } }),
      tooltip: { ...baseOption().tooltip, axisPointer: { type: 'shadow' }, formatter: (ps) => {
        const t = d.trend[ps[0].dataIndex];
        return `<b>${t.year_month}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, fmt.usd(p.value))).join('')
          + tipRow(null, 'MRR lost to churn', fmt.usd(t.sel_mrr_lost));
      } },
      series,
    }, true);
  }

  /* Answer for a bar chart: the option that churns most vs least (only options large enough not to be noise). */
  function barAnswer(key, rows) {
    const withRate = rows.map((r) => ({ ...r, rate: r.churners / r.customers }));
    const big = withRate.filter((r) => r.customers >= MIN_GROUP);
    const pool = (big.length >= 2 ? big : withRate).slice().sort((a, b) => b.rate - a.rate);
    if (pool.length < 2) return 'Only one option left in the selected group.';
    const hi = pool[0], lo = pool[pool.length - 1];
    const name = (r) => esc(valueLabel(key, r.value));
    const ratio = lo.rate > 0 ? `, <b>${fmt.num(hi.rate / lo.rate, hi.rate / lo.rate >= 10 ? 0 : 1)}x</b> ${name(lo)} (${fmt.pct(lo.rate)})` : `, while ${name(lo)} barely churns`;
    return `<b>${name(hi)}</b> churned ${fmt.pct(hi.rate)}${ratio}.`;
  }

  /* Mix donut: where churned customers come from (complements the rate charts). Each internet type has a fixed colour. */
  function drawChurnMixDonut(d, id, key) {
    const chart = state.charts[id];
    if (!chart) return;
    const color = { 'Fiber optic': css('--series-1'), 'DSL': css('--series-2'), 'No': css('--series-3') };
    const rows = d.breakdown.filter((b) => b.factor_key === key).sort((a, b) => a.value_sort - b.value_sort);
    const total = sum(rows, (r) => r.churners);
    const chosen = ex.filters[key] || [];
    const top = rows.reduce((a, r) => (!a || r.churners > a.churners ? r : a), null);
    $(`#${id}-hint`).innerHTML = top && total
      ? `<b>${esc(valueLabel(key, top.value))}</b> accounts for <b>${fmt.pct(top.churners / total, 0)}</b> of churned customers (${fmt.int(top.churners)}/${fmt.int(total)}).`
      : 'No churned customers in this group.';
    chart.setOption({
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
        const r = p.data.row;
        return `<b>${esc(p.name)}</b>${tipRow(p.color, 'Churned customers', `${fmt.int(r.churners)} (${fmt.pct(p.percent / 100)})`)}
          ${tipRow(null, 'Churn rate', fmt.pct(r.churners / r.customers))}${tipRow(null, 'Customers', fmt.int(r.customers))}
          <div style="color:${css('--text-3')};margin-top:4px">${chosen.includes(p.data.raw) ? 'Click to remove filter' : 'Click to filter'}</div>`;
      } },
      legend: { show: false },
      graphic: [{ type: 'text', left: 'center', top: '40%', silent: true,
        style: { text: fmt.int(total), fill: css('--text'), font: '600 18px Inter, system-ui, sans-serif', textAlign: 'center' } },
        { type: 'text', left: 'center', top: '53%', silent: true,
        style: { text: 'churned', fill: css('--text-3'), font: '11px Inter, system-ui, sans-serif', textAlign: 'center' } }],
      series: [{ type: 'pie', radius: ['52%', '78%'], center: ['50%', '50%'], cursor: 'pointer', avoidLabelOverlap: true,
        itemStyle: { borderColor: css('--surface'), borderWidth: 2, borderRadius: 3 },
        label: { formatter: (p) => `${p.name}\n${fmt.pct(p.percent / 100, 0)}`, fontSize: 11, color: css('--text-2'), lineHeight: 14 },
        labelLine: { length: 6, length2: 6 },
        data: rows.filter((r) => r.churners > 0).map((r) => {
          const on = chosen.includes(r.value);
          return { name: valueLabel(key, r.value), value: r.churners, raw: r.value, row: r,
            itemStyle: { color: color[r.value], opacity: chosen.length && !on ? 0.3 : 1 } };
        }) }],
    }, true);
  }

  /*
    Retention curve: share of customers still billed k months after their first bill. Only cohorts that start
    inside the analysis window are used (older ones only contain survivors), and each point only counts customers
    who could be observed that long, so recent cohorts do not drag the curve down.
  */
  function drawRetention(d, filtered) {
    const chart = state.charts['ex-retention'];
    if (!chart) return;
    const s1 = css('--series-1'), neutral = css('--neutral-mark');
    const activeAt = Object.fromEntries(d.retention.map((r) => [r.k, r]));
    const maxK = Math.max(0, ...d.retention_base.map((b) => b.max_k));
    const curve = (activeKey, baseKey) => [...Array(maxK + 1).keys()].map((k) => {
      const base = sum(d.retention_base.filter((b) => b.max_k >= k), (b) => b[baseKey] || 0);
      return base >= MIN_GROUP ? ((activeAt[k] && activeAt[k][activeKey]) || 0) / base : null;
    });
    const sel = curve('sel_active', 'sel_customers');
    const all = curve('all_active', 'all_customers');
    const lastK = Math.max(0, all.reduce((last, v, k) => (v == null ? last : k), 0));
    const ks = [...Array(lastK + 1).keys()];
    $('#ex-retention-hint').innerHTML = sel[1] == null
      ? 'Too few customers in this group started in 2024-2025 to draw a curve.'
      : `<b>${fmt.pct(1 - sel[1], 0)}</b> are gone after the first bill`
        + (sel[12] == null ? '.' : `; <b>${fmt.pct(sel[12], 0)}</b> are still active after 12 months.`);
    const series = [{ name: filtered ? 'Selected group' : 'Whole company', type: 'line', data: ks.map((k) => sel[k]),
      showSymbol: false, lineStyle: { width: 2.5, color: s1 }, itemStyle: { color: s1 }, areaStyle: { color: s1 + '14' } }];
    if (filtered) series.push({ name: 'Whole company', type: 'line', data: ks.map((k) => all[k]), showSymbol: false,
      lineStyle: { width: 1.8, color: neutral }, itemStyle: { color: neutral } });
    chart.setOption({
      legend: { ...baseOption().legend, show: filtered, top: 0, right: 0, left: 'auto' },
      grid: { left: 4, right: 8, top: filtered ? 26 : 10, bottom: 18, containLabel: true },
      xAxis: axis({ type: 'category', data: ks, boundaryGap: false, name: 'Months since first bill', nameLocation: 'middle',
        nameGap: 22, nameTextStyle: { color: css('--text-3'), fontSize: 10 },
        axisLabel: { ...axis().axisLabel, interval: (i) => i % 6 === 0 } }),
      yAxis: axis({ type: 'value', min: 0, max: 1, interval: 0.25, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Month ${ps[0].axisValue}</b>`
        + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? '–' : fmt.pct(p.value, 1))).join('') },
      series,
    }, true);
  }

  /* Bar chart for one factor with cross-filtering: the selected value stays solid, others fade (like Power BI cross-highlight). */
  function drawFactorBars(d, id, key, allRate, orient) {
    const chart = state.charts[id];
    if (!chart) return;
    const rows = d.breakdown.filter((b) => b.factor_key === key).sort((a, b) => a.value_sort - b.value_sort);
    const chosen = ex.filters[key] || [];
    const s1 = css('--series-1'), neutral = css('--neutral-mark'), muted = css('--text-3');
    const cats = rows.map((r) => valueLabel(key, r.value));
    const data = rows.map((r) => {
      const on = chosen.includes(r.value);
      return { value: r.churners / r.customers, raw: r.value, row: r,
        itemStyle: { color: chosen.length && !on ? neutral : s1, opacity: chosen.length && !on ? 0.55 : 1,
          borderRadius: orient === 'h' ? [0, 4, 4, 0] : [4, 4, 0, 0] } };
    });
    $(`#${id}-hint`).innerHTML = barAnswer(key, rows);
    const valueAxis = axis({ type: 'value', max: (v) => Math.max(v.max * 1.18, allRate * 1.1),
      axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) }, splitNumber: 3 });
    const catAxis = axis({ type: 'category', data: cats, inverse: orient === 'h', axisLine: { show: false },
      axisLabel: { ...axis().axisLabel, color: css('--text-2'), fontSize: 11, interval: 0,
        formatter: (v) => (orient === 'v' ? v.replace(' months', '') : v) } });
    chart.setOption({
      grid: { left: orient === 'h' ? 14 : 4, right: orient === 'h' ? 40 : 8, top: orient === 'h' ? 4 : 18, bottom: 0, containLabel: true },
      xAxis: orient === 'h' ? { ...valueAxis, show: false } : catAxis,
      yAxis: orient === 'h' ? catAxis : { ...valueAxis, show: false },
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
        const r = p.data.row;
        return `<b>${esc(p.name)}</b>${tipRow(null, 'Churned', fmt.pct(p.value))}${tipRow(null, 'Customers', fmt.int(r.customers))}
          ${tipRow(null, 'Current MRR', fmt.usd(r.current_mrr || 0))}<div style="color:${muted};margin-top:4px">${chosen.includes(p.data.raw) ? 'Click to remove filter' : 'Click to filter'}</div>`;
      } },
      series: [{ type: 'bar', data, barMaxWidth: orient === 'h' ? 26 : 30, barCategoryGap: '35%', cursor: 'pointer',
        label: { show: true, position: orient === 'h' ? 'right' : 'top', fontSize: 11, color: css('--text-2'), formatter: (p) => fmt.pct(p.value, 0) },
        emphasis: { itemStyle: { color: css('--accent') } },
        markLine: { silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' },
          label: { show: false }, data: [orient === 'h' ? { xAxis: allRate } : { yAxis: allRate }] } }],
    }, true);
  }

  /* All 13 factors in detail: opened in a drawer so the main page stays compact. */
  function openAllFactors() {
    if (!ex.last) return;
    openDrawer('All 13 factors in the selected group', 'Share churned within the 24-month window for each option. Click a row to add it to the filters.');
    const selRate = ex.last.kpi.sel_customers ? ex.last.kpi.sel_churners / ex.last.kpi.sel_customers : 0;
    const body = $('#drawerBody');
    const draw = () => {
      body.innerHTML = `<div class="impact-grid">${factorImpacts(ex.last).map(({ f, rows, spread }) => {
        const maxRate = Math.max(0.01, ...rows.map((r) => r.rate));
        return `<div class="impact ${ex.filters[f.key] ? 'filtered' : ''}">
          <div class="impact-head"><b>${esc(f.label)}</b><span class="muted">${RANK_EXCLUDED.includes(f.key) ? 'not ranked: tenure stops at exit' : spread ? `gap ${fmt.num(spread * 100, 1)} pts` : '–'}</span></div>
          ${rows.map((r) => {
            const on = (ex.filters[f.key] || []).includes(r.value), tiny = r.customers < MIN_GROUP;
            return `<button type="button" class="impact-row ${on ? 'on' : ''} ${tiny ? 'tiny' : ''}" data-f="${esc(f.key)}" data-v="${esc(r.value)}">
              <span class="impact-name">${esc(valueLabel(f.key, r.value))}</span>
              <span class="impact-bar"><span style="width:${(100 * r.rate / maxRate).toFixed(1)}%" class="${r.rate > selRate * 1.2 && !tiny ? 'hot' : ''}"></span></span>
              <span class="impact-val num">${fmt.pct(r.rate)}</span>
              <span class="impact-n num">${tiny ? 'small' : fmt.int(r.customers)}</span></button>`;
          }).join('')}</div>`;
      }).join('')}</div>`;
    };
    body.onclick = (e) => {
      const r = e.target.closest('[data-f]');
      if (!r) return;
      toggleValue(r.dataset.f, r.dataset.v);
      closeDrawer();
    };
    draw();
  }

  function openDrawer(title, crumb) {
    $('#drawerTitle').textContent = title;
    $('#drawerCrumb').textContent = crumb || '';
    $('#drawerBody').onclick = null;
    $('#drawerBody').innerHTML = '<div class="skeleton"></div>';
    $('#drawer').classList.add('open'); $('#drawerBackdrop').classList.add('open');
    $('#drawer').setAttribute('aria-hidden', 'false');
  }

  async function openCustomerList() {
    openDrawer('Customer list preview', 'Check the list, narrow it further if needed, then download CSV');
    renderCustomerTable();
  }

  function filterSummary() {
    return Object.entries(ex.filters).map(([k, vs]) => {
      const f = ex.catalog.find((c) => c.key === k);
      return `${f.label}: ${vs.map((v) => valueLabel(k, v)).join(' or ')}`;
    }).join(' · ');
  }

  /* Download the server-built CSV, reusing the exact page filters (+ quick filters when called from the list). */
  async function downloadCustomersCsv(listParams = {}) {
    try {
      const res = await fetch('/api/explore/customers.csv', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filters: ex.filters, ...listParams }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const name = (res.headers.get('Content-Disposition') || '').match(/filename=([^;]+)/)?.[1] || 'customers_to_contact.csv';
      const url = URL.createObjectURL(await res.blob());
      const a = Object.assign(document.createElement('a'), { href: url, download: name });
      a.click(); URL.revokeObjectURL(url);
      toast(`Downloaded ${name}`);
    } catch (e) {
      toast('Could not download CSV'); console.error(e);
    }
  }

  /*
    Customer list: quick filters, search, sorting and paging all run in SQL (mart.usp_explore_customers);
    the browser only sends parameters via AJAX and receives exactly one page of 50 rows.
  */
  function renderCustomerTable() {
    const PAGE = 50;
    const cols = [
      ['customer_id', 'Customer ID', 's'], ['contract_type', 'Contract', 's'], ['internet_service', 'Internet', 's'],
      ['tenure_months', 'Tenure (mo)', 'n'], ['current_mrr_usd', 'Monthly charge', 'usd'], ['billing_tickets', 'Billing complaints', 'n'],
      ['late_payment_rate', 'Late payments', 'pct'], ['tech_support', 'Tech support', 's'], ['payment_method', 'Payment', 's'],
    ];
    const QUICK = [
      { key: 'mrr', label: 'High charge (top 25%)' }, { key: 'bill', label: 'Has billing complaints' },
      { key: 'late', label: 'Often late (≥ 20%)' }, { key: 'notech', label: 'No tech support' }, { key: 'new', label: 'First-year customers' },
    ];
    const st = { quick: new Set(), search: '', sort: 'current_mrr_usd', desc: true, page: 0, ctrl: null, timer: null, matched: 0 };
    const params = () => ({ quick: [...st.quick], search: st.search, sort: st.sort, desc: st.desc, page: st.page, page_size: PAGE });
    const context = Object.keys(ex.filters).length ? esc(filterSummary()) : 'Whole company';
    const body = $('#drawerBody');
    body.innerHTML = `
      <div class="cl-context">Page filters: <b>${context}</b> · <span id="clGroup">…</span></div>
      <div class="cl-quick" id="clQuick">${QUICK.map((q) => `<button type="button" class="chip" data-q="${q.key}" aria-pressed="false">${esc(q.label)}</button>`).join('')}</div>
      <div class="toolbar">
        <input class="input" id="custSearch" placeholder="Search customer ID..." aria-label="Search customer ID">
        <span class="muted" id="custCount"></span>
        <button class="btn primary" id="custExport" type="button" style="margin-left:auto">${ICON.download}Download CSV</button>
      </div>
      <div class="table-wrap cl-table"><table><thead><tr>${cols.map(([k, l, t]) => `<th class="sortable ${t === 's' ? '' : 'r'}" data-k="${k}">${l}<span class="sort-ind"></span></th>`).join('')}</tr></thead>
      <tbody id="custBody"><tr><td colspan="${cols.length}"><div class="skeleton" style="height:240px"></div></td></tr></tbody></table></div>
      <div class="cl-pager"><span class="muted" id="custRange"></span>
        <button class="btn" id="custPrev" type="button">‹ Previous</button><button class="btn" id="custNext" type="button">Next ›</button></div>`;
    const cell = (r, k, t) => (r[k] == null ? '–' : t === 'usd' ? fmt.usd2(r[k]) : t === 'pct' ? fmt.pct(r[k], 0) : t === 'n' ? fmt.int(r[k]) : esc(valueLabel('', r[k])));

    const load = async () => {
      if (st.ctrl) st.ctrl.abort();
      st.ctrl = new AbortController();
      body.classList.add('loading');
      try {
        const res = await fetch('/api/explore/customers', { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ filters: ex.filters, ...params() }), signal: st.ctrl.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const d = await res.json();
        st.matched = d.matched;
        $('#clGroup').textContent = `${fmt.int(d.group_total)} active customers`;
        body.querySelector('[data-q="mrr"]').textContent = `High charge (≥ ${fmt.usd(d.mrr_p75 || 0)})`;
        $('#custBody').innerHTML = d.rows.length
          ? d.rows.map((r) => `<tr>${cols.map(([k, , t]) => `<td class="${t === 's' ? '' : 'r num'}">${cell(r, k, t)}</td>`).join('')}</tr>`).join('')
          : `<tr><td colspan="${cols.length}" class="muted" style="text-align:center;padding:24px">No matching customers. Remove a quick filter.</td></tr>`;
        const pages = Math.max(1, Math.ceil(d.matched / PAGE));
        $('#custCount').textContent = `${fmt.int(d.matched)} / ${fmt.int(d.group_total)} customers match`;
        $('#custRange').textContent = d.matched ? `${fmt.int(st.page * PAGE + 1)}–${fmt.int(st.page * PAGE + d.rows.length)} / ${fmt.int(d.matched)} · page ${st.page + 1}/${pages}` : '';
        $('#custPrev').disabled = st.page === 0;
        $('#custNext').disabled = st.page >= pages - 1;
        $('#custExport').innerHTML = `${ICON.download}Download CSV (${fmt.int(d.matched)} customers)`;
        $('#custExport').disabled = !d.matched;
      } catch (e) {
        if (e.name !== 'AbortError') { $('#custBody').innerHTML = `<tr><td class="error">Could not load: ${esc(e.message)}</td></tr>`; }
      } finally {
        body.classList.remove('loading');
      }
      body.querySelectorAll('th.sortable').forEach((th) => {
        th.querySelector('.sort-ind').textContent = th.dataset.k === st.sort ? (st.desc ? ' ▼' : ' ▲') : '';
      });
      body.querySelectorAll('#clQuick .chip').forEach((c) => {
        const on = st.quick.has(c.dataset.q); c.classList.toggle('on', on); c.setAttribute('aria-pressed', on);
      });
    };

    $('#clQuick').addEventListener('click', (e) => {
      const c = e.target.closest('[data-q]');
      if (!c) return;
      st.quick.has(c.dataset.q) ? st.quick.delete(c.dataset.q) : st.quick.add(c.dataset.q);
      st.page = 0; load();
    });
    // Wait until the user has stopped typing for 250 ms before calling the server, instead of one request per key.
    $('#custSearch').addEventListener('input', (e) => {
      clearTimeout(st.timer);
      st.timer = setTimeout(() => { st.search = e.target.value.trim(); st.page = 0; load(); }, 250);
    });
    body.querySelectorAll('th.sortable').forEach((th) => th.addEventListener('click', () => {
      st.desc = st.sort === th.dataset.k ? !st.desc : true; st.sort = th.dataset.k; st.page = 0; load();
    }));
    $('#custPrev').addEventListener('click', () => { st.page -= 1; load(); });
    $('#custNext').addEventListener('click', () => { st.page += 1; load(); });
    $('#custExport').addEventListener('click', () => downloadCustomersCsv(params()));
    load();
  }

  function closeDrawer() {
    $('#drawer').classList.remove('open'); $('#drawerBackdrop').classList.remove('open');
    $('#drawer').setAttribute('aria-hidden', 'true');
  }

  /* ---------- What-if page: fits one screen ---------- */
  async function renderWhatif(root) {
    const base = await api('whatif_base');
    const m2m = base.find((b) => b.contract_type === 'Month-to-month');
    const oneY = base.find((b) => b.contract_type === 'One year');
    root.innerHTML = `
      <div class="headline" id="wfHeadline"></div>
      <div class="grid kpis4" id="wfKpis"></div>
      <div class="grid main-split">
        <div class="card flex-card">
          <div class="card-head"><div><h3 class="card-title">Customers left in the moved group</h3>
            <div class="card-sub">Blue: after moving to a one-year contract · Orange: if they stay month-to-month.</div></div></div>
          <div class="chart fill" id="c-whatif"></div>
        </div>
        <div class="card flex-card">
          <h3 class="card-title" style="margin-bottom:12px">Parameters</h3>
          <div class="control"><div class="control-row"><label for="shift">Month-to-month customers moved to one year</label><output id="shiftOut" class="num"></output></div>
            <input type="range" id="shift" min="0" max="50" step="5" value="20"></div>
          <div class="control"><div class="control-row"><label for="discount">Discount offered</label><output id="discountOut" class="num"></output></div>
            <input type="range" id="discount" min="0" max="30" step="1" value="10"></div>
          <div class="control"><div class="control-row"><label for="horizon">Horizon</label><output id="horizonOut" class="num"></output></div>
            <input type="range" id="horizon" min="6" max="24" step="6" value="12"></div>
          <p class="assumptions">Monthly churn: month-to-month ${fmt.pct(m2m.monthly_churn_rate, 2)}, one year ${fmt.pct(oneY.monthly_churn_rate, 2)}.
            ARPU ${fmt.usd2(m2m.arpu_usd)}. Based on a correlational gap between groups, so treat it as an upper bound.</p>
        </div>
      </div>`;

    const s1 = css('--series-1'), s2 = css('--series-2');
    const chart = mountChart('c-whatif', {});
    const update = () => {
      const pct = +$('#shift').value / 100, disc = +$('#discount').value / 100, H = +$('#horizon').value;
      $('#shiftOut').textContent = fmt.pct(pct, 0); $('#discountOut').textContent = fmt.pct(disc, 0); $('#horizonOut').textContent = `${H} months`;
      const moved = Math.round(m2m.active_customers * pct);
      const cM = m2m.monthly_churn_rate, c1 = oneY.monthly_churn_rate, arpu = m2m.arpu_usd;
      const ks = [...Array(H + 1).keys()];
      const stay = ks.map((k) => moved * Math.pow(1 - cM, k));
      const move = ks.map((k) => moved * Math.pow(1 - c1, k));
      let gross = 0, keptRevenue = 0;
      for (let k = 1; k <= H; k++) { gross += moved * arpu * (Math.pow(1 - c1, k) - Math.pow(1 - cM, k)); keptRevenue += moved * arpu * Math.pow(1 - c1, k); }
      const cost = disc * keptRevenue, net = gross - cost;
      const breakEven = keptRevenue ? gross / keptRevenue : 0;
      const extra = move[H] - stay[H];
      $('#wfHeadline').innerHTML = `${ICON.bulb}<span>${moved
        ? `Move <b>${fmt.int(moved)}</b> customers to a one-year contract with a ${fmt.pct(disc, 0)} discount: after ${H} months <b>${fmt.int(Math.round(extra))} more customers</b> stay, net benefit <b>${fmt.usd(net)}</b>. Break-even discount: ${fmt.pct(breakEven, 1)}.`
        : 'Move the sliders on the right to see a scenario.'}</span>`;
      $('#wfKpis').innerHTML = [
        kpiCard('Customers moved', fmt.int(moved), `of ${fmt.int(m2m.active_customers)} month-to-month customers`),
        kpiCard(`Extra MRR in month ${H}`, fmt.usd(extra * arpu), `${fmt.int(Math.round(extra))} more customers stay`),
        kpiCard(`Revenue kept (${H} months)`, fmt.usd(gross), `discount cost ${fmt.usd(cost)}`),
        kpiCard('Net benefit', fmt.usd(net), `${badge(net >= 0 ? 'good' : 'bad', net >= 0 ? 'Profitable' : 'Loss')} breaks even at a ${fmt.pct(breakEven, 1)} discount`),
      ].join('');
      chart.setOption({
        legend: { ...baseOption().legend, data: ['Moved to one year', 'Stayed month-to-month'] },
        grid: { left: 8, right: 16, top: 34, bottom: 24, containLabel: true },
        xAxis: axis({ type: 'category', data: ks, boundaryGap: false, name: 'Month', nameLocation: 'middle', nameGap: 24, nameTextStyle: { color: css('--text-3'), fontSize: 11 } }),
        yAxis: axis({ type: 'value', min: 0 }),
        tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Month ${ps[0].axisValue}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, fmt.num(p.value, 0) + ' customers')).join('') },
        series: [
          { name: 'Moved to one year', type: 'line', data: move, showSymbol: false, lineStyle: { width: 2.5, color: s1 }, itemStyle: { color: s1 }, areaStyle: { color: s1 + '14' } },
          { name: 'Stayed month-to-month', type: 'line', data: stay, showSymbol: false, lineStyle: { width: 2.5, color: s2 }, itemStyle: { color: s2 } },
        ],
      }, true);
    };
    ['shift', 'discount', 'horizon'].forEach((id) => $('#' + id).addEventListener('input', update));
    update();
    resizeChartsSoon();
  }

  /* ---------- Data Quality page: a reference page for the data team, so it may be long; the top still summarises ---------- */
  async function renderQuality(root) {
    const [checks, rejected, steps] = await Promise.all([api('dq_checks'), api('rejected'), api('etl_steps')]);
    const count = (s) => checks.filter((c) => c.status === s).length;
    const totalRejected = sum(rejected, (r) => r.rejected_rows);
    const pipeline = steps.find((s) => s.layer === 'pipeline');
    const groups = [...new Set(checks.map((c) => c.check_group))].sort();
    const fmtVal = (v) => (v == null ? '–' : fmt.num(v, Number.isInteger(v) ? 0 : 2));

    root.innerHTML = `
      <div class="headline">${ICON.bulb}<span><b>${count('PASS')}/${checks.length}</b> checks passed, <b>${count('FAIL')}</b> failures to fix.
        ${count('WARN') ? `${count('WARN')} warnings are the 2024-08 billing outage month, which was estimated.` : ''}
        ${fmt.int(totalRejected)} bad records were set aside with a reason, never silently deleted.</span></div>
      <div class="grid kpis4">
        ${kpiCard('Checks passed', `<span class="status PASS">${count('PASS')}</span>`, `of ${checks.length} checks`)}
        ${kpiCard('Warnings / Failures', `<span class="status WARN">${count('WARN')}</span> <span class="status FAIL">${count('FAIL')}</span>`, 'known warnings · failures to investigate')}
        ${kpiCard('Rejected records', fmt.int(totalRejected), `${rejected.length} reason types`)}
        ${kpiCard('Latest ETL run', pipeline ? fmt.num(pipeline.duration_ms / 1000, 0) + ' s' : '–',
          pipeline ? esc(new Date(pipeline.finished_at).toLocaleString('en-US')) : '')}
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Results of ${checks.length} checks</h3>
        <div class="card-sub">Before = measured on raw data (stg) · After = measured on cleaned data (clean/mart) · Rejected = rows moved to rejected</div></div></div>
        <div class="table-wrap" style="max-height:none"><table><thead><tr><th>Status</th><th>Check</th><th>Object</th>
          <th class="r">Before</th><th class="r">After</th><th class="r">Rejected</th><th>Note</th></tr></thead>
          <tbody>${groups.map((g) => `<tr><td colspan="7" style="background:var(--surface-2);font-weight:600">${esc(g)}</td></tr>` +
            checks.filter((c) => c.check_group === g).map((c) => `<tr><td><span class="status ${c.status}">${c.status}</span></td>
              <td class="wrap">${esc(c.check_name)}</td><td class="wrap muted">${esc(c.object_name || '')}</td>
              <td class="r num">${fmtVal(c.value_before)}</td><td class="r num">${fmtVal(c.value_after)}</td>
              <td class="r num">${fmtVal(c.value_rejected)}</td><td class="wrap muted">${esc(c.note || c.expected_rule || '')}</td></tr>`).join('')).join('')}
          </tbody></table></div></div>
      <div class="grid two">
        <div class="card"><div class="card-head"><div><h3 class="card-title">Rejected records by reason</h3>
          <div class="card-sub">Stored in clean.rejected_records with the original row (JSON)</div></div></div>
          <div class="table-wrap"><table><thead><tr><th>Source table</th><th>Reason</th><th class="r">Rows</th><th>Example</th></tr></thead>
            <tbody>${rejected.map((r) => `<tr><td>${esc(r.source_table)}</td><td>${esc(r.reason_code)}</td>
              <td class="r num">${fmt.int(r.rejected_rows)}</td><td class="wrap muted">${esc(r.sample_detail)}</td></tr>`).join('')}</tbody></table></div></div>
        <div class="card"><div class="card-head"><div><h3 class="card-title">ETL steps of the latest run</h3>
          <div class="card-sub">From dbo.etl_log</div></div></div>
          <div class="table-wrap"><table><thead><tr><th>Step</th><th>Status</th><th class="r">Read</th><th class="r">Written</th><th class="r">Duration</th></tr></thead>
            <tbody>${steps.filter((s) => s.layer !== 'pipeline').map((s) => `<tr><td>${esc(s.step_name)}</td>
              <td><span class="status ${s.status === 'SUCCESS' ? 'PASS' : 'FAIL'}">${esc(s.status)}</span></td>
              <td class="r num">${s.rows_read == null ? '–' : fmt.int(s.rows_read)}</td><td class="r num">${s.rows_written == null ? '–' : fmt.int(s.rows_written)}</td>
              <td class="r num">${fmt.num(s.duration_ms / 1000, 1)} s</td></tr>`).join('')}</tbody></table></div></div>
      </div>`;
  }

  /* ---------- navigation, theme, startup ---------- */
  async function show(page) {
    if (!PAGES[page]) page = 'explore';
    state.page = page;
    const def = PAGES[page];
    document.querySelectorAll('.nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === page));
    document.querySelectorAll('.page').forEach((p) => p.classList.toggle('active', p.id === 'page-' + page));
    $('#page-' + page).classList.toggle('fit', !!def.fit);
    $('#pageTitle').textContent = def.title; $('#crumb').textContent = def.crumb;
    document.title = `${def.title} · Telco Churn Analytics`;
    $('#sidebar').classList.remove('open');
    closeDrawer();
    closePopover();
    disposeCharts();
    const root = $('#page-' + page);
    root.innerHTML = '<div class="skeleton"></div>';
    try {
      await def.render(root);
    } catch (e) {
      root.innerHTML = `<div class="card error">Could not load data: ${esc(e.message)}. Check SQL Server and that python -m src.run_etl has been run.</div>`;
      console.error(e);
    }
  }

  async function loadMeta() {
    try {
      const m = await (await fetch('/api/meta')).json();
      state.meta = m;
      const etl = m.last_etl ? new Date(m.last_etl.finished_at).toLocaleString('en-US') : 'not run yet';
      $('#freshness').innerHTML = `Snapshot <b>${esc(m.snapshot_date)}</b><br>Latest ETL: <b>${esc(etl)}</b>`;
    } catch (e) {
      $('#freshness').textContent = 'Could not read ETL status';
    }
  }

  function setTheme(next) {
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('theme', next); } catch (e) { /* storage blocked by the browser: ignore, the theme still changes */ }
    show(state.page);
  }

  $('#themeToggle').addEventListener('click', () => {
    const cur = document.documentElement.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    setTheme(cur === 'dark' ? 'light' : 'dark');
  });
  $('#menuBtn').addEventListener('click', () => $('#sidebar').classList.toggle('open'));
  $('#drawerClose').addEventListener('click', closeDrawer);
  $('#drawerBackdrop').addEventListener('click', closeDrawer);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeDrawer(); closePopover(); } });
  // The Explore filters sit after the ? in the hash; only re-render when the page changes.
  const pageFromHash = () => location.hash.slice(1).split('?')[0];
  window.addEventListener('hashchange', () => { if (pageFromHash() !== state.page) show(pageFromHash()); });
  const resizeCharts = () => Object.values(state.charts).forEach((c) => c.resize());
  window.addEventListener('resize', resizeCharts);
  // When printing, the page frame changes size (sidebar hidden, A4), so charts must redraw to the new frame.
  window.addEventListener('beforeprint', resizeCharts);
  window.addEventListener('afterprint', resizeCharts);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => show(state.page));

  // The churn chart marks the price event from meta, so meta must arrive before the first render.
  loadMeta().finally(() => show(pageFromHash() || 'explore'));
})();
