/* Telco Churn Analytics: SPA nhỏ, dữ liệu lấy từ /api/* (các view mart). */
(() => {
  'use strict';

  const PAGES = {
    explore: { title: 'Khám phá churn', crumb: 'Phân tích', render: renderExplore, fit: true },
    whatif: { title: 'What-if Scenario', crumb: 'Phân tích', render: renderWhatif, fit: true },
    quality: { title: 'Data Quality', crumb: 'Vận hành', render: renderQuality },
  };

  const state = { page: null, cache: {}, charts: {} };

  /* ---------- tiện ích ---------- */
  const nf = (d) => new Intl.NumberFormat('vi-VN', { minimumFractionDigits: d, maximumFractionDigits: d });
  const fmt = {
    int: (v) => nf(0).format(v),
    usd: (v) => '$' + nf(0).format(v),
    usd2: (v) => '$' + nf(2).format(v),
    usdK: (v) => '$' + nf(1).format(v / 1000) + 'K',
    pct: (v, d = 1) => nf(d).format(v * 100) + '%',
    pp: (v, d = 2) => (v >= 0 ? '+' : '−') + nf(d).format(Math.abs(v * 100)) + ' điểm %',
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

  /* ---------- ECharts: style chung (trục mờ, lưới mảnh, tooltip theo theme) ---------- */
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

  /* ---------- Trang Khám phá: vừa 1 màn hình; chi tiết mở khi cần ---------- */
  const PRESETS = [
    { label: 'Toàn công ty', filters: {} },
    { label: 'Nhóm rủi ro cao', hint: 'hợp đồng tháng · Fiber · trả tay', filters: { contract: ['Month-to-month'], internet: ['Fiber optic'], payment_type: ['Manual'] } },
    { label: 'Khách năm đầu', hint: 'gắn bó 0-12 tháng', filters: { tenure: ['0-12 months'] } },
    { label: 'Khách Fiber', filters: { internet: ['Fiber optic'] } },
    { label: 'Không dùng dịch vụ kèm', hint: 'có internet, 0 dịch vụ', filters: { addons: ['0'] } },
    { label: 'Hợp đồng dài hạn', hint: '1 hoặc 2 năm', filters: { contract: ['One year', 'Two year'] } },
  ];
  const MAIN_FACTORS = ['contract', 'internet', 'tenure', 'addons', 'payment_type', 'tech_support'];
  const SHORT_LABEL = { contract: 'Hợp đồng', internet: 'Internet', tenure: 'Gắn bó', addons: 'Dịch vụ kèm',
    payment_type: 'Thanh toán', tech_support: 'Hỗ trợ KT' };
  const VALUE_LABEL = {
    'Yes': 'Có', 'No': 'Không', 'No internet service': 'Không dùng internet', 'No phone service': 'Không dùng điện thoại',
    'Month-to-month': 'Theo tháng', 'One year': '1 năm', 'Two year': '2 năm', 'Fiber optic': 'Fiber', 'DSL': 'DSL',
    'Manual': 'Trả tay', 'Automatic': 'Tự động', 'Female': 'Nữ', 'Male': 'Nam',
    'Electronic check': 'Séc điện tử', 'Mailed check': 'Séc bưu điện',
    'Bank transfer (automatic)': 'Chuyển khoản tự động', 'Credit card (automatic)': 'Thẻ tín dụng tự động',
  };
  const MIN_GROUP = 30;          // nhánh nhỏ hơn mức này thì tỷ lệ dao động mạnh: hiển thị mờ, không xếp hạng
  const TOP_FACTORS = 6;   // tối đa; số thực hiển thị tự co theo chiều cao panel (fitTopFactors)

  function valueLabel(factor, v) {
    if (factor === 'addons') return v === 'No internet service' ? 'Không dùng internet' : `${v} dịch vụ`;
    if (factor === 'tenure') return v.replace(' months', ' tháng');
    if (factor === 'internet' && v === 'No') return 'Không dùng internet';
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
    ex.timer = setTimeout(refreshExplore, 120);   // gộp các cú bấm liên tiếp thành một request
  }

  async function renderExplore(root) {
    if (location.hash.includes('?')) ex.filters = filtersFromHash();
    syncHash();
    ex.catalog = ex.catalog || await api('factors');
    root.innerHTML = `
      <div class="card filterbar">
        <select class="input select" id="exPreset" aria-label="Góc nhìn có sẵn"></select>
        <div class="pills" id="exPills"></div>
        <div class="spacer"></div>
        <button class="btn ghost no-print" id="exClear" type="button">Xoá lọc</button>
      </div>
      <div class="headline" id="exHeadline"></div>
      <div class="grid kpis4" id="exKpis"></div>
      <div class="grid main-split">
        <div class="card flex-card">
          <div class="card-head"><div><h3 class="card-title" id="exChartTitle">Tỷ lệ rời đi theo tháng</h3>
            <div class="card-sub" id="exChartSub"></div></div></div>
          <div class="chart fill" id="ex-churn"></div>
        </div>
        <div class="card flex-card">
          <div class="card-head"><div><h3 class="card-title">Yếu tố tác động mạnh nhất</h3>
            <div class="card-sub">Trong nhóm đang chọn. Bấm một ô để lọc theo nhánh đó.</div></div></div>
          <div class="top-factors" id="exTop"></div>
          <button class="btn block no-print" id="exAll" type="button">Xem đủ 13 yếu tố</button>
        </div>
      </div>`;
    mountChart('ex-churn', {});
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
    $('#exKpis').addEventListener('click', (e) => { if (e.target.closest('#exCustomers')) openCustomerList(); });
    $('#exAll').addEventListener('click', openAllFactors);
    $('#exTop').addEventListener('click', (e) => {
      const v = e.target.closest('[data-f]');
      if (v) toggleValue(v.dataset.f, v.dataset.v);
    });
    drawFilterBar();
    await refreshExplore();
  }

  function drawFilterBar() {
    const sel = $('#exPreset');
    if (!sel) return;
    const match = PRESETS.findIndex((p) => JSON.stringify(normalize(p.filters)) === JSON.stringify(normalize(ex.filters)));
    sel.innerHTML = `<option value="" ${match < 0 ? 'selected' : ''}>${match < 0 ? 'Bộ lọc tuỳ chọn' : 'Góc nhìn có sẵn'}</option>`
      + PRESETS.map((p, i) => `<option value="${i}" ${i === match ? 'selected' : ''} title="${esc(p.hint || '')}">${esc(p.label)}</option>`).join('');
    const pill = (key, label) => {
      const vals = ex.filters[key] || [];
      // Một giá trị thì hiện tên, nhiều giá trị thì hiện số lượng: nút giữ độ rộng ổn định, thanh lọc không phải cuộn.
      const text = vals.length === 1 ? valueLabel(key, vals[0]) : vals.length ? `${vals.length} lựa chọn` : '';
      const full = vals.map((v) => valueLabel(key, v)).join(', ');
      return `<span class="pill ${vals.length ? 'on' : ''}" title="${esc(full || 'Tất cả')}"><button type="button" data-pop="${key}" aria-haspopup="true">
        <span class="pill-k">${esc(label)}${text ? ':' : ''}</span> ${esc(text)} <span class="caret">▾</span></button>${vals.length ? `<button type="button" class="pill-x" data-rm="${key}" aria-label="Bỏ lọc ${esc(label)}">✕</button>` : ''}</span>`;
    };
    const others = ex.catalog.filter((c) => !MAIN_FACTORS.includes(c.key));
    const otherActive = others.filter((c) => ex.filters[c.key]).length;
    $('#exPills').innerHTML = MAIN_FACTORS.map((k) => pill(k, SHORT_LABEL[k])).join('')
      + `<span class="pill ${otherActive ? 'on' : ''}"><button type="button" data-pop="__other" aria-haspopup="true"><span class="pill-k">Khác${otherActive ? ':' : ''}</span> ${otherActive ? `${otherActive} đang lọc` : ''} <span class="caret">▾</span></button></span>`;
  }

  /* Popover chọn giá trị: hiện luôn tỷ lệ rời đi của từng lựa chọn trong ngữ cảnh hiện tại. */
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
          <span class="muted num">${b ? fmt.int(b.customers) + ' khách' : '0 khách'}</span>
          <b class="num">${rate == null ? '–' : fmt.pct(rate)}</b></label>`;
      }).join('')}</div>`).join('') + '<div class="pop-foot muted">Cột phải: tỷ lệ đã rời đi trong 24 tháng, theo các bộ lọc còn lại.</div>';
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
      if (e.name !== 'AbortError') { toast('Không tải được dữ liệu'); console.error(e); }
    } finally {
      $('#page-explore')?.classList.remove('loading');
    }
  }

  function factorImpacts(d) {
    const byFactor = {};
    d.breakdown.forEach((b) => (byFactor[b.factor_key] = byFactor[b.factor_key] || []).push(b));
    return ex.catalog.map((f) => {
      const rows = (byFactor[f.key] || []).slice().sort((a, b) => a.value_sort - b.value_sort)
        .map((r) => ({ ...r, rate: r.churners / r.customers }));
      // "Không dùng internet" ở các yếu tố phụ thuộc internet chỉ lặp lại yếu tố Loại internet, nên không xếp hạng.
      const big = rows.filter((r) => r.customers >= MIN_GROUP && !(f.key !== 'internet' && r.value === 'No internet service'))
        .sort((a, b) => b.rate - a.rate);
      return { f, rows, hi: big[0], lo: big[big.length - 1], spread: big.length >= 2 ? big[0].rate - big[big.length - 1].rate : 0 };
    }).sort((a, b) => b.spread - a.spread);
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
    const impacts = factorImpacts(d);
    // Yếu tố đang lọc đúng một giá trị thì không còn gì để so trong nhóm, bỏ khỏi bảng xếp hạng.
    const ranked = impacts.filter((i) => i.spread > 0 && !(ex.filters[i.f.key] || []).length);
    const top = ranked[0];

    const who = filtered ? `Nhóm ${fmt.int(k.sel_customers)} khách (${fmt.pct(k.sel_customers / k.all_customers, 0)} công ty)` : 'Toàn công ty';
    const vs = filtered ? `, ${lift >= 1 ? `gấp <b>${fmt.num(lift, 1)} lần</b>` : `bằng <b>${fmt.num(lift, 2)} lần</b>`} mức chung ${fmt.pct(allRate)}` : '';
    const driver = top ? `. Khác biệt nhất: <b>${esc(top.f.label.toLowerCase())}</b> (${esc(valueLabel(top.f.key, top.hi.value))} ${fmt.pct(top.hi.rate)} so với ${esc(valueLabel(top.f.key, top.lo.value))} ${fmt.pct(top.lo.rate)})` : '';
    $('#exHeadline').innerHTML = `${ICON.bulb}<span>${who}: <b>${fmt.pct(selRate)}</b> đã rời đi trong 24 tháng${vs}${driver}.`
      + `${k.sel_customers < 100 ? ` ${badge('warn', 'nhóm dưới 100 khách, xem như tham khảo')}` : ''}</span>`;

    $('#exKpis').innerHTML = [
      kpiCard('Khách trong nhóm', fmt.int(k.sel_customers), `${filtered ? fmt.pct(k.sel_customers / k.all_customers) + ' toàn công ty' : 'có tính cước'} · <button type="button" class="inline-link" id="exCustomers">Xem danh sách ›</button>`),
      kpiCard('Đã rời đi (24 tháng)', fmt.pct(selRate),
        filtered ? `${badge(lift > 1.05 ? 'bad' : lift < 0.95 ? 'good' : 'neutral', '×' + fmt.num(lift, 2), lift > 1.05 ? 'up' : lift < 0.95 ? 'down' : null)} so với mức chung` : `${fmt.int(k.all_churners)} khách · ${fmt.pct(selMonthly, 2)}/tháng`),
      kpiCard('MRR hiện tại', fmt.usd(selMrr), filtered ? `${fmt.pct(k.all_mrr ? selMrr / k.all_mrr : 0)} doanh thu định kỳ` : `${fmt.int(k.sel_active)} khách còn hoạt động`),
      kpiCard('MRR dự kiến mất / tháng', fmt.usd(selLoss), 'nếu không có hành động giữ chân'),
    ].join('');

    const opt = (i, r, kind) => `
      <button type="button" class="tf-opt ${kind}" data-f="${esc(i.f.key)}" data-v="${esc(r.value)}"
        title="Lọc nhóm: ${esc(i.f.label)} = ${esc(valueLabel(i.f.key, r.value))}">
        <span class="tf-main"><span class="tf-name">${esc(valueLabel(i.f.key, r.value))}</span><b class="num">${fmt.pct(r.rate)}</b></span>
        <span class="tf-bar"><i style="width:${Math.max(2, 100 * r.rate).toFixed(1)}%"></i></span>
        <span class="tf-meta"><span class="num">${fmt.int(r.customers)} khách</span><span class="tf-add">＋ Lọc</span></span>
      </button>`;
    $('#exTop').innerHTML = ranked.length ? '<div class="tf-cols"><span>▲ Rời đi nhiều nhất</span><span>▼ Rời đi ít nhất</span></div>' + ranked.slice(0, TOP_FACTORS).map((i) => `
      <div class="tf">
        <div class="tf-head"><b>${esc(i.f.label)}</b><span class="tf-gap">chênh ${fmt.num(i.spread * 100, 0)} điểm %</span></div>
        <div class="tf-opts">${opt(i, i.hi, 'hi')}${opt(i, i.lo, 'lo')}</div>
      </div>`).join('') : '<p class="muted">Nhóm quá nhỏ để so sánh tiếp.</p>';
    fitTopFactors();

    drawChurnChart(d, filtered);
    resizeChartsSoon();
  }

  // Bỏ bớt yếu tố cuối cho tới khi danh sách vừa khung panel: không cắt dở, không thanh cuộn.
  function fitTopFactors() {
    const el = $('#exTop');
    if (!el) return;
    while (el.scrollHeight > el.clientHeight + 1 && el.querySelectorAll('.tf').length > 1) el.querySelector('.tf:last-of-type').remove();
  }

  // Khung biểu đồ co giãn theo chiều cao còn lại của trang, nên phải đo lại sau khi nội dung phía trên đã vẽ xong.
  function resizeChartsSoon() { requestAnimationFrame(() => Object.values(state.charts).forEach((c) => c.resize())); }

  function drawChurnChart(d, filtered) {
    const chart = state.charts['ex-churn'];
    if (!chart) return;
    const s1 = css('--series-1'), muted = css('--text-3'), neutral = css('--neutral-mark');
    const months = d.trend.map((t) => t.year_month);
    const sel = d.trend.map((t) => (t.sel_customers ? t.sel_churners / t.sel_customers : null));
    const peakIdx = sel.reduce((bi, v, i) => (v != null && (bi < 0 || v > sel[bi]) ? i : bi), -1);
    $('#exChartTitle').textContent = filtered ? 'Tỷ lệ rời đi theo tháng: nhóm đang chọn và toàn công ty' : 'Tỷ lệ rời đi theo tháng so với chỉ tiêu';
    $('#exChartSub').textContent = peakIdx >= 0 ? `Đỉnh ${fmt.pct(sel[peakIdx], 1)} vào ${months[peakIdx]}${months[peakIdx] >= '2025-03' && months[peakIdx] <= '2025-05' ? ', ngay sau đợt tăng giá Fiber' : ''}.` : '';
    const series = [{ name: filtered ? 'Nhóm đang chọn' : 'Toàn công ty', type: 'line', data: sel, showSymbol: false,
      lineStyle: { width: 2.5, color: s1 }, itemStyle: { color: s1 }, areaStyle: { color: s1 + '14' },
      markLine: { silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' },
        label: { formatter: 'Tăng giá Fiber', color: muted, fontSize: 11, position: 'insideStartTop' }, data: [{ xAxis: '2025-03' }] },
      markPoint: peakIdx < 0 ? undefined : { symbol: 'circle', symbolSize: 8, itemStyle: { color: s1, borderColor: css('--surface'), borderWidth: 2 },
        label: { formatter: fmt.pct(sel[peakIdx], 1), position: 'top', color: css('--text'), fontSize: 11, fontWeight: 600 },
        data: [{ coord: [months[peakIdx], sel[peakIdx]] }] } }];
    series.push(filtered
      ? { name: 'Toàn công ty', type: 'line', data: d.trend.map((t) => t.all_churners / t.all_customers), showSymbol: false,
          lineStyle: { width: 2, color: neutral }, itemStyle: { color: neutral } }
      : { name: 'Chỉ tiêu', type: 'line', step: 'middle', data: d.trend.map((t) => t.churn_rate_target), showSymbol: false,
          lineStyle: { width: 2, type: 'dashed', color: muted }, itemStyle: { color: muted } });
    chart.setOption({
      legend: { ...baseOption().legend, data: series.map((s) => s.name) },
      grid: { left: 8, right: 16, top: 34, bottom: 4, containLabel: true },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false }),
      yAxis: axis({ type: 'value', axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, Math.round(v * 1000) % 10 ? 1 : 0) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const t = d.trend[ps[0].dataIndex];
        return `<b>${t.year_month}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? '–' : fmt.pct(p.value, 2))).join('')
          + (t.sel_customers ? tipRow(null, 'Rời đi / khách trong nhóm', `${fmt.int(t.sel_churners)}/${fmt.int(t.sel_customers)}`) : '')
          + tipRow(null, 'MRR của nhóm', fmt.usd(t.sel_mrr));
      } },
      series,
    }, true);
  }

  /* Chi tiết đủ 13 yếu tố: mở trong drawer để trang chính luôn gọn. */
  function openAllFactors() {
    if (!ex.last) return;
    openDrawer('Cả 13 yếu tố trong nhóm đang chọn', 'Tỷ lệ đã rời đi (24 tháng) của từng nhánh. Bấm một dòng để thêm vào bộ lọc.');
    const selRate = ex.last.kpi.sel_customers ? ex.last.kpi.sel_churners / ex.last.kpi.sel_customers : 0;
    const body = $('#drawerBody');
    const draw = () => {
      body.innerHTML = `<div class="impact-grid">${factorImpacts(ex.last).map(({ f, rows, spread }) => {
        const maxRate = Math.max(0.01, ...rows.map((r) => r.rate));
        return `<div class="impact ${ex.filters[f.key] ? 'filtered' : ''}">
          <div class="impact-head"><b>${esc(f.label)}</b><span class="muted">${spread ? `chênh ${fmt.num(spread * 100, 1)} điểm %` : '–'}</span></div>
          ${rows.map((r) => {
            const on = (ex.filters[f.key] || []).includes(r.value), tiny = r.customers < MIN_GROUP;
            return `<button type="button" class="impact-row ${on ? 'on' : ''} ${tiny ? 'tiny' : ''}" data-f="${esc(f.key)}" data-v="${esc(r.value)}">
              <span class="impact-name">${esc(valueLabel(f.key, r.value))}</span>
              <span class="impact-bar"><span style="width:${(100 * r.rate / maxRate).toFixed(1)}%" class="${r.rate > selRate * 1.2 && !tiny ? 'hot' : ''}"></span></span>
              <span class="impact-val num">${fmt.pct(r.rate)}</span>
              <span class="impact-n num">${tiny ? 'mẫu nhỏ' : fmt.int(r.customers)}</span></button>`;
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
    openDrawer(Object.keys(ex.filters).length ? filterSummary() : 'Toàn công ty', 'Khách đang hoạt động trong nhóm, sắp theo cước giảm dần');
    try {
      const res = await fetch('/api/explore/customers', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ filters: ex.filters }) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      renderCustomerTable(data.rows, data.limit);
    } catch (e) {
      $('#drawerBody').innerHTML = `<p class="error">Không tải được danh sách khách: ${esc(e.message)}</p>`;
    }
  }

  function filterSummary() {
    return Object.entries(ex.filters).map(([k, vs]) => {
      const f = ex.catalog.find((c) => c.key === k);
      return `${f.label}: ${vs.map((v) => valueLabel(k, v)).join(' hoặc ')}`;
    }).join(' · ');
  }

  function renderCustomerTable(rows, limit) {
    const cols = [
      ['customer_id', 'Mã khách', 's'], ['contract_type', 'Hợp đồng', 's'], ['internet_service', 'Internet', 's'],
      ['tenure_months', 'Gắn bó (th)', 'n'], ['current_mrr_usd', 'Cước hiện tại', 'usd'], ['tickets', 'Ticket', 'n'],
      ['billing_tickets', 'Ticket hoá đơn', 'n'], ['late_payment_rate', 'Trả trễ', 'pct'], ['tech_support', 'Hỗ trợ KT', 's'],
      ['addon_count', 'Dịch vụ kèm', 'n'], ['payment_method', 'Thanh toán', 's'],
    ];
    let sortKey = 'current_mrr_usd', sortDir = -1, query = '';
    const body = $('#drawerBody');
    body.innerHTML = `
      <div class="toolbar">
        <input class="input" id="custSearch" placeholder="Tìm mã khách..." aria-label="Tìm mã khách">
        <span class="muted" id="custCount"></span>
        <button class="btn" id="custExport" type="button" style="margin-left:auto">${ICON.download}Xuất CSV</button>
      </div>
      <div class="table-wrap"><table><thead><tr>${cols.map(([k, l, t]) => `<th class="sortable ${t === 's' ? '' : 'r'}" data-k="${k}">${l}</th>`).join('')}</tr></thead>
      <tbody id="custBody"></tbody></table></div>
      ${rows.length >= limit ? `<p class="muted">Hiển thị ${limit} khách có cước cao nhất.</p>` : ''}`;
    const cell = (r, k, t) => (r[k] == null ? '–' : t === 'usd' ? fmt.usd2(r[k]) : t === 'pct' ? fmt.pct(r[k], 0) : t === 'n' ? fmt.int(r[k]) : esc(valueLabel('', r[k])));
    const visible = () => rows.filter((r) => r.customer_id.toLowerCase().includes(query))
      .sort((a, b) => (a[sortKey] > b[sortKey] ? 1 : a[sortKey] < b[sortKey] ? -1 : 0) * sortDir);
    const draw = () => {
      const v = visible();
      $('#custBody').innerHTML = v.map((r) => `<tr>${cols.map(([k, , t]) => `<td class="${t === 's' ? '' : 'r num'}">${cell(r, k, t)}</td>`).join('')}</tr>`).join('');
      $('#custCount').textContent = `${fmt.int(v.length)} khách`;
    };
    $('#custSearch').addEventListener('input', (e) => { query = e.target.value.trim().toLowerCase(); draw(); });
    body.querySelectorAll('th.sortable').forEach((th) => th.addEventListener('click', () => {
      sortDir = sortKey === th.dataset.k ? -sortDir : -1; sortKey = th.dataset.k; draw();
    }));
    $('#custExport').addEventListener('click', () => {
      const lines = [cols.map((c) => c[0]).join(',')].concat(visible().map((r) => cols.map(([k]) => `"${String(r[k] ?? '').replace(/"/g, '""')}"`).join(',')));
      const url = URL.createObjectURL(new Blob(['﻿' + lines.join('\n')], { type: 'text/csv;charset=utf-8' }));
      const a = Object.assign(document.createElement('a'), { href: url, download: 'khach_hang_nhom_dang_chon.csv' });
      a.click(); URL.revokeObjectURL(url); toast('Đã xuất CSV');
    });
    draw();
  }

  function closeDrawer() {
    $('#drawer').classList.remove('open'); $('#drawerBackdrop').classList.remove('open');
    $('#drawer').setAttribute('aria-hidden', 'true');
  }

  /* ---------- Trang What-if: vừa 1 màn hình ---------- */
  async function renderWhatif(root) {
    const base = await api('whatif_base');
    const m2m = base.find((b) => b.contract_type === 'Month-to-month');
    const oneY = base.find((b) => b.contract_type === 'One year');
    root.innerHTML = `
      <div class="headline" id="wfHeadline"></div>
      <div class="grid kpis4" id="wfKpis"></div>
      <div class="grid main-split">
        <div class="card flex-card">
          <div class="card-head"><div><h3 class="card-title">Số khách còn lại của nhóm được chuyển đổi</h3>
            <div class="card-sub">Xanh: sau khi chuyển sang hợp đồng 1 năm · Cam: nếu vẫn theo tháng.</div></div></div>
          <div class="chart fill" id="c-whatif"></div>
        </div>
        <div class="card flex-card">
          <h3 class="card-title" style="margin-bottom:12px">Tham số</h3>
          <div class="control"><div class="control-row"><label for="shift">Khách hợp đồng tháng chuyển sang 1 năm</label><output id="shiftOut" class="num"></output></div>
            <input type="range" id="shift" min="0" max="50" step="5" value="20"></div>
          <div class="control"><div class="control-row"><label for="discount">Chiết khấu để thuyết phục</label><output id="discountOut" class="num"></output></div>
            <input type="range" id="discount" min="0" max="30" step="1" value="10"></div>
          <div class="control"><div class="control-row"><label for="horizon">Tầm nhìn</label><output id="horizonOut" class="num"></output></div>
            <input type="range" id="horizon" min="6" max="24" step="6" value="12"></div>
          <p class="assumptions">Rời đi mỗi tháng: theo tháng ${fmt.pct(m2m.monthly_churn_rate, 2)}, hợp đồng 1 năm ${fmt.pct(oneY.monthly_churn_rate, 2)}.
            ARPU ${fmt.usd2(m2m.arpu_usd)}. Là chênh lệch tương quan nên xem như mức tối đa.</p>
        </div>
      </div>`;

    const s1 = css('--series-1'), s2 = css('--series-2');
    const chart = mountChart('c-whatif', {});
    const update = () => {
      const pct = +$('#shift').value / 100, disc = +$('#discount').value / 100, H = +$('#horizon').value;
      $('#shiftOut').textContent = fmt.pct(pct, 0); $('#discountOut').textContent = fmt.pct(disc, 0); $('#horizonOut').textContent = `${H} tháng`;
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
        ? `Chuyển <b>${fmt.int(moved)}</b> khách sang hợp đồng 1 năm với chiết khấu ${fmt.pct(disc, 0)}: sau ${H} tháng giữ thêm <b>${fmt.int(Math.round(extra))} khách</b>, lợi ích ròng <b>${fmt.usd(net)}</b>. Chiết khấu tối đa để hoà vốn: ${fmt.pct(breakEven, 1)}.`
        : 'Kéo thanh trượt bên phải để xem kịch bản.'}</span>`;
      $('#wfKpis').innerHTML = [
        kpiCard('Khách được chuyển đổi', fmt.int(moved), `trên ${fmt.int(m2m.active_customers)} khách hợp đồng tháng`),
        kpiCard(`MRR giữ thêm ở tháng ${H}`, fmt.usd(extra * arpu), `${fmt.int(Math.round(extra))} khách còn ở lại thêm`),
        kpiCard(`Doanh thu giữ thêm (${H} tháng)`, fmt.usd(gross), `chi phí chiết khấu ${fmt.usd(cost)}`),
        kpiCard('Lợi ích ròng', fmt.usd(net), `${badge(net >= 0 ? 'good' : 'bad', net >= 0 ? 'Có lãi' : 'Lỗ')} hoà vốn ở chiết khấu ${fmt.pct(breakEven, 1)}`),
      ].join('');
      chart.setOption({
        legend: { ...baseOption().legend, data: ['Chuyển sang 1 năm', 'Vẫn theo tháng'] },
        grid: { left: 8, right: 16, top: 34, bottom: 24, containLabel: true },
        xAxis: axis({ type: 'category', data: ks, boundaryGap: false, name: 'Tháng', nameLocation: 'middle', nameGap: 24, nameTextStyle: { color: css('--text-3'), fontSize: 11 } }),
        yAxis: axis({ type: 'value', min: 0 }),
        tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Tháng ${ps[0].axisValue}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, fmt.num(p.value, 0) + ' khách')).join('') },
        series: [
          { name: 'Chuyển sang 1 năm', type: 'line', data: move, showSymbol: false, lineStyle: { width: 2.5, color: s1 }, itemStyle: { color: s1 }, areaStyle: { color: s1 + '14' } },
          { name: 'Vẫn theo tháng', type: 'line', data: stay, showSymbol: false, lineStyle: { width: 2.5, color: s2 }, itemStyle: { color: s2 } },
        ],
      }, true);
    };
    ['shift', 'discount', 'horizon'].forEach((id) => $('#' + id).addEventListener('input', update));
    update();
    resizeChartsSoon();
  }

  /* ---------- Trang Data Quality: trang tra cứu cho đội dữ liệu nên được phép dài; phần đầu vẫn tóm tắt gọn ---------- */
  async function renderQuality(root) {
    const [checks, rejected, steps] = await Promise.all([api('dq_checks'), api('rejected'), api('etl_steps')]);
    const count = (s) => checks.filter((c) => c.status === s).length;
    const totalRejected = sum(rejected, (r) => r.rejected_rows);
    const pipeline = steps.find((s) => s.layer === 'pipeline');
    const groups = [...new Set(checks.map((c) => c.check_group))].sort();
    const fmtVal = (v) => (v == null ? '–' : fmt.num(v, Number.isInteger(v) ? 0 : 2));

    root.innerHTML = `
      <div class="headline">${ICON.bulb}<span><b>${count('PASS')}/${checks.length}</b> kiểm tra đạt, <b>${count('FAIL')}</b> lỗi cần xử lý.
        ${count('WARN') ? `${count('WARN')} cảnh báo là tháng 2024-08 hệ thống billing sự cố, đã được ước lượng bù.` : ''}
        ${fmt.int(totalRejected)} bản ghi lỗi được tách riêng kèm lý do, không xoá im lặng.</span></div>
      <div class="grid kpis4">
        ${kpiCard('Kiểm tra đạt', `<span class="status PASS">${count('PASS')}</span>`, `trên ${checks.length} kiểm tra`)}
        ${kpiCard('Cảnh báo / Lỗi', `<span class="status WARN">${count('WARN')}</span> <span class="status FAIL">${count('FAIL')}</span>`, 'cảnh báo đã biết · lỗi cần điều tra')}
        ${kpiCard('Bản ghi bị loại', fmt.int(totalRejected), `${rejected.length} loại lý do`)}
        ${kpiCard('Lần chạy ETL gần nhất', pipeline ? fmt.num(pipeline.duration_ms / 1000, 0) + ' giây' : '–',
          pipeline ? esc(new Date(pipeline.finished_at).toLocaleString('vi-VN')) : '')}
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Kết quả ${checks.length} kiểm tra</h3>
        <div class="card-sub">Trước = đo trên dữ liệu gốc (stg) · Sau = đo trên dữ liệu đã làm sạch (clean/mart) · Loại = số dòng tách sang rejected</div></div></div>
        <div class="table-wrap" style="max-height:none"><table><thead><tr><th>Trạng thái</th><th>Kiểm tra</th><th>Đối tượng</th>
          <th class="r">Trước</th><th class="r">Sau</th><th class="r">Loại</th><th>Ghi chú</th></tr></thead>
          <tbody>${groups.map((g) => `<tr><td colspan="7" style="background:var(--surface-2);font-weight:600">${esc(g)}</td></tr>` +
            checks.filter((c) => c.check_group === g).map((c) => `<tr><td><span class="status ${c.status}">${c.status}</span></td>
              <td class="wrap">${esc(c.check_name)}</td><td class="wrap muted">${esc(c.object_name || '')}</td>
              <td class="r num">${fmtVal(c.value_before)}</td><td class="r num">${fmtVal(c.value_after)}</td>
              <td class="r num">${fmtVal(c.value_rejected)}</td><td class="wrap muted">${esc(c.note || c.expected_rule || '')}</td></tr>`).join('')).join('')}
          </tbody></table></div></div>
      <div class="grid two">
        <div class="card"><div class="card-head"><div><h3 class="card-title">Bản ghi bị loại theo lý do</h3>
          <div class="card-sub">Lưu trong clean.rejected_records kèm nguyên dòng gốc (JSON)</div></div></div>
          <div class="table-wrap"><table><thead><tr><th>Bảng nguồn</th><th>Lý do</th><th class="r">Số dòng</th><th>Ví dụ</th></tr></thead>
            <tbody>${rejected.map((r) => `<tr><td>${esc(r.source_table)}</td><td>${esc(r.reason_code)}</td>
              <td class="r num">${fmt.int(r.rejected_rows)}</td><td class="wrap muted">${esc(r.sample_detail)}</td></tr>`).join('')}</tbody></table></div></div>
        <div class="card"><div class="card-head"><div><h3 class="card-title">Các bước ETL của lần chạy gần nhất</h3>
          <div class="card-sub">Từ dbo.etl_log</div></div></div>
          <div class="table-wrap"><table><thead><tr><th>Bước</th><th>Trạng thái</th><th class="r">Đọc</th><th class="r">Ghi</th><th class="r">Thời gian</th></tr></thead>
            <tbody>${steps.filter((s) => s.layer !== 'pipeline').map((s) => `<tr><td>${esc(s.step_name)}</td>
              <td><span class="status ${s.status === 'SUCCESS' ? 'PASS' : 'FAIL'}">${esc(s.status)}</span></td>
              <td class="r num">${s.rows_read == null ? '–' : fmt.int(s.rows_read)}</td><td class="r num">${s.rows_written == null ? '–' : fmt.int(s.rows_written)}</td>
              <td class="r num">${fmt.num(s.duration_ms / 1000, 1)} s</td></tr>`).join('')}</tbody></table></div></div>
      </div>`;
  }

  /* ---------- điều hướng, theme, khởi động ---------- */
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
      root.innerHTML = `<div class="card error">Không tải được dữ liệu: ${esc(e.message)}. Kiểm tra SQL Server và đã chạy python -m src.run_etl chưa.</div>`;
      console.error(e);
    }
  }

  async function loadMeta() {
    try {
      const m = await (await fetch('/api/meta')).json();
      const etl = m.last_etl ? new Date(m.last_etl.finished_at).toLocaleString('vi-VN') : 'chưa chạy';
      $('#freshness').innerHTML = `Snapshot <b>${esc(m.snapshot_date)}</b><br>ETL gần nhất: <b>${esc(etl)}</b>`;
    } catch (e) {
      $('#freshness').textContent = 'Không đọc được trạng thái ETL';
    }
  }

  function setTheme(next) {
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('theme', next); } catch (e) { /* trình duyệt chặn storage: bỏ qua, theme vẫn đổi */ }
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
  // Bộ lọc của trang Khám phá nằm sau dấu ? trong hash; chỉ vẽ lại trang khi đổi trang.
  const pageFromHash = () => location.hash.slice(1).split('?')[0];
  window.addEventListener('hashchange', () => { if (pageFromHash() !== state.page) show(pageFromHash()); });
  const resizeCharts = () => Object.values(state.charts).forEach((c) => c.resize());
  window.addEventListener('resize', () => { resizeCharts(); if (state.page === 'explore' && ex.last) drawExplore(ex.last); });
  // Khi in, khung trang đổi kích thước (ẩn sidebar, khổ A4) nên biểu đồ phải vẽ lại theo khung mới.
  window.addEventListener('beforeprint', resizeCharts);
  window.addEventListener('afterprint', resizeCharts);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => show(state.page));

  loadMeta();
  show(pageFromHash() || 'explore');
})();
