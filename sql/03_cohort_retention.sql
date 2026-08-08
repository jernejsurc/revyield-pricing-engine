-- =============================================================================
-- RevYield  ·  sql/03_cohort_retention.sql
--
-- QUESTION
--   Once a cohort has landed, does its revenue grow or decay - and how much of
--   the movement is expansion, contraction and outright churn?
--
-- METHOD
--   There is no MRR table. Recurring revenue is reconstructed from the deal
--   ledger: every closed-won contract contributes realized_price / 12 for every
--   month between contract_start_date and contract_end_date. Mid-term expansions
--   are sold co-terminus with their parent contract, so overlapping rows are
--   genuinely additive rather than double counted.
--
--   Accounts are placed on a gap-free monthly spine built from dim_date. The gap
--   matters: a churned account is one that simply stops appearing in the ledger,
--   and without the spine that month would vanish instead of registering as a
--   loss. LAG() over the spine turns each account-month into a movement type.
--
--   Two retention measures, because they answer different questions:
--     nrr_mom_pct  month-over-month, excludes new logos - the operational read
--     nrr_ttm_pct  vs the same cohort 12 months earlier - the board read
--   A signup cohort is a closed population, so no new logos enter after month 0
--   and the trailing-twelve comparison is a true like-for-like.
--
-- OUTPUT GRAIN
--   One row per (cohort_month × month_index).
-- =============================================================================

WITH reporting_period AS (
    SELECT DATE_TRUNC('month', MAX(recorded_date))::date AS as_of_month
    FROM fact_usage_metrics
),

month_spine AS (
    SELECT DISTINCT d.month_start, d.month_end
    FROM dim_date AS d
    CROSS JOIN reporting_period AS r
    WHERE d.month_start >= (SELECT DATE_TRUNC('month', MIN(signup_date))::date FROM dim_accounts)
      AND d.month_start <= r.as_of_month
),

account_spine AS (
    -- Every account gets a row for every month from its signup month onward,
    -- whether or not it was paying that month.
    SELECT
        a.account_id,
        DATE_TRUNC('month', a.signup_date)::date AS cohort_month,
        m.month_start,
        m.month_end
    FROM dim_accounts AS a
    CROSS JOIN month_spine AS m
    WHERE m.month_start >= DATE_TRUNC('month', a.signup_date)::date
),

account_mrr AS (
    -- MRR is a point-in-time snapshot taken at month END, matching how
    -- fact_usage_metrics is recorded. Testing liveness at the month START would
    -- make every account that signed after the 1st invisible in its own cohort
    -- month, which inflates every downstream retention ratio against an
    -- artificially tiny month-zero base.
    SELECT
        s.account_id,
        s.cohort_month,
        s.month_start,
        COALESCE(SUM(t.mrr), 0) AS mrr
    FROM account_spine AS s
    LEFT JOIN fact_transactions AS t
           ON t.account_id          = s.account_id
          AND t.deal_stage          = 'closed_won'
          AND t.contract_start_date <= s.month_end
          AND t.contract_end_date   >  s.month_end
    GROUP BY s.account_id, s.cohort_month, s.month_start
),

movement AS (
    SELECT
        m.*,
        LAG(mrr) OVER w                                     AS prev_mrr,
        MIN(month_start) FILTER (WHERE mrr > 0) OVER (
            PARTITION BY account_id
        )                                                   AS first_paid_month
    FROM account_mrr AS m
    WINDOW w AS (PARTITION BY account_id ORDER BY month_start)
),

classified AS (
    SELECT
        *,
        CASE
            -- An account that signs mid-month may not bill until the month after,
            -- so 'new' is the first month with revenue, not the first month on file.
            WHEN month_start = first_paid_month           THEN 'new'
            WHEN COALESCE(prev_mrr, 0) = 0 AND mrr > 0    THEN 'reactivation'
            WHEN COALESCE(prev_mrr, 0) > 0 AND mrr = 0    THEN 'churn'
            WHEN mrr > prev_mrr                           THEN 'expansion'
            WHEN mrr < prev_mrr                           THEN 'contraction'
            ELSE 'flat'
        END AS movement_type
    FROM movement
),

cohort_size AS (
    SELECT
        DATE_TRUNC('month', signup_date)::date AS cohort_month,
        COUNT(*)                               AS cohort_accounts
    FROM dim_accounts
    GROUP BY 1
),

cohort_month_agg AS (
    SELECT
        c.cohort_month,
        ( (EXTRACT(YEAR  FROM c.month_start) - EXTRACT(YEAR  FROM c.cohort_month)) * 12
        + (EXTRACT(MONTH FROM c.month_start) - EXTRACT(MONTH FROM c.cohort_month)) )::int AS month_index,
        c.month_start,
        COUNT(*) FILTER (WHERE c.mrr > 0)                                AS active_accounts,
        COUNT(*) FILTER (WHERE c.movement_type = 'churn')                AS churned_accounts,
        COALESCE(SUM(c.prev_mrr), 0)                                     AS starting_mrr,
        SUM(c.mrr)                                                       AS ending_mrr,
        COALESCE(SUM(c.mrr)
                 FILTER (WHERE c.movement_type = 'new'), 0)              AS new_mrr,
        COALESCE(SUM(c.mrr - COALESCE(c.prev_mrr, 0))
                 FILTER (WHERE c.movement_type IN ('expansion', 'reactivation')), 0) AS expansion_mrr,
        COALESCE(SUM(COALESCE(c.prev_mrr, 0) - c.mrr)
                 FILTER (WHERE c.movement_type = 'contraction'), 0)      AS contraction_mrr,
        COALESCE(SUM(c.prev_mrr)
                 FILTER (WHERE c.movement_type = 'churn'), 0)            AS churned_mrr
    FROM classified AS c
    GROUP BY c.cohort_month, c.month_start
)

SELECT
    TO_CHAR(a.cohort_month, 'YYYY-MM')                      AS cohort_month,
    a.month_index,
    z.cohort_accounts,
    a.active_accounts,
    a.churned_accounts,

    ROUND(a.starting_mrr,     0)                            AS starting_mrr,
    ROUND(a.new_mrr,          0)                            AS new_mrr,
    ROUND(a.expansion_mrr,    0)                            AS expansion_mrr,
    ROUND(-a.contraction_mrr, 0)                            AS contraction_mrr,
    ROUND(-a.churned_mrr,     0)                            AS churned_mrr,
    ROUND(a.ending_mrr,       0)                            AS ending_mrr,

    -- Net revenue retention, month over month. New logos are deliberately out of
    -- the numerator: NRR measures what the existing base did, not how much the
    -- sales team added on top.
    ROUND(( a.starting_mrr + a.expansion_mrr - a.contraction_mrr - a.churned_mrr)
          / NULLIF(a.starting_mrr, 0) * 100, 1)             AS nrr_mom_pct,
    ROUND(( a.starting_mrr - a.contraction_mrr - a.churned_mrr)
          / NULLIF(a.starting_mrr, 0) * 100, 1)             AS grr_mom_pct,

    -- Trailing twelve months against the same closed cohort.
    ROUND(a.ending_mrr
          / NULLIF(LAG(a.ending_mrr, 12) OVER w_cohort, 0) * 100, 1) AS nrr_ttm_pct,

    -- Classic cohort curve: revenue and logos indexed to the cohort's first month.
    ROUND(a.ending_mrr
          / NULLIF(FIRST_VALUE(a.ending_mrr) OVER w_cohort, 0) * 100, 1) AS mrr_retention_vs_m0_pct,
    ROUND(a.active_accounts::numeric
          / NULLIF(FIRST_VALUE(a.active_accounts) OVER w_cohort, 0) * 100, 1) AS logo_retention_vs_m0_pct,

    ROUND(a.ending_mrr / NULLIF(a.active_accounts, 0), 0)   AS arpa,
    ROUND(SUM(a.churned_mrr) OVER (
              PARTITION BY a.cohort_month ORDER BY a.month_index
              ROWS UNBOUNDED PRECEDING), 0)                 AS cumulative_churned_mrr
FROM cohort_month_agg AS a
JOIN cohort_size      AS z ON z.cohort_month = a.cohort_month
WINDOW w_cohort AS (PARTITION BY a.cohort_month ORDER BY a.month_index)
ORDER BY a.cohort_month, a.month_index;
