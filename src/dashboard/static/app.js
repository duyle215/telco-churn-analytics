/* Telco Churn Analytics: SPA nhỏ, dữ liệu lấy từ /api/* (các view mart). */
(() => {
  'use strict';

  const PAGES = {
    overview: { title: 'Finance Overview', crumb: 'Báo cáo', period: true, render: renderOverview },
    drivers: { title: 'Churn Drivers', crumb: 'Báo cáo', period: false, render: renderDrivers },
    risk: { title: 'Risk Segments', crumb: 'Báo cáo', period: false, render: renderRisk },
    whatif: { title: 'What-if Scenario', crumb: 'Báo cáo', period: false, render: renderWhatif },
    quality: { title: 'Data Quality', crumb: 'Vận hành', period: false, render: renderQuality },
  };
  // Màu gắn với thực thể, không theo thứ hạng: Fiber luôn xanh, DSL luôn cam, không internet luôn aqua.
  const INTERNET_COLOR = { 'Fiber optic': '--series-1', 'DSL': '--series-2', 'No': '--series-3' };
  const DRIVER_ORDER = ['Contract', 'Tenure group', 'Internet service', 'Add-on services', 'Tech support',
    'Online security', 'Payment method', 'Paperless billing', 'Senior citizen'];

  const state = { period: 'all', page: null, cache: {}, charts: {} };

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

  /* ---------- Trang 1: Finance Overview ---------- */
  async function renderOverview(root) {
    const [kpiAll, anomaly] = await Promise.all([api('kpi'), api('anomaly')]);
    const rows = state.period === 'all' ? kpiAll : kpiAll.filter((r) => String(r.year) === state.period);
    const months = rows.map((r) => r.year_month);
    const first = rows[0], last = rows[rows.length - 1];
    const avgChurn = sum(rows, (r) => r.churn_rate) / rows.length;
    const avgTarget = sum(rows, (r) => r.churn_rate_target) / rows.length;
    const above = rows.filter((r) => r.churn_rate > r.churn_rate_target);
    const peak = rows.reduce((a, r) => (r.churn_rate > a.churn_rate ? r : a), rows[0]);
    const mrrLost = sum(rows, (r) => r.mrr_lost_usd);
    const peakLost = rows.reduce((a, r) => (r.mrr_lost_usd > a.mrr_lost_usd ? r : a), rows[0]);
    const mrrBelow = rows.filter((r) => r.mrr_usd < r.mrr_target_usd);
    const imputed = rows.filter((r) => r.imputed_rows > r.customers / 2).map((r) => r.year_month);
    const custGrowth = last.customers / first.customers - 1;
    const mrrVsTarget = last.mrr_vs_target_pct;

    root.innerHTML = `
      ${insight(`Churn vượt chỉ tiêu ${above.length}/${rows.length} tháng; đỉnh ${fmt.pct(peak.churn_rate, 2)} vào ${peak.year_month}.`, [
        `MRR mất do churn cao nhất ở ${peakLost.year_month}: ${fmt.usd(peakLost.mrr_lost_usd)}, gấp ${fmt.num(peakLost.mrr_lost_usd / (mrrLost / rows.length), 1)} lần bình quân kỳ.`,
        `MRR hụt chỉ tiêu ${mrrBelow.length}/${rows.length} tháng; tháng cuối kỳ ${mrrVsTarget >= 0 ? 'vượt' : 'hụt'} ${fmt.pct(Math.abs(mrrVsTarget))}.`,
      ])}
      <div class="grid kpis">
        ${kpiCard('Khách có tính cước (cuối kỳ)', fmt.int(last.customers),
          `${badge(custGrowth >= 0 ? 'good' : 'bad', fmt.pct(custGrowth), custGrowth >= 0 ? 'up' : 'down')} so với đầu kỳ`)}
        ${kpiCard('Churn rate bình quân/tháng', fmt.pct(avgChurn, 2),
          `${badge(avgChurn > avgTarget ? 'bad' : 'good', fmt.pp(avgChurn - avgTarget), avgChurn > avgTarget ? 'up' : 'down')} so với chỉ tiêu ${fmt.pct(avgTarget, 2)}`)}
        ${kpiCard('MRR tháng cuối kỳ', fmt.usd(last.mrr_usd),
          `${badge(mrrVsTarget >= 0 ? 'good' : 'bad', fmt.pct(mrrVsTarget), mrrVsTarget >= 0 ? 'up' : 'down')} so với chỉ tiêu`)}
        ${kpiCard('MRR mất do churn (cả kỳ)', fmt.usd(mrrLost), `${fmt.int(sum(rows, (r) => r.churners))} khách rời đi`)}
        ${kpiCard('ARPU tháng cuối kỳ', fmt.usd2(last.arpu_usd), `đầu kỳ ${fmt.usd2(first.arpu_usd)}`)}
      </div>
      <div class="grid two">
        ${cardHtml('c-mrr', `MRR ${mrrBelow.length === 0 ? 'vượt chỉ tiêu mọi tháng' : `hụt chỉ tiêu ${mrrBelow.length}/${rows.length} tháng`}`,
          'MRR (USD) so với chỉ tiêu của Finance. Điểm rỗng: tháng ước lượng do sự cố billing.')}
        ${cardHtml('c-churn', `Churn vượt chỉ tiêu ${above.length}/${rows.length} tháng`,
          'Churn rate theo tháng. Cột đỏ: vượt chỉ tiêu.')}
      </div>
      <div class="grid two">
        ${cardHtml('c-lost', `MRR mất do churn đỉnh ${fmt.usd(peakLost.mrr_lost_usd)} vào ${peakLost.year_month}`,
          'Cước tháng cuối của khách rời đi: doanh thu định kỳ sẽ mất từ tháng sau.')}
        ${cardHtml('c-warn', 'Cảnh báo sớm: ticket Billing', 'Số ticket Billing theo tháng và dải bình thường (trung bình ± 2σ của 24 tháng).')}
      </div>`;

    const s1 = css('--series-1'), s2 = css('--series-2'), crit = css('--critical'), muted = css('--text-3');
    const eventLine = months.includes('2025-03') ? {
      silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' },
      label: { formatter: 'Tăng giá Fiber', color: muted, fontSize: 11 }, data: [{ xAxis: '2025-03' }],
    } : undefined;
    const imputedPoint = imputed.length ? {
      silent: true, symbol: 'circle', symbolSize: 9,
      itemStyle: { color: css('--surface'), borderColor: muted, borderWidth: 2 },
      label: { formatter: 'ước lượng', color: muted, fontSize: 10, position: 'bottom', distance: 6 },
      data: imputed.map((m) => ({ coord: [m, rows.find((r) => r.year_month === m).mrr_usd] })),
    } : undefined;

    mountChart('c-mrr', {
      legend: { ...baseOption().legend, data: ['MRR', 'Chỉ tiêu'] },
      xAxis: axis({ type: 'category', data: months, boundaryGap: false }),
      yAxis: axis({ type: 'value', scale: true, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.usdK(v) } }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const r = rows[ps[0].dataIndex];
        return `<b>${r.year_month}</b>${tipRow(s1, 'MRR', fmt.usd(r.mrr_usd))}${tipRow(muted, 'Chỉ tiêu', fmt.usd(r.mrr_target_usd))}
          ${tipRow(null, 'Chênh lệch', fmt.pct(r.mrr_vs_target_pct))}${tipRow(null, 'MoM', r.mrr_mom_pct == null ? '–' : fmt.pct(r.mrr_mom_pct))}
          ${r.imputed_rows > r.customers / 2 ? '<div style="color:' + muted + '">Số ước lượng (sự cố billing)</div>' : ''}`;
      } },
      series: [
        { name: 'MRR', type: 'line', data: rows.map((r) => r.mrr_usd), symbol: 'circle', symbolSize: 6, showSymbol: false,
          lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 },
          areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: s1 + '33' }, { offset: 1, color: s1 + '00' }]) },
          markLine: eventLine, markPoint: imputedPoint },
        { name: 'Chỉ tiêu', type: 'line', data: rows.map((r) => r.mrr_target_usd), showSymbol: false,
          lineStyle: { width: 2, type: 'dashed', color: muted }, itemStyle: { color: muted } },
      ],
    });

    mountChart('c-churn', {
      legend: { ...baseOption().legend, data: ['Churn rate', 'Chỉ tiêu'] },
      xAxis: axis({ type: 'category', data: months }),
      yAxis: axis({ type: 'value', axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 1) } }),
      tooltip: { ...baseOption().tooltip, axisPointer: { type: 'shadow' }, formatter: (ps) => {
        const r = rows[ps[0].dataIndex];
        return `<b>${r.year_month}</b>${tipRow(r.churn_rate > r.churn_rate_target ? crit : s1, 'Churn rate', fmt.pct(r.churn_rate, 2))}
          ${tipRow(muted, 'Chỉ tiêu', fmt.pct(r.churn_rate_target, 2))}${tipRow(null, 'Khách rời đi', fmt.int(r.churners))}${tipRow(null, 'Khách trong tháng', fmt.int(r.customers))}`;
      } },
      series: [
        { name: 'Churn rate', type: 'bar', barMaxWidth: 22, itemStyle: { color: s1 },
          data: rows.map((r) => ({ value: r.churn_rate, itemStyle: { color: r.churn_rate > r.churn_rate_target ? crit : s1, borderRadius: [4, 4, 0, 0] } })),
          markLine: eventLine },
        { name: 'Chỉ tiêu', type: 'line', step: 'middle', z: 5, data: rows.map((r) => r.churn_rate_target), showSymbol: false,
          lineStyle: { width: 2, type: 'dashed', color: muted }, itemStyle: { color: muted } },
      ],
    });

    mountChart('c-lost', {
      xAxis: axis({ type: 'category', data: months }),
      yAxis: axis({ type: 'value', axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.usdK(v) } }),
      tooltip: { ...baseOption().tooltip, axisPointer: { type: 'shadow' }, formatter: (ps) => {
        const r = rows[ps[0].dataIndex];
        return `<b>${r.year_month}</b>${tipRow(s2, 'MRR mất', fmt.usd(r.mrr_lost_usd))}${tipRow(null, 'Khách rời đi', fmt.int(r.churners))}`;
      } },
      series: [{ name: 'MRR mất do churn', type: 'bar', barMaxWidth: 22, data: rows.map((r) => r.mrr_lost_usd),
        itemStyle: { color: s2, borderRadius: [4, 4, 0, 0] },
        label: { show: true, position: 'top', fontSize: 10, color: css('--text-2'),
          formatter: (p) => (rows[p.dataIndex].year_month === peakLost.year_month ? fmt.usdK(p.value) : '') } }],
    });

    const bt = anomaly.filter((a) => a.segment === 'All' && a.metric === 'Billing tickets' && months.includes(a.year_month));
    const flagged = bt.filter((a) => a.is_anomaly);
    const top = flagged.reduce((a, r) => (!a || r.z_score > a.z_score ? r : a), null);
    if (top) $('#c-warn-title').textContent = `Ticket Billing vượt ngưỡng ${flagged.map((f) => f.year_month).join(', ')} (z = ${fmt.num(top.z_score, 1)})`;
    mountChart('c-warn', {
      legend: { ...baseOption().legend, data: ['Ticket Billing', 'Dải bình thường'] },
      xAxis: axis({ type: 'category', data: bt.map((a) => a.year_month), boundaryGap: false }),
      yAxis: axis({ type: 'value' }),
      tooltip: { ...baseOption().tooltip, formatter: (ps) => {
        const r = bt[ps[0].dataIndex];
        return `<b>${r.year_month}</b>${tipRow(s1, 'Ticket Billing', fmt.int(r.value))}${tipRow(null, 'Bình quân 24 tháng', fmt.num(r.mean_value, 1))}
          ${tipRow(null, 'Ngưỡng trên (+2σ)', fmt.num(r.upper_bound, 1))}${tipRow(r.is_anomaly ? crit : null, 'z-score', fmt.num(r.z_score, 2))}`;
      } },
      series: [
        { name: 'lower', type: 'line', stack: 'band', data: bt.map((a) => Math.max(0, a.lower_bound)), showSymbol: false, lineStyle: { opacity: 0 }, silent: true },
        { name: 'Dải bình thường', type: 'line', stack: 'band', data: bt.map((a) => a.upper_bound - Math.max(0, a.lower_bound)), showSymbol: false,
          lineStyle: { opacity: 0 }, areaStyle: { color: css('--surface-2') }, itemStyle: { color: css('--border-strong') }, silent: true },
        { name: 'Ticket Billing', type: 'line', data: bt.map((a) => ({ value: a.value,
            symbolSize: a.is_anomaly ? 10 : 6, itemStyle: { color: a.is_anomaly ? crit : s1, borderColor: css('--surface'), borderWidth: 2 } })),
          lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 }, showSymbol: true, symbol: 'circle' },
      ],
    });
  }

  /* ---------- Trang 2: Churn Drivers ---------- */
  async function renderDrivers(root) {
    const [drivers, ic, cohort] = await Promise.all([api('drivers'), api('internet_contract'), api('cohort')]);
    const byDriver = {};
    drivers.forEach((d) => (byDriver[d.driver] = byDriver[d.driver] || []).push(d));
    const spread = DRIVER_ORDER.filter((d) => byDriver[d]).map((d) => {
      const rs = byDriver[d];
      return { d, max: Math.max(...rs.map((r) => r.churn_rate)), min: Math.min(...rs.map((r) => r.churn_rate)) };
    }).sort((a, b) => (b.max - b.min) - (a.max - a.min));
    const overall = sum(drivers.filter((d) => d.driver === 'Contract'), (r) => r.churners) / sum(drivers.filter((d) => d.driver === 'Contract'), (r) => r.customers);

    const contracts = [...new Set(ic.map((r) => r.contract_type))];
    const ratio = contracts.map((c) => {
      const f = ic.find((r) => r.contract_type === c && r.internet_service === 'Fiber optic');
      const d = ic.find((r) => r.contract_type === c && r.internet_service === 'DSL');
      return f.churn_rate / d.churn_rate;
    });
    const weighted = {};
    cohort.forEach((r) => { const w = (weighted[r.month_offset] = weighted[r.month_offset] || { a: 0, s: 0, n: 0 }); w.a += r.active_customers; w.s += r.cohort_size; w.n += 1; });
    // Mốc nào còn quá ít cohort đủ tuổi thì bỏ, tránh đuôi đường cong nhảy lên do nhiễu mẫu nhỏ.
    const MIN_COHORTS = 6;
    const curve = Object.keys(weighted).map(Number).sort((a, b) => a - b).filter((k) => weighted[k].n >= MIN_COHORTS)
      .map((k) => ({ k, v: weighted[k].a / weighted[k].s, n: weighted[k].n }));
    const drop1 = 1 - curve.find((c) => c.k === 1).v;

    root.innerHTML = `
      ${insight(`${esc(spread[0].d)} phân tách rủi ro mạnh nhất (churn ${fmt.pct(spread[0].min)} đến ${fmt.pct(spread[0].max)}), tiếp theo là ${esc(spread[1].d)} và ${esc(spread[2].d)}.`, [
        `Churn bình quân 24 tháng của khách có tính cước: ${fmt.pct(overall)}. Đường đứt nét trong mỗi biểu đồ là mức bình quân này.`,
        `Fiber churn gấp ${fmt.num(Math.min(...ratio), 1)}–${fmt.num(Math.max(...ratio), 1)} lần DSL ngay trong cùng loại hợp đồng, nên Fiber là yếu tố rủi ro riêng.`,
        `Mất ${fmt.pct(drop1)} khách ngay sau kỳ cước đầu tiên: onboarding là điểm rò rỉ lớn nhất.`,
      ])}
      <div class="grid three" id="driverGrid">
        ${DRIVER_ORDER.filter((d) => byDriver[d]).map((d, i) => {
          const rs = byDriver[d]; const hi = rs.reduce((a, r) => (r.churn_rate > a.churn_rate ? r : a), rs[0]);
          return cardHtml(`c-drv-${i}`, esc(d), `Cao nhất: ${esc(hi.driver_value)} (${fmt.pct(hi.churn_rate)})`, 'short');
        }).join('')}
      </div>
      <div class="grid two">
        ${cardHtml('c-ic', `Fiber churn gấp ${fmt.num(Math.min(...ratio), 1)}–${fmt.num(Math.max(...ratio), 1)} lần DSL trong cùng loại hợp đồng`,
          'Churn rate 24 tháng theo loại hợp đồng và loại internet (phân tích có kiểm soát).')}
        ${cardHtml('c-curve', `Mất ${fmt.pct(drop1)} khách ngay sau kỳ cước đầu tiên`,
          'Retention bình quân có trọng số, cohort ký từ 12/2023 (tránh thiên lệch sống sót); chỉ vẽ mốc có ≥ 6 cohort.')}
      </div>
      ${cardHtml('c-cohort', 'Cohort retention theo tháng ký hợp đồng', 'Tỷ lệ khách còn giữ, đọc theo thang màu bên dưới. Cột = số tháng kể từ kỳ cước đầu.', 'tall')}`;

    const s1 = css('--series-1'), muted = css('--text-3');
    DRIVER_ORDER.filter((d) => byDriver[d]).forEach((d, i) => {
      const rs = byDriver[d].slice().sort((a, b) => (a.sort_order ?? 99) - (b.sort_order ?? 99) || b.churn_rate - a.churn_rate).reverse();
      mountChart(`c-drv-${i}`, {
        grid: { left: 8, right: 44, top: 8, bottom: 4, containLabel: true },
        xAxis: axis({ type: 'value', max: Math.max(0.6, ...rs.map((r) => r.churn_rate)), axisLabel: { show: false }, splitLine: { show: false } }),
        yAxis: axis({ type: 'category', data: rs.map((r) => r.driver_value), axisLine: { show: false },
          axisLabel: { ...axis().axisLabel, color: css('--text-2'), width: 160, overflow: 'truncate' } }),
        tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
          const r = rs[p.dataIndex];
          return `<b>${esc(r.driver_value)}</b>${tipRow(s1, 'Churn rate', fmt.pct(r.churn_rate))}${tipRow(null, 'Khách', fmt.int(r.customers))}
            ${tipRow(null, 'Rời đi', fmt.int(r.churners))}${tipRow(null, 'So với bình quân', '×' + fmt.num(r.lift_vs_overall, 2))}`;
        } },
        series: [{ type: 'bar', barMaxWidth: 16, data: rs.map((r) => r.churn_rate), itemStyle: { color: s1, borderRadius: [0, 4, 4, 0] },
          label: { show: true, position: 'right', fontSize: 11, color: css('--text-2'), formatter: (p) => fmt.pct(p.value, 0) },
          markLine: { silent: true, symbol: 'none', lineStyle: { color: muted, type: 'dashed' }, label: { show: false }, data: [{ xAxis: overall }] } }],
      });
    });

    const internets = ['Fiber optic', 'DSL', 'No'];
    const icLabel = { 'Fiber optic': 'Fiber optic', 'DSL': 'DSL', 'No': 'Không internet' };
    mountChart('c-ic', {
      legend: { ...baseOption().legend, data: internets.map((n) => icLabel[n]) },
      xAxis: axis({ type: 'category', data: contracts }),
      yAxis: axis({ type: 'value', axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) } }),
      tooltip: { ...baseOption().tooltip, axisPointer: { type: 'shadow' }, formatter: (ps) => `<b>${ps[0].axisValue}</b>` + ps.map((p) => {
        const r = ic.find((x) => x.contract_type === p.axisValue && icLabel[x.internet_service] === p.seriesName);
        return tipRow(p.color, p.seriesName, `${fmt.pct(r.churn_rate)} · ${fmt.int(r.customers)} khách`);
      }).join('') },
      series: internets.map((n) => ({
        name: icLabel[n], type: 'bar', barMaxWidth: 26, barGap: '12%',
        itemStyle: { color: css(INTERNET_COLOR[n]), borderRadius: [4, 4, 0, 0], borderColor: css('--surface'), borderWidth: 1 },
        data: contracts.map((c) => ic.find((r) => r.contract_type === c && r.internet_service === n).churn_rate),
        label: { show: n !== 'No', position: 'top', fontSize: 10, color: css('--text-2'), formatter: (p) => fmt.pct(p.value, 0) },
      })),
    });

    mountChart('c-curve', {
      xAxis: axis({ type: 'category', data: curve.map((c) => c.k), name: 'Tháng kể từ kỳ cước đầu', nameLocation: 'middle', nameGap: 26,
        nameTextStyle: { color: muted, fontSize: 11 }, boundaryGap: false }),
      yAxis: axis({ type: 'value', min: 0.4, max: 1, axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) } }),
      grid: { left: 8, right: 16, top: 16, bottom: 28, containLabel: true },
      tooltip: { ...baseOption().tooltip, formatter: (ps) => `<b>Tháng ${ps[0].axisValue}</b>${tipRow(s1, 'Retention', fmt.pct(ps[0].value))}${tipRow(null, 'Số cohort', curve[ps[0].dataIndex].n)}` },
      series: [{ type: 'line', data: curve.map((c) => c.v), lineStyle: { width: 2, color: s1 }, itemStyle: { color: s1 }, showSymbol: false,
        areaStyle: { color: s1 + '1f' } }],
    });

    const cohorts = [...new Set(cohort.map((r) => r.cohort_label))];
    const maxOffset = Math.max(...cohort.map((r) => r.month_offset));
    mountChart('c-cohort', {
      grid: { left: 8, right: 16, top: 8, bottom: 48, containLabel: true },
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
        const r = cohort.find((x) => x.cohort_label === cohorts[p.value[1]] && x.month_offset === p.value[0]);
        return `<b>Cohort ${r.cohort_label} · tháng ${r.month_offset}</b>${tipRow(null, 'Retention', fmt.pct(r.retention_rate))}
          ${tipRow(null, 'Còn hoạt động', `${fmt.int(r.active_customers)}/${fmt.int(r.cohort_size)}`)}`;
      } },
      xAxis: axis({ type: 'category', data: [...Array(maxOffset + 1).keys()], splitArea: { show: false } }),
      yAxis: axis({ type: 'category', data: cohorts, inverse: true }),
      visualMap: { min: 0.4, max: 1, calculable: false, orient: 'horizontal', left: 'center', bottom: 0, itemHeight: 160,
        inRange: { color: [css('--seq-100'), css('--seq-300'), css('--seq-500'), css('--seq-700')] },
        text: ['100%', '40%'], textStyle: { color: muted, fontSize: 11 } },
      series: [{ type: 'heatmap', data: cohort.map((r) => [r.month_offset, cohorts.indexOf(r.cohort_label), r.retention_rate]),
        itemStyle: { borderColor: css('--surface'), borderWidth: 2, borderRadius: 3 }, emphasis: { itemStyle: { borderColor: css('--text') } } }],
    });
  }

  /* ---------- Trang 3: Risk Segments ---------- */
  async function renderRisk(root) {
    const segs = await api('risk_segments');
    const total = sum(segs, (s) => s.expected_mrr_loss_usd);
    const high = segs.filter((s) => s.is_high_risk);
    const highLoss = sum(high, (s) => s.expected_mrr_loss_usd);
    const top3 = segs.slice(0, 3);
    const overall = segs[0].overall_monthly_churn_rate;

    root.innerHTML = `
      ${insight(`${high.length} phân khúc chiếm ${fmt.pct(highLoss / total)} MRR dự kiến mất mỗi tháng: ${high.map((h) => esc(h.risk_segment)).join(', ')}.`, [
        `Rủi ro cao = đồng thời ≥ 5% khách, churn ≥ 1,5 lần bình quân (${fmt.pct(overall, 2)}/tháng) và ≥ 10% MRR hiện tại.`,
        `Ba phân khúc đầu bảng chiếm ${fmt.pct(sum(top3, (s) => s.expected_mrr_loss_usd) / total)} MRR dự kiến mất. Bấm vào một phân khúc để xem danh sách khách.`,
      ])}
      <div class="grid kpis">
        ${kpiCard('MRR dự kiến mất / tháng', fmt.usd(total), 'nếu churn giữ như 24 tháng qua')}
        ${kpiCard('Phân khúc rủi ro cao', fmt.int(high.length), `trên ${segs.length} phân khúc`)}
        ${kpiCard('MRR hiện tại của nhóm rủi ro cao', fmt.usd(sum(high, (s) => s.current_mrr_usd)), `${fmt.pct(sum(high, (s) => s.mrr_share))} tổng MRR`)}
        ${kpiCard('Khách đang hoạt động (rủi ro cao)', fmt.int(sum(high, (s) => s.active_customers)), 'đối tượng chăm sóc ưu tiên')}
        ${kpiCard('Churn bình quân / tháng', fmt.pct(overall, 2), 'toàn bộ khách, 24 tháng')}
      </div>
      <div class="grid wide-left">
        ${cardHtml('c-bubble', 'Phân khúc: quy mô khách và mức churn', 'Trục ngang: tỷ trọng khách · Trục dọc: churn so với bình quân · Kích thước: MRR hiện tại. Bấm bong bóng để xem khách.', 'tall')}
        <div class="card"><div class="card-head"><div><h3 class="card-title">Top MRR dự kiến mất / tháng</h3>
          <div class="card-sub">= MRR hiện tại × churn theo tháng của phân khúc</div></div></div>
          <div class="chart tall" id="c-loss"></div></div>
      </div>
      <div class="card"><div class="card-head"><div><h3 class="card-title">Tất cả phân khúc</h3>
        <div class="card-sub">Hợp đồng | Internet | Hình thức thanh toán. Bấm một dòng để drill-through.</div></div></div>
        <div class="table-wrap"><table id="segTable"><thead><tr>
          <th>Phân khúc</th><th class="r">Khách (24 th)</th><th class="r">Đang hoạt động</th><th class="r">Churn/tháng</th>
          <th class="r">× bình quân</th><th class="r">MRR hiện tại</th><th class="r">MRR dự kiến mất</th><th>Mức</th></tr></thead>
          <tbody>${segs.map((s) => `<tr class="clickable" data-seg="${esc(s.risk_segment)}">
            <td>${esc(s.risk_segment)}</td><td class="r num">${fmt.int(s.customers)}</td><td class="r num">${fmt.int(s.active_customers)}</td>
            <td class="r num">${fmt.pct(s.monthly_churn_rate, 2)}</td><td class="r num">${fmt.num(s.churn_lift, 2)}</td>
            <td class="r num">${fmt.usd(s.current_mrr_usd)}</td>
            <td class="r"><div class="bar-cell"><div class="bar ${s.is_high_risk ? 'crit' : ''}" style="width:${Math.max(2, 90 * s.expected_mrr_loss_usd / segs[0].expected_mrr_loss_usd)}px"></div><span class="num">${fmt.usd(s.expected_mrr_loss_usd)}</span></div></td>
            <td>${s.is_high_risk ? badge('bad', 'Rủi ro cao') : s.churn_lift >= 1.5 ? badge('warn', 'Churn cao') : badge('neutral', 'Theo dõi')}</td></tr>`).join('')}
          </tbody></table></div></div>`;

    const s1 = css('--series-1'), crit = css('--critical'), neutral = css('--neutral-mark');
    const maxMrr = Math.max(...segs.map((s) => s.current_mrr_usd));
    const maxShare = Math.max(...segs.map((s) => s.customer_share));
    const bubble = mountChart('c-bubble', {
      grid: { left: 8, right: 24, top: 16, bottom: 32, containLabel: true },
      xAxis: axis({ type: 'value', name: 'Tỷ trọng khách', nameLocation: 'middle', nameGap: 26, nameTextStyle: { color: css('--text-3'), fontSize: 11 },
        axisLabel: { ...axis().axisLabel, formatter: (v) => fmt.pct(v, 0) } }),
      yAxis: axis({ type: 'value', name: 'Churn × bình quân', nameTextStyle: { color: css('--text-3'), fontSize: 11 } }),
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => {
        const s = segs[p.dataIndex];
        return `<b>${esc(s.risk_segment)}</b>${tipRow(null, 'Tỷ trọng khách', fmt.pct(s.customer_share))}${tipRow(null, 'Churn/tháng', `${fmt.pct(s.monthly_churn_rate, 2)} (×${fmt.num(s.churn_lift, 2)})`)}
          ${tipRow(null, 'MRR hiện tại', fmt.usd(s.current_mrr_usd))}${tipRow(s.is_high_risk ? crit : null, 'MRR dự kiến mất', fmt.usd(s.expected_mrr_loss_usd))}`;
      } },
      series: [{ type: 'scatter', data: segs.map((s) => ({
          value: [s.customer_share, s.churn_lift],
          symbolSize: 10 + 46 * Math.sqrt(s.current_mrr_usd / maxMrr),
          itemStyle: { color: s.is_high_risk ? crit : s.churn_lift >= 1.5 ? s1 : neutral, opacity: 0.85, borderColor: css('--surface'), borderWidth: 2 },
          label: { show: s.is_high_risk || segs.indexOf(s) < 3, formatter: s.risk_segment, fontSize: 11, color: css('--text-2'),
            position: s.customer_share > 0.6 * maxShare ? 'left' : 'right' },
        })),
        markLine: { silent: true, symbol: 'none', lineStyle: { color: css('--text-3'), type: 'dashed' },
          label: { formatter: 'bình quân', color: css('--text-3'), fontSize: 10 }, data: [{ yAxis: 1 }] } }],
    });
    bubble.on('click', (p) => openSegment(segs[p.dataIndex]));

    const topLoss = segs.slice(0, 8).reverse();
    mountChart('c-loss', {
      grid: { left: 8, right: 56, top: 8, bottom: 8, containLabel: true },
      xAxis: axis({ type: 'value', axisLabel: { show: false }, splitLine: { show: false } }),
      yAxis: axis({ type: 'category', data: topLoss.map((s) => s.risk_segment), axisLine: { show: false },
        axisLabel: { ...axis().axisLabel, color: css('--text-2'), width: 170, overflow: 'truncate' } }),
      tooltip: { ...baseOption().tooltip, trigger: 'item', formatter: (p) => `<b>${esc(topLoss[p.dataIndex].risk_segment)}</b>${tipRow(null, 'MRR dự kiến mất', fmt.usd(p.value))}` },
      series: [{ type: 'bar', barMaxWidth: 16, data: topLoss.map((s) => ({ value: s.expected_mrr_loss_usd,
          itemStyle: { color: s.is_high_risk ? crit : s1, borderRadius: [0, 4, 4, 0] } })),
        label: { show: true, position: 'right', fontSize: 11, color: css('--text-2'), formatter: (p) => fmt.usd(p.value) } }],
    }).on('click', (p) => openSegment(topLoss[p.dataIndex]));

    $('#segTable tbody').addEventListener('click', (e) => {
      const tr = e.target.closest('tr[data-seg]');
      if (tr) openSegment(segs.find((s) => s.risk_segment === tr.dataset.seg));
    });
  }

  async function openSegment(seg) {
    $('#drawerTitle').textContent = seg.risk_segment;
    $('#drawerBody').innerHTML = '<div class="skeleton"></div>';
    $('#drawer').classList.add('open'); $('#drawerBackdrop').classList.add('open');
    $('#drawer').setAttribute('aria-hidden', 'false');
    try {
      const res = await api('segment_customers', { segment: seg.risk_segment });
      renderSegmentTable(seg, res.rows, res.limit);
    } catch (e) {
      $('#drawerBody').innerHTML = `<p class="error">Không tải được danh sách khách: ${esc(e.message)}</p>`;
    }
  }

  function renderSegmentTable(seg, rows, limit) {
    const cols = [
      ['customer_id', 'Mã khách', 's'], ['tenure_months', 'Tenure (th)', 'n'], ['current_mrr_usd', 'Cước hiện tại', 'usd'],
      ['tickets', 'Ticket', 'n'], ['billing_tickets', 'Ticket Billing', 'n'], ['late_payment_rate', 'Tỷ lệ trả trễ', 'pct'],
      ['tech_support', 'Tech support', 's'], ['addon_count', 'Add-on', 'n'], ['payment_method', 'Thanh toán', 's'],
    ];
    let sortKey = 'current_mrr_usd', sortDir = -1, query = '';
    const body = $('#drawerBody');
    body.innerHTML = `
      <div class="mini-stats">
        <div><div class="k">Đang hoạt động</div><div class="v num">${fmt.int(seg.active_customers)}</div></div>
        <div><div class="k">Churn / tháng</div><div class="v num">${fmt.pct(seg.monthly_churn_rate, 2)}</div></div>
        <div><div class="k">MRR hiện tại</div><div class="v num">${fmt.usd(seg.current_mrr_usd)}</div></div>
        <div><div class="k">MRR dự kiến mất</div><div class="v num">${fmt.usd(seg.expected_mrr_loss_usd)}</div></div>
      </div>
      <div class="toolbar">
        <input class="input" id="custSearch" placeholder="Tìm mã khách..." aria-label="Tìm mã khách">
        <span class="muted" id="custCount"></span>
        <button class="btn" id="custExport" type="button" style="margin-left:auto">${ICON.download}Xuất CSV</button>
      </div>
      <div class="table-wrap"><table><thead><tr>${cols.map(([k, l, t]) => `<th class="sortable ${t === 's' ? '' : 'r'}" data-k="${k}">${l}</th>`).join('')}</tr></thead>
      <tbody id="custBody"></tbody></table></div>
      ${rows.length >= limit ? `<p class="muted">Hiển thị ${limit} khách có cước cao nhất.</p>` : ''}`;
    const cell = (r, k, t) => (r[k] == null ? '–' : t === 'usd' ? fmt.usd2(r[k]) : t === 'pct' ? fmt.pct(r[k], 0) : t === 'n' ? fmt.int(r[k]) : esc(r[k]));
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
      const a = Object.assign(document.createElement('a'), { href: url, download: `khach_${seg.risk_segment.replace(/\W+/g, '_')}.csv` });
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
    if (!PAGES[page]) page = 'overview';
    state.page = page;
    const def = PAGES[page];
    document.querySelectorAll('.nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === page));
    document.querySelectorAll('.page').forEach((p) => p.classList.toggle('active', p.id === 'page-' + page));
    $('#pageTitle').textContent = def.title; $('#crumb').textContent = def.crumb;
    $('#periodFilter').classList.toggle('hidden', !def.period);
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
  $('#periodFilter').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-period]');
    if (!b) return;
    state.period = b.dataset.period;
    document.querySelectorAll('#periodFilter button').forEach((x) => x.classList.toggle('active', x === b));
    show(state.page);
  });
  $('#menuBtn').addEventListener('click', () => $('#sidebar').classList.toggle('open'));
  $('#drawerClose').addEventListener('click', closeDrawer);
  $('#drawerBackdrop').addEventListener('click', closeDrawer);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDrawer(); });
  window.addEventListener('hashchange', () => show(location.hash.slice(1)));
  window.addEventListener('resize', () => Object.values(state.charts).forEach((c) => c.resize()));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => show(state.page));

  loadMeta();
  show(location.hash.slice(1) || 'overview');
})();
