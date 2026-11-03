/*
  Data quality checks, run at the end of every batch, stored in mart.dq_check_results.
  value_before is measured on stg (raw data), value_after on clean/mart, value_rejected = rows rejected.
  PASS: meets expectation. WARN: known and handled deviation (e.g. the billing outage month). FAIL: needs investigation.
*/
CREATE OR ALTER PROCEDURE dbo.usp_run_dq_checks @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log_id BIGINT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'dq', N'dbo.usp_run_dq_checks', N'mart.dq_check_results', NULL, @log_id OUTPUT;
    BEGIN TRY
        DELETE FROM mart.dq_check_results WHERE batch_id = @batch_id;

        CREATE TABLE #dq (check_id VARCHAR(40), check_group NVARCHAR(50), check_name NVARCHAR(200),
                          object_name NVARCHAR(200), value_before DECIMAL(18,2), value_after DECIMAL(18,2),
                          value_rejected DECIMAL(18,2), expected_rule NVARCHAR(300), status VARCHAR(10), note NVARCHAR(1000));

        DECLARE @rej TABLE (source_table NVARCHAR(128), n INT);
        INSERT INTO @rej SELECT source_table, COUNT(*) FROM clean.rejected_records GROUP BY source_table;

        /* 1. Row reconciliation: every stg row must be in clean or in rejected; no row may be lost. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule)
        SELECT CONCAT('ROWS_', UPPER(PARSENAME(x.stg_table, 1))), N'1. Row reconciliation', N'stg = clean + rejected',
               CONCAT(x.stg_table, N' -> ', x.clean_table), x.stg_rows, x.clean_rows, ISNULL(r.n, 0),
               N'value_before = value_after + value_rejected'
        FROM (VALUES
            (N'stg.crm_customers', N'clean.customers', (SELECT COUNT(*) FROM stg.crm_customers), (SELECT COUNT(*) FROM clean.customers)),
            (N'stg.crm_contracts', N'clean.contracts', (SELECT COUNT(*) FROM stg.crm_contracts), (SELECT COUNT(*) FROM clean.contracts)),
            (N'stg.crm_services', N'clean.services', (SELECT COUNT(*) FROM stg.crm_services), (SELECT COUNT(*) FROM clean.services)),
            (N'stg.billing_invoices', N'clean.invoices', (SELECT COUNT(*) FROM stg.billing_invoices), (SELECT COUNT(*) FROM clean.invoices)),
            (N'stg.billing_payments', N'clean.payments', (SELECT COUNT(*) FROM stg.billing_payments), (SELECT COUNT(*) FROM clean.payments)),
            (N'stg.ticket_support_tickets', N'clean.tickets', (SELECT COUNT(*) FROM stg.ticket_support_tickets), (SELECT COUNT(*) FROM clean.tickets)),
            (N'stg.finance_targets_cells', N'clean.targets', (SELECT COUNT(*) FROM (SELECT DISTINCT sheet_name, excel_row FROM stg.finance_targets_cells) t), (SELECT COUNT(*) FROM clean.targets)),
            (N'stg.api_fx_rates', N'clean.fx_rates', (SELECT COUNT(*) FROM stg.api_fx_rates), (SELECT COUNT(*) FROM clean.fx_rates))
        ) x(stg_table, clean_table, stg_rows, clean_rows)
        LEFT JOIN @rej r ON r.source_table = x.stg_table;
        UPDATE #dq SET status = CASE WHEN value_before = value_after + value_rejected THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'1. Row reconciliation';

        /* 2. Each error type: counted before (stg) and after (clean) cleaning. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, note)
        SELECT 'ERR_DUPLICATE_CUSTOMER', N'2. Errors before/after cleaning', N'Duplicate customer_id (after TRIM)', N'customers',
               (SELECT COUNT(*) - COUNT(DISTINCT LTRIM(RTRIM(customer_id))) FROM stg.crm_customers),
               (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM clean.customers),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE reason_code = 'DUPLICATE_KEY' AND source_table = N'stg.crm_customers'),
               N'after = 0', N'Kept the row with the latest updated_at'
        UNION ALL
        SELECT 'ERR_BOOLEAN_VARIANT', N'2. Errors before/after cleaning', N'Non-standard Yes/No values (Y, yes, 1, N, 0...)',
               N'customers.partner/dependents, contracts.paperless_billing/churn_flag, services.phone_service',
               (SELECT COUNT(*) FROM stg.crm_customers CROSS APPLY (VALUES (partner), (dependents)) v(x) WHERE x COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No'))
             + (SELECT COUNT(*) FROM stg.crm_contracts CROSS APPLY (VALUES (paperless_billing), (churn_flag)) v(x) WHERE x COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No'))
             + (SELECT COUNT(*) FROM stg.crm_services WHERE phone_service COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No')),
               0, NULL, N'after = 0',
               N'Clean stores flags as BIT, so variants cannot survive by design; case-sensitive compare catches "yes"/"YES"'
        UNION ALL
        SELECT 'ERR_WHITESPACE', N'2. Errors before/after cleaning', N'Leading/trailing whitespace (measured with DATALENGTH)',
               N'customer_id (customers, services, invoices, tickets), gender, contract_type, payment_method',
               (SELECT COUNT(*) FROM stg.crm_customers WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))) OR DATALENGTH(gender) <> DATALENGTH(LTRIM(RTRIM(gender))))
             + (SELECT COUNT(*) FROM stg.crm_contracts WHERE DATALENGTH(contract_type) <> DATALENGTH(LTRIM(RTRIM(contract_type))) OR DATALENGTH(payment_method) <> DATALENGTH(LTRIM(RTRIM(payment_method))))
             + (SELECT COUNT(*) FROM stg.crm_services WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM stg.billing_invoices WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM stg.ticket_support_tickets WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id)))),
               (SELECT COUNT(*) FROM clean.customers WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))) OR DATALENGTH(gender) <> DATALENGTH(LTRIM(RTRIM(gender))))
             + (SELECT COUNT(*) FROM clean.contracts WHERE DATALENGTH(contract_type) <> DATALENGTH(LTRIM(RTRIM(contract_type))) OR DATALENGTH(payment_method) <> DATALENGTH(LTRIM(RTRIM(payment_method))))
             + (SELECT COUNT(*) FROM clean.services WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM clean.invoices WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM clean.tickets WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id)))),
               NULL, N'after = 0',
               N'DATALENGTH because SQL Server ignores trailing spaces when comparing with ='
        UNION ALL
        SELECT 'ERR_NON_ISO_DATE', N'2. Errors before/after cleaning', N'Date strings not in ISO format',
               N'contracts.start_date/end_date, tickets.created_at/resolved_at',
               (SELECT COUNT(*) FROM stg.crm_contracts CROSS APPLY (VALUES (start_date), (end_date)) v(x) WHERE clean.fn_date_format(x) NOT IN ('ISO', 'EMPTY'))
             + (SELECT COUNT(*) FROM stg.ticket_support_tickets CROSS APPLY (VALUES (created_at), (resolved_at)) v(x) WHERE clean.fn_date_format(x) NOT IN ('ISO', 'EMPTY')),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE reason_code = 'INVALID_DATE'
                AND source_table IN (N'stg.crm_contracts', N'stg.ticket_support_tickets')),
               NULL, N'after (rows that cannot be parsed) = 0', N'Clean stores DATE/DATETIME2; after = rows rejected because the date could not be read'
        UNION ALL
        SELECT 'ERR_NEGATIVE_AMOUNT', N'2. Errors before/after cleaning', N'Negative invoice amount', N'invoices.amount_usd',
               (SELECT COUNT(*) FROM stg.billing_invoices WHERE amount_usd < 0),
               (SELECT COUNT(*) FROM clean.invoices WHERE amount_usd < 0),
               NULL, N'after = 0', CONCAT(N'Sign flipped on ', (SELECT COUNT(*) FROM clean.invoices WHERE amount_source = 'SIGN_CORRECTED'), N' rows')
        UNION ALL
        SELECT 'ERR_NULL_AMOUNT', N'2. Errors before/after cleaning', N'NULL invoice amount', N'invoices.amount_usd',
               (SELECT COUNT(*) FROM stg.billing_invoices WHERE amount_usd IS NULL),
               (SELECT COUNT(*) FROM clean.invoices WHERE amount_usd IS NULL),
               NULL, N'after = 0',
               (SELECT N'Recovered: ' + STRING_AGG(CONCAT(amount_source, N'=', n), N', ')
                FROM (SELECT amount_source, COUNT(*) n FROM clean.invoices
                      WHERE amount_source IN ('FROM_PAYMENT', 'IMPUTED_PREV_INVOICE', 'IMPUTED_NEXT_INVOICE', 'IMPUTED_CONTRACT_PRICE')
                      GROUP BY amount_source) x)
        UNION ALL
        SELECT 'ERR_TOTAL_CHARGES_BLANK', N'2. Errors before/after cleaning', N'Blank TotalCharges (present in the original data)', N'contracts.total_charges',
               (SELECT COUNT(*) FROM stg.crm_contracts WHERE NULLIF(LTRIM(RTRIM(total_charges)), N'') IS NULL),
               (SELECT COUNT(*) FROM clean.contracts WHERE total_charges IS NULL AND tenure_months > 0),
               NULL, N'after (blank with tenure > 0) = 0', N'Blank is only valid for tenure = 0 customers (nothing billed yet); kept as NULL';
        UPDATE #dq SET status = CASE WHEN value_after = 0 THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'2. Errors before/after cleaning';

        /* 3. Key reconciliation between CRM and Billing. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'KEY_ORPHAN_INVOICE', N'3. CRM - Billing reconciliation', N'Invoices for a customer_id missing from CRM', N'invoices.customer_id',
               (SELECT COUNT(*) FROM stg.billing_invoices i
                WHERE NOT EXISTS (SELECT 1 FROM stg.crm_customers c WHERE LTRIM(RTRIM(c.customer_id)) = LTRIM(RTRIM(i.customer_id)))),
               (SELECT COUNT(*) FROM clean.invoices i WHERE NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = i.customer_id)),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE source_table = N'stg.billing_invoices' AND reason_code = 'ORPHAN_CUSTOMER'),
               N'after = 0', NULL,
               (SELECT CONCAT(COUNT(DISTINCT LTRIM(RTRIM(i.customer_id))), N' orphan customer_id')
                FROM stg.billing_invoices i
                WHERE NOT EXISTS (SELECT 1 FROM stg.crm_customers c WHERE LTRIM(RTRIM(c.customer_id)) = LTRIM(RTRIM(i.customer_id))))
        UNION ALL
        -- A customer whose every billing period falls in a month with no invoices at all (billing outage) has an
        -- explained gap (WARN); anything else is a FAIL.
        SELECT 'KEY_BILLED_CUSTOMER_NO_INVOICE', N'3. CRM - Billing reconciliation', N'Customer billed per CRM but with no invoice', N'contracts vs invoices',
               NULL, COUNT(*), NULL, N'after = 0; WARN if all of the customer''s periods fall in the billing outage month',
               CASE WHEN COUNT(*) = 0 THEN 'PASS' WHEN SUM(x.explained) = COUNT(*) THEN 'WARN' ELSE 'FAIL' END,
               CONCAT(SUM(x.explained), N'/', COUNT(*), N' customers only have periods in a month with no invoices')
        FROM clean.contracts k
        CROSS APPLY (SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM clean.invoices i2
                                                  WHERE i2.billing_month BETWEEN k.first_billing_month AND k.last_billing_month)
                                 THEN 1 ELSE 0 END AS explained) x
        WHERE k.first_billing_month IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM clean.invoices i WHERE i.customer_id = k.customer_id)
        UNION ALL
        SELECT 'KEY_INVOICE_OUTSIDE_CONTRACT', N'3. CRM - Billing reconciliation', N'Invoice outside the contract lifetime', N'invoices vs contracts',
               NULL, NULL,
               (SELECT COUNT(*) FROM clean.rejected_records WHERE source_table = N'stg.billing_invoices' AND reason_code = 'OUTSIDE_CONTRACT_PERIOD'),
               N'rejected = 0', NULL, NULL
        UNION ALL
        SELECT 'KEY_TENURE_VS_INVOICES', N'3. CRM - Billing reconciliation', N'CRM tenure_months differs from periods implied by contract dates', N'contracts',
               NULL,
               (SELECT COUNT(*) FROM clean.contracts WHERE first_billing_month IS NOT NULL
                AND DATEDIFF(MONTH, first_billing_month, last_billing_month) + 1 <> tenure_months),
               NULL, N'after = 0', NULL, NULL;
        UPDATE #dq SET status = CASE WHEN COALESCE(value_after, value_rejected) = 0 THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'3. CRM - Billing reconciliation' AND check_id NOT IN ('KEY_ORPHAN_INVOICE', 'KEY_BILLED_CUSTOMER_NO_INVOICE');
        UPDATE #dq SET status = CASE WHEN value_after = 0 AND value_rejected = value_before THEN 'PASS' ELSE 'FAIL' END
        WHERE check_id = 'KEY_ORPHAN_INVOICE';

        -- Months missing invoices compared with the CRM billing calendar: finds a billing outage without knowing the month in advance.
        WITH expected AS (
            SELECT d.[date] AS billing_month, COUNT(*) AS customers
            FROM clean.contracts k
            JOIN mart.dim_date d ON d.is_month_start = 1 AND d.[date] BETWEEN k.first_billing_month AND k.last_billing_month
            GROUP BY d.[date]
        ), actual AS (
            SELECT billing_month, COUNT(*) AS invoices FROM clean.invoices GROUP BY billing_month
        ), gap AS (
            SELECT e.billing_month, e.customers, ISNULL(a.invoices, 0) AS invoices
            FROM expected e LEFT JOIN actual a ON a.billing_month = e.billing_month
            WHERE e.customers <> ISNULL(a.invoices, 0)
        )
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'KEY_MISSING_INVOICE_MONTH', N'3. CRM - Billing reconciliation', N'Customer-months in the CRM billing calendar without an invoice',
               N'contracts vs invoices', (SELECT SUM(customers) FROM expected), (SELECT ISNULL(SUM(customers - invoices), 0) FROM gap), NULL,
               N'after = 0; WARN when a whole month is missing (estimated in fact_billing)',
               CASE WHEN NOT EXISTS (SELECT 1 FROM gap) THEN 'PASS'
                    WHEN NOT EXISTS (SELECT 1 FROM gap WHERE invoices > 0) THEN 'WARN' ELSE 'FAIL' END,
               (SELECT STRING_AGG(CONCAT(CONVERT(CHAR(7), billing_month, 120), N': missing ', customers - invoices, N'/', customers), N'; ') FROM gap);

        /* 4. Amount totals before/after. The stg -> clean difference must be fully explained by the fixes. */
        DECLARE @stg_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM stg.billing_invoices);
        DECLARE @clean_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM clean.invoices);
        DECLARE @sign_fix DECIMAL(18,2) = (SELECT ISNULL(SUM(2 * amount_usd), 0) FROM clean.invoices WHERE amount_source = 'SIGN_CORRECTED');
        DECLARE @null_fix DECIMAL(18,2) = (SELECT ISNULL(SUM(amount_usd), 0) FROM clean.invoices
                                           WHERE amount_source IN ('FROM_PAYMENT', 'IMPUTED_PREV_INVOICE', 'IMPUTED_NEXT_INVOICE', 'IMPUTED_CONTRACT_PRICE'));
        DECLARE @rejected_sum DECIMAL(18,2) = (SELECT ISNULL(SUM(s.amount_usd), 0) FROM stg.billing_invoices s
                                               JOIN clean.rejected_records r ON r.source_table = N'stg.billing_invoices' AND r.stg_row_id = s.stg_row_id);
        DECLARE @mart_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM mart.fact_billing);
        DECLARE @mart_imputed DECIMAL(18,2) = (SELECT ISNULL(SUM(amount_usd), 0) FROM mart.fact_billing WHERE amount_source = 'IMPUTED_MISSING_INVOICE');
        DECLARE @pay_stg DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM stg.billing_payments);
        DECLARE @pay_clean DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM clean.payments);
        DECLARE @pay_rejected DECIMAL(18,2) = (SELECT ISNULL(SUM(s.amount_usd), 0) FROM stg.billing_payments s
                                               JOIN clean.rejected_records r ON r.source_table = N'stg.billing_payments' AND r.stg_row_id = s.stg_row_id);

        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        VALUES
        ('AMT_INVOICE_STG_CLEAN', N'4. Amount totals', N'Invoice amount total stg -> clean (USD)', N'invoices',
         @stg_sum, @clean_sum, @rejected_sum,
         N'clean = stg - rejected + 2 x |sign-flipped| + recovered NULLs',
         CASE WHEN ABS(@clean_sum - (@stg_sum - @rejected_sum + @sign_fix + @null_fix)) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
         CONCAT(N'+', @sign_fix, N' from sign fixes; +', @null_fix, N' from recovered NULLs; -', @rejected_sum, N' from rejected rows')),
        ('AMT_INVOICE_CLEAN_MART', N'4. Amount totals', N'Amount total clean.invoices -> mart.fact_billing (USD)', N'fact_billing',
         @clean_sum, @mart_sum, NULL,
         N'mart = clean + estimates for months without an invoice',
         CASE WHEN ABS(@mart_sum - (@clean_sum + @mart_imputed)) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
         CONCAT(N'+', @mart_imputed, N' estimated for customer-months without an invoice')),
        ('AMT_PAYMENT_STG_CLEAN', N'4. Amount totals', N'Payment total stg -> clean (USD)', N'payments',
         @pay_stg, @pay_clean, @pay_rejected, N'clean = stg - rejected',
         CASE WHEN ABS(@pay_clean - (@pay_stg - @pay_rejected)) < 0.01 THEN 'PASS' ELSE 'FAIL' END, NULL);

        -- Check the assumption "negative = sign entry error": after flipping, the amount must equal the amount paid.
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'AMT_SIGN_FIX_MATCHES_PAYMENT', N'4. Amount totals', N'Sign-flipped invoices match the amount paid', N'invoices vs payments',
               COUNT(*), SUM(CASE WHEN p.paid = i.amount_usd THEN 1 ELSE 0 END), NULL,
               N'after = before (for invoices that have a payment)',
               CASE WHEN COUNT(*) = SUM(CASE WHEN p.paid = i.amount_usd THEN 1 ELSE 0 END) THEN 'PASS' ELSE 'WARN' END,
               N'Only invoices that were sign-flipped and have a payment'
        FROM clean.invoices i
        JOIN (SELECT invoice_id, SUM(amount_usd) paid FROM clean.payments GROUP BY invoice_id) p ON p.invoice_id = i.invoice_id
        WHERE i.amount_source = 'SIGN_CORRECTED';

        /* 5. Completeness of reference data. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'REF_FX_COVERAGE', N'5. Reference data', N'Billed months without an FX rate', N'fx_rates',
               NULL, COUNT(*), NULL, N'after = 0', CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
               (SELECT STRING_AGG(CONCAT(provider, N' (', granularity, N'): ', n, N' months'), N'; ')
                FROM (SELECT provider, granularity, COUNT(*) n FROM clean.fx_rates GROUP BY provider, granularity) x)
        FROM (SELECT DISTINCT billing_month FROM clean.invoices) i
        WHERE NOT EXISTS (SELECT 1 FROM clean.fx_rates f WHERE f.rate_month = i.billing_month)
        UNION ALL
        SELECT 'REF_TARGET_COVERAGE', N'5. Reference data', N'Months with a target in the analysis window', N'targets',
               24, COUNT(*), NULL, N'after = 24', CASE WHEN COUNT(*) = 24 THEN 'PASS' ELSE 'FAIL' END, NULL
        FROM clean.targets
        WHERE target_month BETWEEN dbo.fn_config_date('analysis_window_start') AND dbo.fn_config_date('snapshot_date');

        INSERT INTO mart.dq_check_results (batch_id, check_id, check_group, check_name, object_name, value_before,
            value_after, value_rejected, expected_rule, status, note, checked_at)
        SELECT @batch_id, check_id, check_group, check_name, object_name, value_before, value_after, value_rejected,
               expected_rule, status, note, SYSDATETIME()
        FROM #dq;

        SELECT @msg = STRING_AGG(CONCAT(status, N'=', n), N', ') FROM (SELECT status, COUNT(*) n FROM #dq GROUP BY status) x;
        DECLARE @n INT = (SELECT COUNT(*) FROM #dq);
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', NULL, @n, @msg;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', NULL, NULL, @msg;
        THROW;
    END CATCH
END
GO
