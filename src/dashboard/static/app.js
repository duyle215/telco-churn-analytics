/* Telco Churn Analytics: SPA nhỏ, dữ liệu lấy từ /api/* (các view mart). */
(() => {
  'use strict';

  const PAGES = {
    explore: { title: 'Khám phá churn', crumb: 'Phân tích', render: renderExplore },
    whatif: { title: 'What-if Scenario', crumb: 'Phân tích', render: renderWhatif },
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

  /* ---------- Trang Khám phá: bật/tắt yếu tố, mọi thứ tính lại theo nhóm đang chọn ---------- */
  const PRESETS = [
    { label: 'Toàn công ty', filters: {} },
    { label: 'Nhóm rủi ro cao', hint: 'Hợp đồng tháng · Fiber · trả tay', filters: { contract: ['Month-to-month'], internet: ['Fiber optic'], payment_type: ['Manual'] } },
    { label: 'Khách năm đầu', hint: 'gắn bó 0-12 tháng', filters: { tenure: ['0-12 months'] } },
    { label: 'Khách Fiber', filters: { internet: ['Fiber optic'] } },
    { label: 'Không dùng dịch vụ đi kèm', hint: 'có internet', filters: { addons: ['0'] } },
    { label: 'Hợp đồng dài hạn', hint: '1-2 năm', filters: { contract: ['One year', 'Two year'] } },
  ];
  const VALUE_LABEL = {
    'Yes': 'Có', 'No': 'Không', 'No internet service': 'Không dùng internet', 'No phone service': 'Không dùng điện thoại',
    'Month-to-month': 'Theo tháng', 'One year': '1 năm', 'Two year': '2 năm', 'Fiber optic': 'Fiber', 'DSL': 'DSL',
    'Manual': 'Trả tay', 'Automatic': 'Tự động', 'Female': 'Nữ', 'Male': 'Nam',
    'Electronic check': 'Séc điện tử', 'Mailed check': 'Séc gửi bưu điện',
    'Bank transfer (automatic)': 'Chuyển khoản (tự động)', 'Credit card (automatic)': 'Thẻ tín dụng (tự động)',
  };
  const MIN_GROUP = 30;          // nhóm nhỏ hơn mức này thì tỷ lệ dao động mạnh, chỉ hiển thị mờ
  const MIN_COHORTS = 6;

  function valueLabel(factor, v) {
    if (factor === 'addons') return v === 'No internet service' ? 'Không dùng internet' : `${v} dịch vụ`;
    if (factor === 'tenure') return v.replace(' months', ' tháng');
    if (factor === 'internet' && v === 'No') return 'Không dùng internet';
    return VALUE_LABEL[v] || v;
  }

  const ex = { filters: {}, catalog: null, charts: {}, ctrl: null, timer: null, last: null };

  function filtersFromHash() {
    const q = location.hash.split('?')[1];
    if (!q) return {};
    try { return JSON.parse(decodeURIComponent(new URLSearchParams(q).get('f') || '{}')); } catch (e) { return {}; }
  }
  function syncHash() {
    const has = Object.keys(ex.filters).length;
    const target = '#explore' + (has ? '?f=' + encodeURIComponent(JSON.stringify(ex.filters)) : '');
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
    drawChips();
    clearTimeout(ex.timer);
    // Gộp các cú bấm liên tiếp thành một request.
    ex.timer = setTimeout(refreshExplore, 120);
  }

  async function renderExplore(root) {
    // Link có bộ lọc thì dùng bộ lọc đó; quay lại từ trang khác thì giữ bộ lọc đang chọn.
    if (location.hash.includes('?')) ex.filters = filtersFromHash();
    syncHash();
    ex.catalog = ex.catalog || await api('factors');
    root.innerHTML = `
      <div class="card">
        <div class="card-head"><div><h3 class="card-title">Chọn nhóm khách muốn xem</h3>
          <div class="card-sub">Bấm để bật/tắt. Trong cùng một yếu tố: khách thuộc <b>một trong</b> các lựa chọn. Giữa các yếu tố: phải thoả <b>tất cả</b>.</div></div>
          <button class="btn" id="exClear" type="button">Xoá lọc</button></div>
        <div class="presets" id="exPresets">${PRESETS.map((p, i) => `<button type="button" class="preset" data-i="${i}">${esc(p.label)}${p.hint ? `<span>${esc(p.hint)}</span>` : ''}</button>`).join('')}</div>
        <div class="factor-grid" id="exChips"></div>
      </div>
      <div id="exInsight"></div>
      <div class="grid kpis" id="exKpis"></div>
      <div class="grid two">
        ${cardHtml('ex-churn', 'Tỷ lệ rời đi theo tháng', 'Nhóm đang chọn so với toàn công ty.')}
        ${cardHtml('ex-mrr', 'Doanh thu định kỳ (MRR) theo tháng', 'Tổng cước hàng tháng của nhóm đang chọn (USD).')}
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title" id="exImpactTitle">Yếu tố nào tạo khác biệt lớn nhất?</h3>
        <div class="card-sub">Chia tiếp nhóm đang chọn theo từng yếu tố: mỗi dòng là tỷ lệ khách đã rời đi trong 24 tháng. Yếu tố chênh lệch nhiều nhất đứng đầu. <b>Bấm một dòng để thêm vào bộ lọc.</b></div></div></div>
        <div class="impact-grid" id="exImpact"></div></div>
      <div class="grid two">
        ${cardHtml('ex-retention', 'Sau khi ký, còn giữ được bao nhiêu khách?', 'Tỷ lệ khách còn dùng dịch vụ sau k tháng (khách bắt đầu từ 12/2023).')}
        ${cardHtml('ex-tickets', 'Ticket khiếu nại hoá đơn trên 100 khách', 'Tín hiệu cảnh báo sớm: thường tăng trước khi khách rời đi.')}
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Danh sách khách đang hoạt động trong nhóm</h3>
        <div class="card-sub">Để đội chăm sóc khách hàng gọi điện / ưu đãi giữ chân.</div></div>
        <button class="btn primary" id="exCustomers" type="button">Xem danh sách khách</button></div></div>`;

    ex.charts = {};
    ['ex-churn', 'ex-mrr', 'ex-retention', 'ex-tickets'].forEach((id) => { ex.charts[id] = mountChart(id, {}); });
    $('#exClear').addEventListener('click', () => { ex.filters = {}; onFiltersChanged(); });
    $('#exPresets').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-i]');
      if (b) { ex.filters = JSON.parse(JSON.stringify(PRESETS[+b.dataset.i].filters)); onFiltersChanged(); }
    });
    $('#exChips').addEventListener('click', (e) => {
      const c = e.target.closest('button[data-f]');
      if (c) toggleValue(c.dataset.f, c.dataset.v);
    });
    $('#exImpact').addEventListener('click', (e) => {
      const r = e.target.closest('[data-f]');
      if (r) toggleValue(r.dataset.f, r.dataset.v);
    });
    $('#exCustomers').addEventListener('click', openCustomerList);
    drawChips();
    await refreshExplore();
  }

  function drawChips() {
    const el = $('#exChips');
    if (!el) return;
    el.innerHTML = ex.catalog.map((f) => `
      <div class="factor"><div class="factor-label">${esc(f.label)}</div><div class="chips">
        ${f.values.map((v) => {
          const on = (ex.filters[f.key] || []).includes(v.value);
          return `<button type="button" class="chip ${on ? 'on' : ''}" aria-pressed="${on}" data-f="${esc(f.key)}" data-v="${esc(v.value)}">${esc(valueLabel(f.key, v.value))}</button>`;
        }).join('')}
      </div></div>`).join('');
    document.querySelectorAll('#exPresets .preset').forEach((b) => {
      b.classList.toggle('on', JSON.stringify(normalize(PRESETS[+b.dataset.i].filters)) === JSON.stringify(normalize(ex.filters)));
    });
  }
  const normalize = (f) => Object.keys(f).sort().reduce((o, k) => (o[k] = [...f[k]].sort(), o), {});

  async function refreshExplore() {
    if (ex.ctrl) ex.ctrl.abort();
    ex.ctrl = new AbortController();
    document.getElementById('page-explore').classList.add('loading');
    try {
      const res = await fetch('/api/explore', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filters: ex.filters }), signal: ex.ctrl.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
      ex.last = await res.json();
      drawExplore(ex.last);
    } catch (e) {
      if (e.name !== 'AbortError') { toast('Không tải được dữ liệu'); console.error(e); }
    } finally {
      document.getElementById('page-explore')?.classList.remove('loading');
    }
  }

  function filterSummary() {
    const parts = Object.entries(ex.filters).map(([k, vs]) => {
      const f = ex.catalog.find((c) => c.key === k);
      return `${f.label}: ${vs.map((v) => valueLabel(k, v)).join(' hoặc ')}`;
    });
    return parts.length ? parts.join(' · ') : 'Toàn công ty';
  }

  function drawExplore(d) {
    const k = d.kpi;
    const filtered = Object.keys(ex.filters).length > 0;
    const selRate = k.sel_customers ? k.sel_churners / k.sel_customers : 0;
    const allRate = k.all_churners / k.all_customers;
    const selMonthly = k.sel_customer_months ? k.sel_churners / k.sel_customer_months : 0;
    const allMonthly = k.all_churners / k.all_customer_months;
    const selMrr = k.sel_mrr || 0;
    const selLoss = selMrr * selMonthly, allLoss = k.all_mrr * allMonthly;
    const small = k.sel_customers < 100;

    // Thống kê từng yếu tố: chênh lệch giữa nhánh churn cao nhất và thấp nhất (chỉ xét nhánh đủ lớn).
    const byFactor = {};
    d.breakdown.forEach((b) => (byFactor[b.factor_key] = byFactor[b.factor_key] || []).push(b));
    const impacts = ex.catalog.map((f) => {
      const rows = (byFactor[f.key] || []).slice().sort((a, b) => a.value_sort - b.value_sort);
      const big = rows.filter((r) => r.customers >= MIN_GROUP);
      const rates = big.map((r) => r.churners / r.customers);
      const spread = big.length >= 2 ? Math.max(...rates) - Math.min(...rates) : 0;
      return { f, rows, spread, big };
    }).sort((a, b) => b.spread - a.spread);
    const topFree = impacts.find((i) => !ex.filters[i.f.key] && i.big.length >= 2);

    // Insight viết bằng câu thường cho người không chuyên.
    const bullets = [];
    if (filtered) {
      bullets.push(`Nhóm có <b>${fmt.int(k.sel_customers)}</b> khách (${fmt.pct(k.sel_customers / k.all_customers)} công ty); <b>${fmt.pct(selRate)}</b> đã rời đi trong 24 tháng, ${selRate >= allRate ? `<b>gấp ${fmt.num(selRate / allRate, 1)} lần</b>` : `chỉ bằng <b>${fmt.num(selRate / allRate, 2)} lần</b>`} mức chung (${fmt.pct(allRate)}).`);
    } else {
      bullets.push(`${fmt.pct(allRate)} khách có tính cước trong 24 tháng đã rời đi (${fmt.int(k.all_churners)}/${fmt.int(k.all_customers)}). Chọn yếu tố hoặc một góc nhìn có sẵn để so sánh.`);
    }
    if (topFree) {
      const rs = topFree.big.map((r) => ({ r, rate: r.churners / r.customers })).sort((a, b) => b.rate - a.rate);
      bullets.push(`Trong nhóm này, <b>${esc(topFree.f.label.toLowerCase())}</b> tạo khác biệt lớn nhất: ${esc(valueLabel(topFree.f.key, rs[0].r.value))} rời đi ${fmt.pct(rs[0].rate)} so với ${esc(valueLabel(topFree.f.key, rs[rs.length - 1].r.value))} chỉ ${fmt.pct(rs[rs.length - 1].rate)}.`);
    }
    const peak = d.trend.reduce((a, t) => (t.sel_customers && (!a || t.sel_churners / t.sel_customers > a.sel_churners / a.sel_customers) ? t : a), null);
    if (peak) bullets.push(`Tháng rời đi nhiều nhất: ${peak.year_month} (${fmt.pct(peak.sel_churners / peak.sel_customers, 2)} khách của nhóm).`);
    if (selMrr) bullets.push(`Nhóm đang đóng góp ${fmt.usd(selMrr)}/tháng (${fmt.pct(selMrr / k.all_mrr)} MRR); nếu không làm gì, dự kiến mất khoảng <b>${fmt.usd(selLoss)}</b> MRR mỗi tháng.`);
    if (small) bullets.push('<b>Lưu ý:</b> nhóm dưới 100 khách, tỷ lệ có thể dao động mạnh, nên xem như tham khảo.');
    $('#exInsight').innerHTML = insight(`Đang xem: ${esc(filterSummary())}`, bullets);

    const lift = allRate ? selRate / allRate : 0;
    $('#exKpis').innerHTML = [
      kpiCard('Số khách trong nhóm', fmt.int(k.sel_customers), `${fmt.pct(k.sel_customers / k.all_customers)} toàn công ty${small ? ' ' + badge('warn', 'mẫu nhỏ') : ''}`),
      kpiCard('Đã rời đi (24 tháng)', fmt.pct(selRate),
        filtered ? `${badge(lift > 1.05 ? 'bad' : lift < 0.95 ? 'good' : 'neutral', '×' + fmt.num(lift, 2), lift > 1.05 ? 'up' : lift < 0.95 ? 'down' : null)} so với mức chung ${fmt.pct(allRate)}` : `${fmt.int(k.all_churners)} khách`),
      kpiCard('Rời đi mỗi tháng', fmt.pct(selMonthly, 2), filtered ? `mức chung ${fmt.pct(allMonthly, 2)}` : 'bình quân 24 tháng'),
      kpiCard('MRR hiện tại', fmt.usd(selMrr), `${fmt.int(k.sel_active)} khách còn hoạt động · ${fmt.pct(k.all_mrr ? selMrr / k.all_mrr : 0)} MRR`),
      kpiCard('MRR dự kiến mất / tháng', fmt.usd(selLoss), filtered ? `${fmt.pct(allLoss ? selLoss / allLoss : 0)} mức mất toàn công ty` : 'nếu churn giữ như 24 tháng qua'),
    ].join('');

    const imp = $('#exImpact');
    imp.innerHTML = impacts.map(({ f, rows, spread }) => {
      const maxRate = Math.max(0.01, ...rows.map((r) => r.churners / r.customers));
      return `<div class="impact ${ex.filters[f.key] ? 'filtered' : ''}">
        <div class="impact-head"><b>${esc(f.label)}</b><span class="muted">${spread ? `chênh ${fmt.num(spread * 100, 1)} điểm %` : 'không đủ dữ liệu so sánh'}</span></div>
        ${rows.map((r) => {
          const rate = r.churners / r.customers;
          const on = (ex.filters[f.key] || []).includes(r.value);
          const tiny = r.customers < MIN_GROUP;
          const delta = rate - selRate;
          return `<button type="button" class="impact-row ${on ? 'on' : ''} ${tiny ? 'tiny' : ''}" data-f="${esc(f.key)}" data-v="${esc(r.value)}"
              title="${esc(valueLabel(f.key, r.value))}: ${fmt.int(r.churners)}/${fmt.int(r.customers)} khách đã rời đi">
            <span class="impact-name">${esc(valueLabel(f.key, r.value))}</span>
            <span class="impact-bar"><span style="width:${(100 * rate / maxRate).toFixed(1)}%" class="${rate > selRate * 1.2 && !tiny ? 'hot' : ''}"></span></span>
            <span class="impact-val num">${fmt.pct(rate)}</span>
            <span class="impact-n num">${tiny ? 'mẫu nhỏ' : fmt.int(r.customers) + ' khách'}</span>
            <span class="impact-delta num ${delta > 0.005 ? 'up' : delta < -0.005 ? 'down' : ''}">${(delta >= 0 ? '+' : '−') + fmt.num(Math.abs(delta) * 100, 1)}</span>
          </button>`;
        }).join('')}
      </div>`;
    }).join('');
    if (impacts[0]) $('#exImpactTitle').textContent = topFree
      ? `Yếu tố tạo khác biệt lớn nhất lúc này: ${topFree.f.label}`
      : 'Yếu tố nào tạo khác biệt lớn nhất?';

    drawExploreCharts(d, filtered);
  }

  function drawExploreCharts(d, filtered) {
    const s1 = css('--series-1'), muted = css('--text-3');
    const months = d.trend.map((t) => t.year_month);
    const selName = filtered ? 'Nhóm đang chọn' : 'Toàn công ty';
    const event = { silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' },
      label: { formatter: 'Tăng giá Fiber', color: muted, fontSize: 11 }, data: [{ xAxis: '2025-03' }] };

    const churnSeries = [{ name: selName, type: 'line', data: d.trend.map((t) => (t.sel_customers ? t.sel_churners / t.sel_customers : null)),
      showSymbol: false, lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 }, markLine: event }];
    churnSeries.push(filtered
      ? { name: 'Toàn công ty', type: 'line', data: d.trend.map((t) => t.all_churners / t.all_customers), showSymbol: false,
          lineStyle: { width: 2, color: css('--neutral-mark') }, itemStyle: { color: css('--neutral-mark') } }
      : { name: 'Chỉ tiêu', type: 'line', step: 'middle', data: d.trend.map((t) => t.churn_rate_target), showSymbol: false,
          lineStyle: { width: 2, type: 'dashed', color: muted }, itemStyle: { color: muted } });
    ex.charts['ex-churn'].setOption({
      legend: { ...baseOption().legend, data: churnSeries.map((s) => s.name) },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false }),
      yAxis: axis({ type: 'value', axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 1) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const t = d.trend[ps[0].dataIndex];
        return `<b>${t.year_month}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? '–' : fmt.pct(p.value, 2))).join('')
          + (t.sel_customers ? tipRow(null, 'Khách rời đi / trong nhóm', `${fmt.int(t.sel_churners)}/${fmt.int(t.sel_customers)}`) : '');
      } },
      series: churnSeries,
    }, true);

    const mrrSeries = [{ name: selName, type: 'line', data: d.trend.map((t) => t.sel_mrr), showSymbol: false,
      lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 }, areaStyle: { color: s1 + '1f' }, markLine: event }];
    if (!filtered) mrrSeries.push({ name: 'Chỉ tiêu', type: 'line', data: d.trend.map((t) => t.mrr_target_usd), showSymbol: false,
      lineStyle: { width: 2, type: 'dashed', color: muted }, itemStyle: { color: muted } });
    ex.charts['ex-mrr'].setOption({
      legend: { ...baseOption().legend, data: mrrSeries.map((s) => s.name) },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false }),
      yAxis: axis({ type: 'value', scale: !filtered, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.usdK(v) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const t = d.trend[ps[0].dataIndex];
        return `<b>${t.year_month}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, fmt.usd(p.value))).join('')
          + tipRow(null, 'MRR mất do khách rời đi', fmt.usd(t.sel_mrr_lost)) + (filtered ? tipRow(null, 'Tỷ trọng trong công ty', fmt.pct(t.sel_mrr / t.all_mrr)) : '');
      } },
      series: mrrSeries,
    }, true);

    // Retention: mẫu số ở tháng k = số khách đã đủ k tháng tính tới snapshot.
    const base = d.retention_base;
    const ks = d.retention.map((r) => r.k).sort((a, b) => a - b);
    const curve = ks.map((kk) => {
      const r = d.retention.find((x) => x.k === kk);
      const eligible = base.filter((b) => b.max_k >= kk);
      const allDen = sum(eligible, (b) => b.all_customers), selDen = sum(eligible, (b) => b.sel_customers);
      return { k: kk, cohorts: eligible.length, all: allDen ? r.all_active / allDen : null, sel: selDen >= MIN_GROUP ? r.sel_active / selDen : null };
    }).filter((c) => c.cohorts >= MIN_COHORTS);
    const retSeries = [{ name: selName, type: 'line', data: curve.map((c) => c.sel), showSymbol: false, connectNulls: false,
      lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 } }];
    if (filtered) retSeries.push({ name: 'Toàn công ty', type: 'line', data: curve.map((c) => c.all), showSymbol: false,
      lineStyle: { width: 2, color: css('--neutral-mark') }, itemStyle: { color: css('--neutral-mark') } });
    ex.charts['ex-retention'].setOption({
      legend: { ...baseOption().legend, data: retSeries.map((s) => s.name) },
      grid: { left: 8, right: 16, top: 36, bottom: 28, containLabel: true },
      xAxis: axis({ type: 'category', data: curve.map((c) => c.k), boundaryGap: false, name: 'Tháng kể từ kỳ cước đầu',
        nameLocation: 'middle', nameGap: 26, nameTextStyle: { color: muted, fontSize: 11 } }),
      yAxis: axis({ type: 'value', min: 0, max: 1, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Tháng ${ps[0].axisValue}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? 'mẫu nhỏ' : fmt.pct(p.value))).join('') },
      series: retSeries,
    }, true);

    const tByMonth = Object.fromEntries(d.tickets.map((t) => [t.year_month, t]));
    const tickSeries = [{ name: selName, type: 'line', showSymbol: false, lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 }, markLine: event,
      data: d.trend.map((t) => (t.sel_customers ? 100 * ((tByMonth[t.year_month] || {}).sel_billing || 0) / t.sel_customers : null)) }];
    if (filtered) tickSeries.push({ name: 'Toàn công ty', type: 'line', showSymbol: false, lineStyle: { width: 2, color: css('--neutral-mark') },
      itemStyle: { color: css('--neutral-mark') }, data: d.trend.map((t) => 100 * ((tByMonth[t.year_month] || {}).all_billing || 0) / t.all_customers) });
    ex.charts['ex-tickets'].setOption({
      legend: { ...baseOption().legend, data: tickSeries.map((s) => s.name) },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false }),
      yAxis: axis({ type: 'value', min: 0 }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>${months[ps[0].dataIndex]}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, p.value == null ? '–' : fmt.num(p.value, 1) + ' / 100 khách')).join('') },
      series: tickSeries,
    }, true);
  }

  async function openCustomerList() {
    $('#drawerTitle').textContent = filterSummary();
    $('#drawerBody').innerHTML = '<div class="skeleton"></div>';
    $('#drawer').classList.add('open'); $('#drawerBackdrop').classList.add('open');
    $('#drawer').setAttribute('aria-hidden', 'false');
    try {
      const res = await fetch('/api/explore/customers', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ filters: ex.filters }) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      renderCustomerTable(data.rows, data.limit);
    } catch (e) {
      $('#drawerBody').innerHTML = `<p class="error">Không tải được danh sách khách: ${esc(e.message)}</p>`;
    }
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

  /* ---------- Trang 4: What-if ---------- */
  async function renderWhatif(root) {
    const base = await api('whatif_base');
    const m2m = base.find((b) => b.contract_type === 'Month-to-month');
    const oneY = base.find((b) => b.contract_type === 'One year');
    root.innerHTML = `
      <div class="grid wide-left">
        <div class="card">
          <div class="card-head"><div><h3 class="card-title" id="wf-title">Kịch bản</h3>
            <div class="card-sub">Số khách còn lại của nhóm được chuyển đổi, theo hai nhịp churn.</div></div></div>
          <div class="chart tall" id="c-whatif"></div>
        </div>
        <div class="card">
          <h3 class="card-title" style="margin-bottom:14px">Tham số</h3>
          <div class="control"><div class="control-row"><label for="shift">Khách Month-to-month chuyển sang 1 năm</label><output id="shiftOut" class="num"></output></div>
            <input type="range" id="shift" min="0" max="50" step="5" value="20"></div>
          <div class="control"><div class="control-row"><label for="discount">Chiết khấu cho khách chuyển đổi</label><output id="discountOut" class="num"></output></div>
            <input type="range" id="discount" min="0" max="30" step="1" value="10"></div>
          <div class="control"><div class="control-row"><label for="horizon">Tầm nhìn</label><output id="horizonOut" class="num"></output></div>
            <input type="range" id="horizon" min="6" max="24" step="6" value="12"></div>
          <ul class="assumptions">
            <li>Nhóm chuyển đổi mang churn của One year (${fmt.pct(oneY.monthly_churn_rate, 2)}/tháng) thay vì Month-to-month (${fmt.pct(m2m.monthly_churn_rate, 2)}/tháng).</li>
            <li>ARPU giữ như Month-to-month (${fmt.usd2(m2m.arpu_usd)}); chiết khấu trừ trên doanh thu của khách chuyển đổi còn ở lại.</li>
            <li>Chênh lệch tương quan, chưa phải nhân quả, nên đây là cận trên. Công thức trùng sql/analysis/07_whatif_contract.sql.</li>
          </ul>
        </div>
      </div>
      <div class="grid kpis" id="wf-kpis"></div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Số liệu nền theo loại hợp đồng</h3>
        <div class="card-sub">Khách và MRR tại tháng snapshot; churn theo tháng trong cửa sổ 24 tháng.</div></div></div>
        <div class="table-wrap"><table><thead><tr><th>Hợp đồng</th><th class="r">Khách đang hoạt động</th><th class="r">MRR hiện tại</th>
          <th class="r">ARPU</th><th class="r">Churn / tháng</th><th class="r">Rời đi bq / tháng</th><th class="r">MRR mất bq / tháng</th></tr></thead>
          <tbody>${base.map((b) => `<tr><td>${esc(b.contract_type)}</td><td class="r num">${fmt.int(b.active_customers)}</td>
            <td class="r num">${fmt.usd(b.current_mrr_usd)}</td><td class="r num">${fmt.usd2(b.arpu_usd)}</td>
            <td class="r num">${fmt.pct(b.monthly_churn_rate, 2)}</td><td class="r num">${fmt.num(b.avg_churners_per_month, 1)}</td>
            <td class="r num">${fmt.usd(b.avg_mrr_lost_per_month_usd)}</td></tr>`).join('')}</tbody></table></div></div>`;

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
      $('#wf-title').textContent = moved
        ? `Chuyển ${fmt.int(moved)} khách giữ thêm ${fmt.int(Math.round(extra))} khách sau ${H} tháng, lãi ròng ${fmt.usd(net)}`
        : 'Chọn tỷ lệ chuyển đổi để xem kịch bản';
      $('#wf-kpis').innerHTML = [
        kpiCard('Khách được chuyển đổi', fmt.int(moved), `MRR ${fmt.usd(moved * arpu)}`),
        kpiCard('Khách rời đi tránh được (tháng 1)', fmt.num(moved * (cM - c1), 1), 'mỗi tháng, ở đầu kỳ'),
        kpiCard(`MRR giữ thêm ở tháng ${H}`, fmt.usd(extra * arpu), `${fmt.int(Math.round(extra))} khách`),
        kpiCard(`Doanh thu giữ thêm (${H} tháng)`, fmt.usd(gross), `chi phí chiết khấu ${fmt.usd(cost)}`),
        kpiCard('Lợi ích ròng', fmt.usd(net), `${badge(net >= 0 ? 'good' : 'bad', net >= 0 ? 'Có lãi' : 'Lỗ')} hoà vốn tại chiết khấu ${fmt.pct(breakEven, 1)}`),
      ].join('');
      chart.setOption({
        legend: { ...baseOption().legend, data: ['Chuyển sang One year', 'Giữ Month-to-month'] },
        grid: { left: 8, right: 16, top: 36, bottom: 28, containLabel: true },
        xAxis: axis({ type: 'category', data: ks, boundaryGap: false, name: 'Tháng', nameLocation: 'middle', nameGap: 26, nameTextStyle: { color: css('--text-3'), fontSize: 11 } }),
        yAxis: axis({ type: 'value', min: 0 }),
        tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Tháng ${ps[0].axisValue}</b>` + ps.map((p) => tipRow(p.color, p.seriesName, fmt.num(p.value, 0) + ' khách')).join('')
          + tipRow(null, 'Chênh lệch', fmt.num(ps[0].value - (ps[1] ? ps[1].value : 0), 0) + ' khách') },
        series: [
          { name: 'Chuyển sang One year', type: 'line', data: move, showSymbol: false, lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 },
            areaStyle: { color: s1 + '1a' } },
          { name: 'Giữ Month-to-month', type: 'line', data: stay, showSymbol: false, lineStyle: { width: 2, color: s2 }, itemStyle: { color: s2 } },
        ],
      }, true);
    };
    ['shift', 'discount', 'horizon'].forEach((id) => $('#' + id).addEventListener('input', update));
    update();
  }

  /* ---------- Trang 5: Data Quality ---------- */
  async function renderQuality(root) {
    const [checks, rejected, steps] = await Promise.all([api('dq_checks'), api('rejected'), api('etl_steps')]);
    const count = (s) => checks.filter((c) => c.status === s).length;
    const totalRejected = sum(rejected, (r) => r.rejected_rows);
    const pipeline = steps.find((s) => s.layer === 'pipeline');
    const groups = [...new Set(checks.map((c) => c.check_group))].sort();
    const fmtVal = (v) => (v == null ? '–' : fmt.num(v, Number.isInteger(v) ? 0 : 2));

    root.innerHTML = `
      ${insight(`${count('PASS')}/${checks.length} kiểm tra đạt; ${count('WARN')} cảnh báo đã biết, ${count('FAIL')} lỗi cần xử lý.`, [
        `${fmt.int(totalRejected)} bản ghi bị loại, có lý do và JSON gốc trong clean.rejected_records; không xoá im lặng.`,
        ...checks.filter((c) => c.status === 'WARN').map((c) => `${esc(c.check_name)}: ${esc(c.note || '')}`),
      ])}
      <div class="grid kpis">
        ${kpiCard('Đạt', `<span class="status PASS">${count('PASS')}</span>`, 'kiểm tra PASS')}
        ${kpiCard('Cảnh báo', `<span class="status WARN">${count('WARN')}</span>`, 'lệch đã biết, đã xử lý')}
        ${kpiCard('Lỗi', `<span class="status FAIL">${count('FAIL')}</span>`, 'cần điều tra')}
        ${kpiCard('Bản ghi bị loại', fmt.int(totalRejected), `${rejected.length} loại lý do`)}
        ${kpiCard('Lần chạy ETL gần nhất', pipeline ? fmt.num(pipeline.duration_ms / 1000, 1) + ' giây' : '–',
          pipeline ? esc(new Date(pipeline.finished_at).toLocaleString('vi-VN')) : '')}
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Kết quả kiểm tra</h3>
        <div class="card-sub">Trước = đo trên stg (dữ liệu gốc) · Sau = đo trên clean/mart · Loại = số dòng chuyển sang rejected</div></div></div>
        <div class="table-wrap" style="max-height:none"><table><thead><tr><th>Trạng thái</th><th>Kiểm tra</th><th>Đối tượng</th>
          <th class="r">Trước</th><th class="r">Sau</th><th class="r">Loại</th><th>Ghi chú</th></tr></thead>
          <tbody>${groups.map((g) => `<tr><td colspan="7" style="background:var(--surface-2);font-weight:600">${esc(g)}</td></tr>` +
            checks.filter((c) => c.check_group === g).map((c) => `<tr>
              <td><span class="status ${c.status}">${c.status}</span></td><td class="wrap">${esc(c.check_name)}</td>
              <td class="wrap muted">${esc(c.object_name || '')}</td><td class="r num">${fmtVal(c.value_before)}</td>
              <td class="r num">${fmtVal(c.value_after)}</td><td class="r num">${fmtVal(c.value_rejected)}</td>
              <td class="wrap muted">${esc(c.note || c.expected_rule || '')}</td></tr>`).join('')).join('')}
          </tbody></table></div></div>
      <div class="grid two">
        ${cardHtml('c-rej', `${fmt.int(totalRejected)} bản ghi bị loại theo lý do`, 'Bảng nguồn · mã lý do', 'short')}
        <div class="card"><div class="card-head"><div><h3 class="card-title">Các bước ETL của lần chạy gần nhất</h3>
          <div class="card-sub">Từ dbo.etl_log</div></div></div>
          <div class="table-wrap" style="max-height:260px"><table><thead><tr><th>Bước</th><th>Trạng thái</th><th class="r">Đọc</th><th class="r">Ghi</th><th class="r">Thời gian</th></tr></thead>
            <tbody>${steps.filter((s) => s.layer !== 'pipeline').map((s) => `<tr><td>${esc(s.step_name)}</td>
              <td><span class="status ${s.status === 'SUCCESS' ? 'PASS' : 'FAIL'}">${esc(s.status)}</span></td>
              <td class="r num">${s.rows_read == null ? '–' : fmt.int(s.rows_read)}</td><td class="r num">${s.rows_written == null ? '–' : fmt.int(s.rows_written)}</td>
              <td class="r num">${fmt.num(s.duration_ms / 1000, 1)} s</td></tr>`).join('')}</tbody></table></div></div>
      </div>`;

    const rj = rejected.slice().reverse();
    mountChart('c-rej', {
      grid: { left: 8, right: 40, top: 8, bottom: 4, containLabel: true },
      xAxis: axis({ type: 'value', axisLabel: { show: false }, splitLine: { show: false } }),
      yAxis: axis({ type: 'category', data: rj.map((r) => `${r.source_table.replace('stg.', '')} · ${r.reason_code}`), axisLine: { show: false },
        axisLabel: { ...axis().axisLabel, color: css('--text-2') } }),
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
        const r = rj[p.dataIndex];
        return `<b>${esc(r.reason_code)}</b>${tipRow(null, 'Bảng', esc(r.source_table))}${tipRow(null, 'Số dòng', fmt.int(r.rejected_rows))}<div style="max-width:260px;white-space:normal">${esc(r.sample_detail)}</div>`;
      } },
      series: [{ type: 'bar', barMaxWidth: 16, data: rj.map((r) => r.rejected_rows), itemStyle: { color: css('--series-1'), borderRadius: [0, 4, 4, 0] },
        label: { show: true, position: 'right', fontSize: 11, color: css('--text-2'), formatter: (p) => fmt.int(p.value) } }],
    });
  }

  /* ---------- điều hướng, theme, khởi động ---------- */
  async function show(page) {
    if (!PAGES[page]) page = 'explore';
    state.page = page;
    const def = PAGES[page];
    document.querySelectorAll('.nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === page));
    document.querySelectorAll('.page').forEach((p) => p.classList.toggle('active', p.id === 'page-' + page));
    $('#pageTitle').textContent = def.title; $('#crumb').textContent = def.crumb;
    document.title = `${def.title} · Telco Churn Analytics`;
    $('#sidebar').classList.remove('open');
    closeDrawer();
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
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDrawer(); });
  // Bộ lọc của trang Khám phá nằm sau dấu ? trong hash; chỉ vẽ lại trang khi đổi trang.
  const pageFromHash = () => location.hash.slice(1).split('?')[0];
  window.addEventListener('hashchange', () => { if (pageFromHash() !== state.page) show(pageFromHash()); });
  window.addEventListener('resize', () => Object.values(state.charts).forEach((c) => c.resize()));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => show(state.page));

  loadMeta();
  show(pageFromHash() || 'explore');
})();
