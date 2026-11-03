/*
  clean -> mart: fact tables. Fully reloaded in one transaction (TRUNCATE + INSERT).
  Each procedure compares expected and written row counts; a mismatch THROWs instead of silently losing rows.
*/

CREATE OR ALTER PROCEDURE mart.usp_load_fact_billing @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_billing', N'mart.fact_billing', NULL, @log_id OUTPUT;
    BEGIN TRY
        /*
          Grain comes from CRM (every month the contract is billed), not from the invoice table.
          Reason: the billing outage month has no invoices; taking the grain from invoices would make customers "vanish"
          for a month and break that month's churn rate, customer count and MRR.
        */
        -- Generate months from a numbers table, then join dim_date on equality: a range join (BETWEEN) on dim_date
        -- ran as a nested loop in SQL Server, reading ~14 million pages and taking ~37 seconds.
        WITH n AS (
            SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects
        )
        SELECT k.customer_id, d.date_key, d.[date] AS billing_month,
               n.i + 1 AS tenure_month_no,
               k.monthly_charges, k.churn_month
        INTO #m
        FROM clean.contracts k
        JOIN n ON n.i <= DATEDIFF(MONTH, k.first_billing_month, k.last_billing_month)
        JOIN mart.dim_date d ON d.[date] = DATEADD(MONTH, n.i, k.first_billing_month)
        WHERE k.first_billing_month IS NOT NULL;
        SET @expected = @@ROWCOUNT;

        SELECT m.*, i.invoice_id, i.amount_usd, i.amount_source, i.due_date,
               p.paid_amount, p.last_payment_date
        INTO #f
        FROM #m m
        LEFT JOIN clean.invoices i ON i.customer_id = m.customer_id AND i.billing_month = m.billing_month
        LEFT JOIN (SELECT invoice_id, SUM(amount_usd) AS paid_amount, MAX(payment_date) AS last_payment_date
                   FROM clean.payments GROUP BY invoice_id) p ON p.invoice_id = i.invoice_id;

        -- Month without an invoice: estimate as the mean of the customer's previous and next invoice
        -- (customer charges are usually stable); use whichever side exists, or the plan price if neither does.
        UPDATE f
        SET amount_usd = CASE WHEN prev.amount_usd IS NOT NULL AND nxt.amount_usd IS NOT NULL
                                  THEN ROUND((prev.amount_usd + nxt.amount_usd) / 2, 2)
                              ELSE COALESCE(prev.amount_usd, nxt.amount_usd, f.monthly_charges) END,
            amount_source = 'IMPUTED_MISSING_INVOICE'
        FROM #f f
        OUTER APPLY (SELECT TOP (1) amount_usd FROM clean.invoices x
                     WHERE x.customer_id = f.customer_id AND x.billing_month < f.billing_month
                     ORDER BY x.billing_month DESC) prev
        OUTER APPLY (SELECT TOP (1) amount_usd FROM clean.invoices x
                     WHERE x.customer_id = f.customer_id AND x.billing_month > f.billing_month
                     ORDER BY x.billing_month ASC) nxt
        WHERE f.invoice_id IS NULL;

        -- Look up surrogate keys once per customer (7 thousand rows) instead of joining 9 service columns on every customer-month.
        SELECT k.customer_id, dc.customer_key, ct.contract_key, ds.service_key, pm.payment_method_key
        INTO #keys
        FROM clean.contracts k
        JOIN mart.dim_customer dc ON dc.customer_id = k.customer_id
        JOIN mart.dim_contract ct ON ct.contract_type = k.contract_type
                                 AND ct.paperless_billing = CASE k.is_paperless_billing WHEN 1 THEN N'Yes' ELSE N'No' END
        JOIN mart.dim_payment_method pm ON pm.payment_method = k.payment_method
        JOIN clean.services sv ON sv.customer_id = k.customer_id
        JOIN mart.dim_service ds ON ds.phone_service = sv.phone_service AND ds.multiple_lines = sv.multiple_lines
                                AND ds.internet_service = sv.internet_service AND ds.online_security = sv.online_security
                                AND ds.online_backup = sv.online_backup AND ds.device_protection = sv.device_protection
                                AND ds.tech_support = sv.tech_support AND ds.streaming_tv = sv.streaming_tv
                                AND ds.streaming_movies = sv.streaming_movies;
        CREATE UNIQUE CLUSTERED INDEX ix_tmp_keys ON #keys (customer_id);

        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_billing;
            INSERT INTO mart.fact_billing WITH (TABLOCK) (customer_key, date_key, contract_key, service_key, payment_method_key,
                invoice_id, tenure_month_no, amount_usd, usd_vnd_rate, amount_vnd, amount_source, is_imputed,
                is_first_month, is_churn_month, is_paid, paid_amount_usd, payment_date, days_after_due, is_late)
            SELECT ky.customer_key, f.date_key, ky.contract_key, ky.service_key, ky.payment_method_key,
                   f.invoice_id, f.tenure_month_no, f.amount_usd, fx.usd_vnd,
                   ROUND(f.amount_usd * fx.usd_vnd, 0),
                   f.amount_source,
                   CASE WHEN f.amount_source LIKE 'IMPUTED%' THEN 1 ELSE 0 END,
                   CASE WHEN f.tenure_month_no = 1 THEN 1 ELSE 0 END,
                   CASE WHEN f.billing_month = f.churn_month THEN 1 ELSE 0 END,
                   CASE WHEN f.invoice_id IS NULL THEN NULL WHEN f.paid_amount IS NOT NULL THEN 1 ELSE 0 END,
                   f.paid_amount, f.last_payment_date,
                   DATEDIFF(DAY, f.due_date, f.last_payment_date),
                   CASE WHEN f.last_payment_date IS NULL THEN NULL WHEN f.last_payment_date > f.due_date THEN 1 ELSE 0 END
            FROM #f f
            JOIN #keys ky ON ky.customer_id = f.customer_id
            JOIN clean.fx_rates fx ON fx.rate_month = f.billing_month;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected
                THROW 50010, N'fact_billing: rows written differ from expected customer-months (missing dimension or FX rate)', 1;
        COMMIT;

        SET @msg = CONCAT(N'customer-months ', @expected, N'; imputed ',
                          (SELECT COUNT(*) FROM #f WHERE amount_source = 'IMPUTED_MISSING_INVOICE'));
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_fact_tickets @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_tickets', N'mart.fact_tickets', NULL, @log_id OUTPUT;
    BEGIN TRY
        SET @expected = (SELECT COUNT(*) FROM clean.tickets);
        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_tickets;
            INSERT INTO mart.fact_tickets (ticket_id, customer_key, created_date_key, resolved_date_key, contract_key,
                service_key, payment_method_key, created_at, resolved_at, category, priority, channel, status,
                resolution_hours, is_open, days_before_churn, is_within_90d_before_churn)
            SELECT t.ticket_id, dc.customer_key,
                   YEAR(t.created_at) * 10000 + MONTH(t.created_at) * 100 + DAY(t.created_at),
                   CASE WHEN t.resolved_at IS NOT NULL THEN YEAR(t.resolved_at) * 10000 + MONTH(t.resolved_at) * 100 + DAY(t.resolved_at) END,
                   ct.contract_key, ds.service_key, pm.payment_method_key,
                   t.created_at, t.resolved_at, t.category, t.priority, t.channel, t.status, t.resolution_hours,
                   CASE WHEN t.status = N'Open' THEN 1 ELSE 0 END,
                   CASE WHEN k.end_date IS NOT NULL THEN DATEDIFF(DAY, CAST(t.created_at AS DATE), k.end_date) END,
                   CASE WHEN k.end_date IS NOT NULL AND DATEDIFF(DAY, CAST(t.created_at AS DATE), k.end_date) BETWEEN 0 AND 90
                        THEN 1 ELSE 0 END
            FROM clean.tickets t
            JOIN mart.dim_customer dc ON dc.customer_id = t.customer_id
            JOIN clean.contracts k ON k.customer_id = t.customer_id
            JOIN mart.dim_contract ct ON ct.contract_type = k.contract_type
                                     AND ct.paperless_billing = CASE k.is_paperless_billing WHEN 1 THEN N'Yes' ELSE N'No' END
            JOIN mart.dim_payment_method pm ON pm.payment_method = k.payment_method
            JOIN clean.services sv ON sv.customer_id = t.customer_id
            JOIN mart.dim_service ds ON ds.phone_service = sv.phone_service AND ds.multiple_lines = sv.multiple_lines
                                    AND ds.internet_service = sv.internet_service AND ds.online_security = sv.online_security
                                    AND ds.online_backup = sv.online_backup AND ds.device_protection = sv.device_protection
                                    AND ds.tech_support = sv.tech_support AND ds.streaming_tv = sv.streaming_tv
                                    AND ds.streaming_movies = sv.streaming_movies;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected
                THROW 50011, N'fact_tickets: rows written differ from tickets in clean', 1;
        COMMIT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_fact_target @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_target', N'mart.fact_target', NULL, @log_id OUTPUT;
    BEGIN TRY
        SET @expected = (SELECT COUNT(*) FROM clean.targets);
        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_target;
            INSERT INTO mart.fact_target (date_key, churn_rate_target, mrr_target_usd, note)
            SELECT d.date_key, t.churn_rate_target, t.mrr_target_usd, t.note
            FROM clean.targets t JOIN mart.dim_date d ON d.[date] = t.target_month;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected THROW 50012, N'fact_target: target month outside dim_date', 1;
        COMMIT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO

/* Materialise mart.v_customer_profile for the Explore page; must run after the facts are loaded. */
CREATE OR ALTER PROCEDURE mart.usp_load_customer_snapshot @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_customer_snapshot', N'mart.customer_snapshot', NULL, @log_id OUTPUT;
    BEGIN TRY
        SET @expected = (SELECT COUNT(DISTINCT customer_key) FROM mart.fact_billing);
        BEGIN TRAN;
            DELETE FROM mart.customer_factor;
            DELETE FROM mart.customer_snapshot;
            INSERT INTO mart.customer_snapshot WITH (TABLOCK)
               (customer_key, customer_id, gender, senior_citizen, partner, dependents, signup_month, first_billing_month,
                tenure_months, tenure_group, tenure_group_order, customer_status, churn_month, is_churned, contract_type,
                contract_sort, paperless_billing, internet_service, phone_service, tech_support, online_security,
                online_backup, device_protection, addon_count, has_streaming, payment_method, payment_type, risk_segment,
                last_billed_amount_usd, current_mrr_usd, billed_months, window_months, lifetime_revenue_usd,
                late_payment_rate, tickets, billing_tickets, technical_tickets, in_analysis_window)
            SELECT customer_key, customer_id, gender, senior_citizen, partner, dependents, signup_month, first_billing_month,
                tenure_months, tenure_group, tenure_group_order, customer_status, churn_month, is_churned, contract_type,
                contract_sort, paperless_billing, internet_service, phone_service, tech_support, online_security,
                online_backup, device_protection, addon_count, has_streaming, payment_method, payment_type, risk_segment,
                last_billed_amount_usd, current_mrr_usd, billed_months, window_months, lifetime_revenue_usd,
                late_payment_rate, tickets, billing_tickets, technical_tickets, in_analysis_window
            FROM mart.v_customer_profile;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected THROW 50013, N'customer_snapshot: customer count differs from fact_billing', 1;

            -- Factor catalogue: adding or removing an Explore factor only needs the two VALUES lists below.
            MERGE mart.dim_factor AS t
            USING (VALUES
                ('contract', N'Contract type', 1), ('tenure', N'Tenure', 2), ('internet', N'Internet service', 3),
                ('addons', N'Add-on services', 4), ('tech_support', N'Tech support', 5),
                ('online_security', N'Online security', 6), ('payment_type', N'Payment type', 7),
                ('payment_method', N'Payment method', 8), ('paperless', N'Paperless billing', 9),
                ('senior', N'Senior citizen', 10), ('partner', N'Has partner', 11),
                ('dependents', N'Has dependents', 12), ('gender', N'Gender', 13)
            ) AS s(factor_key, factor_label, factor_sort) ON t.factor_key = s.factor_key
            WHEN MATCHED THEN UPDATE SET factor_label = s.factor_label, factor_sort = s.factor_sort
            WHEN NOT MATCHED BY TARGET THEN INSERT (factor_key, factor_label, factor_sort) VALUES (s.factor_key, s.factor_label, s.factor_sort)
            WHEN NOT MATCHED BY SOURCE THEN DELETE;

            INSERT INTO mart.customer_factor WITH (TABLOCK) (customer_key, factor_key, value, value_sort)
            SELECT s.customer_key, v.factor_key, v.value, v.value_sort
            FROM mart.customer_snapshot s
            CROSS APPLY (VALUES
                ('contract', s.contract_type, s.contract_sort),
                ('tenure', s.tenure_group, s.tenure_group_order),
                ('internet', s.internet_service, CASE s.internet_service WHEN N'Fiber optic' THEN 1 WHEN N'DSL' THEN 2 ELSE 3 END),
                -- Customers without internet cannot have add-ons; lumping them into "0 add-ons" would pull
                -- that group's churn rate down misleadingly, so they get their own option.
                ('addons', CASE WHEN s.internet_service = N'No' THEN N'No internet service' ELSE CAST(s.addon_count AS NVARCHAR(60)) END,
                           CASE WHEN s.internet_service = N'No' THEN 99 ELSE s.addon_count END),
                ('tech_support', s.tech_support, CASE s.tech_support WHEN N'No' THEN 1 WHEN N'Yes' THEN 2 ELSE 3 END),
                ('online_security', s.online_security, CASE s.online_security WHEN N'No' THEN 1 WHEN N'Yes' THEN 2 ELSE 3 END),
                ('payment_type', s.payment_type, CASE s.payment_type WHEN N'Manual' THEN 1 ELSE 2 END),
                ('payment_method', s.payment_method, CASE s.payment_method WHEN N'Electronic check' THEN 1
                    WHEN N'Mailed check' THEN 2 WHEN N'Bank transfer (automatic)' THEN 3 ELSE 4 END),
                ('paperless', s.paperless_billing, CASE s.paperless_billing WHEN N'Yes' THEN 1 ELSE 2 END),
                ('senior', s.senior_citizen, CASE s.senior_citizen WHEN N'Yes' THEN 1 ELSE 2 END),
                ('partner', s.partner, CASE s.partner WHEN N'Yes' THEN 1 ELSE 2 END),
                ('dependents', s.dependents, CASE s.dependents WHEN N'Yes' THEN 1 ELSE 2 END),
                ('gender', s.gender, CASE s.gender WHEN N'Female' THEN 1 ELSE 2 END)
            ) v(factor_key, value, value_sort);
        COMMIT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO
