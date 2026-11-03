/*
  Serving layer for the dashboard's Explore page.

  Filters arrive as JSON: [{"factor": "contract", "value": "Month-to-month"}, ...]
  - Several values of the same factor: OR. Different factors: AND.
  - No dynamic SQL: the plan is compiled once and reused, and there is no path for SQL injection.
  - Each call returns several result sets in one round trip (no N+1).
*/

CREATE OR ALTER PROCEDURE mart.usp_explore_factors
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.factor_key, f.factor_label, f.factor_sort, cf.value, MIN(cf.value_sort) AS value_sort, COUNT(*) AS customers
    FROM mart.customer_factor cf
    JOIN mart.dim_factor f ON f.factor_key = cf.factor_key
    JOIN mart.customer_snapshot s ON s.customer_key = cf.customer_key AND s.in_analysis_window = 1
    GROUP BY f.factor_key, f.factor_label, f.factor_sort, cf.value
    ORDER BY f.factor_sort, value_sort;
END
GO

CREATE OR ALTER PROCEDURE mart.usp_explore @filters NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @window_start DATE = dbo.fn_config_date('analysis_window_start');
    DECLARE @snapshot DATE = dbo.fn_config_date('snapshot_date');
    DECLARE @snapshot_month DATE = DATEFROMPARTS(YEAR(@snapshot), MONTH(@snapshot), 1);

    CREATE TABLE #f (factor_key VARCHAR(30) NOT NULL, value NVARCHAR(60) NOT NULL, PRIMARY KEY (factor_key, value));
    INSERT INTO #f (factor_key, value)
    SELECT DISTINCT j.factor_key, j.value
    FROM OPENJSON(@filters) WITH (factor_key VARCHAR(30) '$.factor', value NVARCHAR(60) '$.value') j
    WHERE j.factor_key IS NOT NULL AND j.value IS NOT NULL;
    DECLARE @filtered_factors INT = (SELECT COUNT(DISTINCT factor_key) FROM #f);

    /*
      fails = number of filtered factors the customer does NOT satisfy. Each customer has exactly one value per factor,
      so matched factors = rows of customer_factor that join to #f.
    */
    SELECT s.customer_key, s.is_churned, s.window_months, s.customer_status, s.current_mrr_usd,
           s.late_payment_rate, s.first_billing_month,
           @filtered_factors - ISNULL(mt.matched, 0) AS fails,
           CASE WHEN @filtered_factors - ISNULL(mt.matched, 0) = 0 THEN 1 ELSE 0 END AS sel
    INTO #s
    FROM mart.customer_snapshot s
    LEFT JOIN (SELECT cf.customer_key, COUNT(*) AS matched
               FROM mart.customer_factor cf
               JOIN #f f ON f.factor_key = cf.factor_key AND f.value = cf.value
               GROUP BY cf.customer_key) mt ON mt.customer_key = s.customer_key
    WHERE s.in_analysis_window = 1;
    CREATE UNIQUE CLUSTERED INDEX ix_s ON #s (customer_key);

    /* 1. KPIs: selected group and whole company in a single scan */
    SELECT COUNT(*) AS all_customers, SUM(is_churned) AS all_churners, SUM(window_months) AS all_customer_months,
           SUM(CASE WHEN customer_status = N'Active' THEN 1 ELSE 0 END) AS all_active, SUM(current_mrr_usd) AS all_mrr,
           AVG(CAST(late_payment_rate AS FLOAT)) AS all_late_rate,
           SUM(sel) AS sel_customers, SUM(sel * is_churned) AS sel_churners, SUM(sel * window_months) AS sel_customer_months,
           SUM(CASE WHEN sel = 1 AND customer_status = N'Active' THEN 1 ELSE 0 END) AS sel_active,
           SUM(CASE WHEN sel = 1 THEN current_mrr_usd END) AS sel_mrr,
           AVG(CASE WHEN sel = 1 THEN CAST(late_payment_rate AS FLOAT) END) AS sel_late_rate
    FROM #s;

    /*
      2. Impact of each factor in the current context. For factor F, a customer counts when it satisfies EVERY filter
         other than F (F's own filter is ignored so all of F's values stay visible):
         - F not filtered, or the customer's value is in F's filter  -> needs fails = 0
         - F filtered and the customer's value is outside F's filter  -> needs fails = 1 (misses only F)
    */
    SELECT cf.factor_key, cf.value, MIN(cf.value_sort) AS value_sort,
           COUNT(*) AS customers, SUM(s.is_churned) AS churners,
           SUM(s.window_months) AS customer_months, SUM(s.current_mrr_usd) AS current_mrr
    FROM #s s
    JOIN mart.customer_factor cf ON cf.customer_key = s.customer_key
    LEFT JOIN (SELECT DISTINCT factor_key FROM #f) ff ON ff.factor_key = cf.factor_key
    LEFT JOIN #f fv ON fv.factor_key = cf.factor_key AND fv.value = cf.value
    WHERE s.fails = CASE WHEN ff.factor_key IS NULL OR fv.value IS NOT NULL THEN 0 ELSE 1 END
    GROUP BY cf.factor_key, cf.value;

    /* 3. Monthly trend: selected group and whole company, with targets */
    SELECT d.year_month,
           COUNT(*) AS all_customers, SUM(CAST(f.is_churn_month AS INT)) AS all_churners, SUM(f.amount_usd) AS all_mrr,
           SUM(CASE WHEN f.is_churn_month = 1 THEN f.amount_usd ELSE 0 END) AS all_mrr_lost,
           SUM(s.sel) AS sel_customers, SUM(s.sel * CAST(f.is_churn_month AS INT)) AS sel_churners,
           SUM(CASE WHEN s.sel = 1 THEN f.amount_usd ELSE 0 END) AS sel_mrr,
           SUM(CASE WHEN s.sel = 1 AND f.is_churn_month = 1 THEN f.amount_usd ELSE 0 END) AS sel_mrr_lost,
           MAX(t.churn_rate_target) AS churn_rate_target, MAX(t.mrr_target_usd) AS mrr_target_usd
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_analysis_window = 1
    JOIN #s s ON s.customer_key = f.customer_key
    LEFT JOIN mart.fact_target t ON t.date_key = f.date_key
    GROUP BY d.year_month
    ORDER BY d.year_month;

    /* 4. Tickets per month */
    SELECT d.year_month, COUNT(*) AS all_tickets,
           SUM(CASE WHEN t.category = N'Billing' THEN 1 ELSE 0 END) AS all_billing,
           SUM(s.sel) AS sel_tickets,
           SUM(CASE WHEN s.sel = 1 AND t.category = N'Billing' THEN 1 ELSE 0 END) AS sel_billing
    FROM mart.fact_tickets t
    JOIN mart.dim_date d ON d.date_key = t.created_date_key AND d.is_analysis_window = 1
    JOIN #s s ON s.customer_key = t.customer_key
    GROUP BY d.year_month
    ORDER BY d.year_month;

    /* 5. Retention: customers still active k months after their first bill (only cohorts that start inside the window,
          to avoid survivorship bias) */
    SELECT DATEDIFF(MONTH, s.first_billing_month, d.[date]) AS k, COUNT(*) AS all_active, SUM(s.sel) AS sel_active
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key
    JOIN #s s ON s.customer_key = f.customer_key
    WHERE s.first_billing_month >= @window_start
    GROUP BY DATEDIFF(MONTH, s.first_billing_month, d.[date]);

    /* 6. Retention denominator: how many months each customer can be observed up to the snapshot */
    SELECT DATEDIFF(MONTH, first_billing_month, @snapshot_month) AS max_k, COUNT(*) AS all_customers, SUM(sel) AS sel_customers
    FROM #s
    WHERE first_billing_month >= @window_start
    GROUP BY DATEDIFF(MONTH, first_billing_month, @snapshot_month);
END
GO

/*
  Customer list for follow-up: filtering, quick filters, search, sorting and paging all run on the server.
  Returns 2 result sets: (1) group size, matched count, "high charge" threshold;
  (2) exactly one page of rows. No dynamic SQL: the sort column is chosen with CASE over a fixed list.
  @page_size = 0 returns every matching row (used for CSV export).
*/
CREATE OR ALTER PROCEDURE mart.usp_explore_customers
    @filters    NVARCHAR(MAX) = N'[]',
    @quick      NVARCHAR(MAX) = N'[]',
    @search     NVARCHAR(50)  = NULL,
    @sort_key   VARCHAR(30)   = 'current_mrr_usd',
    @sort_desc  BIT           = 1,
    @page       INT           = 0,
    @page_size  INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #f (factor_key VARCHAR(30) NOT NULL, value NVARCHAR(60) NOT NULL, PRIMARY KEY (factor_key, value));
    INSERT INTO #f (factor_key, value)
    SELECT DISTINCT j.factor_key, j.value
    FROM OPENJSON(@filters) WITH (factor_key VARCHAR(30) '$.factor', value NVARCHAR(60) '$.value') j
    WHERE j.factor_key IS NOT NULL AND j.value IS NOT NULL;
    DECLARE @filtered_factors INT = (SELECT COUNT(DISTINCT factor_key) FROM #f);

    DECLARE @q TABLE (k VARCHAR(20) PRIMARY KEY);
    INSERT INTO @q (k) SELECT DISTINCT CAST(value AS VARCHAR(20)) FROM OPENJSON(@quick);

    -- Customer group from the Explore page filters (same logic as mart.usp_explore).
    SELECT s.customer_id, s.contract_type, s.internet_service, s.payment_method, s.tenure_months,
           s.current_mrr_usd, s.tickets, s.billing_tickets, s.late_payment_rate, s.tech_support, s.addon_count
    INTO #g
    FROM mart.customer_snapshot s
    LEFT JOIN (SELECT cf.customer_key, COUNT(*) AS matched
               FROM mart.customer_factor cf
               JOIN #f f ON f.factor_key = cf.factor_key AND f.value = cf.value
               GROUP BY cf.customer_key) mt ON mt.customer_key = s.customer_key
    WHERE s.in_analysis_window = 1 AND s.customer_status = N'Active'
      AND ISNULL(mt.matched, 0) = @filtered_factors;

    -- "High charge" = top 25% of charges within the group being viewed, so the threshold follows the page filters.
    DECLARE @mrr_p75 DECIMAL(10,2) =
        (SELECT TOP (1) PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY current_mrr_usd) OVER () FROM #g);

    SELECT *
    INTO #v
    FROM #g
    WHERE (NULLIF(@search, N'') IS NULL OR CHARINDEX(UPPER(@search), UPPER(customer_id)) > 0)
      AND (NOT EXISTS (SELECT 1 FROM @q WHERE k = 'mrr')    OR current_mrr_usd >= @mrr_p75)
      AND (NOT EXISTS (SELECT 1 FROM @q WHERE k = 'bill')   OR billing_tickets > 0)
      AND (NOT EXISTS (SELECT 1 FROM @q WHERE k = 'late')   OR late_payment_rate >= 0.2)
      AND (NOT EXISTS (SELECT 1 FROM @q WHERE k = 'notech') OR tech_support = N'No')
      AND (NOT EXISTS (SELECT 1 FROM @q WHERE k = 'new')    OR tenure_months <= 12);

    SELECT (SELECT COUNT(*) FROM #g) AS group_total, (SELECT COUNT(*) FROM #v) AS matched, @mrr_p75 AS mrr_p75;

    DECLARE @take INT = CASE WHEN @page_size > 0 THEN @page_size ELSE 2147483647 END;
    DECLARE @skip INT = CASE WHEN @page_size > 0 THEN @page * @page_size ELSE 0 END;
    SELECT customer_id, contract_type, internet_service, payment_method, tenure_months, current_mrr_usd,
           tickets, billing_tickets, late_payment_rate, tech_support, addon_count
    FROM #v
    ORDER BY
        -- Numeric and text columns use separate CASE expressions so they are not cast to each other's type.
        CASE WHEN @sort_desc = 1 THEN CASE @sort_key
            WHEN 'current_mrr_usd' THEN current_mrr_usd WHEN 'tenure_months' THEN tenure_months
            WHEN 'billing_tickets' THEN billing_tickets WHEN 'tickets' THEN tickets
            WHEN 'late_payment_rate' THEN late_payment_rate WHEN 'addon_count' THEN addon_count END END DESC,
        CASE WHEN @sort_desc = 0 THEN CASE @sort_key
            WHEN 'current_mrr_usd' THEN current_mrr_usd WHEN 'tenure_months' THEN tenure_months
            WHEN 'billing_tickets' THEN billing_tickets WHEN 'tickets' THEN tickets
            WHEN 'late_payment_rate' THEN late_payment_rate WHEN 'addon_count' THEN addon_count END END ASC,
        CASE WHEN @sort_desc = 1 THEN CASE @sort_key
            WHEN 'customer_id' THEN customer_id WHEN 'contract_type' THEN contract_type
            WHEN 'internet_service' THEN internet_service WHEN 'tech_support' THEN tech_support
            WHEN 'payment_method' THEN payment_method END END DESC,
        CASE WHEN @sort_desc = 0 THEN CASE @sort_key
            WHEN 'customer_id' THEN customer_id WHEN 'contract_type' THEN contract_type
            WHEN 'internet_service' THEN internet_service WHEN 'tech_support' THEN tech_support
            WHEN 'payment_method' THEN payment_method END END ASC,
        customer_id
    OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY;
END
GO
