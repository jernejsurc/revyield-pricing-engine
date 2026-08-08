-- =============================================================================
-- RevYield  ·  sql/02_tier_expansion.sql
--
-- QUESTION
--   Which active accounts have outgrown what they are paying for, and in what
--   order should account managers work them?
--
-- METHOD
--   Usage is measured against what the account is contractually entitled to, on
--   three dimensions blended into one weighted score (0.45 / 0.30 / 0.25).
--
--   Seats are metered against the seats the account actually bought, taken from
--   its live contracts - not against the tier's seat ceiling. "You are paying for
--   240 seats and using 310" is the conversation; "you are below the Enterprise
--   seat cap" is not. API calls and storage are metered against the tier's
--   included platform pools in dim_tier_entitlements, which is what those
--   entitlements are. The tier seat ceiling still does real work: breaching it is
--   what routes an account to an upgrade rather than a seat top-up.
--
--   A single month over the line is noise - a laggy integration or one bulk
--   import will spike API calls. An account qualifies only when it clears the
--   85% threshold in the current month AND the month before, which is what LAG()
--   is doing here.
--
--   The Expansion Readiness Index blends three percentile ranks, so the score is
--   a position in the book rather than an absolute number that drifts as the
--   business grows:
--       50%  how far over capacity the account is now
--       25%  momentum - how fast utilisation moved over the last quarter
--       25%  how much revenue is attached to the account today
--
--   Only seat overage carries a revenue estimate. The rate card sells seats and
--   nothing else, so accounts breaching an API or storage pool are surfaced with
--   the binding constraint named and expansion_acv_opportunity = 0, rather than
--   being sized against an overage rate that does not exist.
--
-- OUTPUT GRAIN
--   One row per expansion-ready account, ranked. Account managers work P1 first.
-- =============================================================================

WITH reporting_period AS (
    -- Anchor to the latest snapshot in the warehouse rather than CURRENT_DATE,
    -- so the query returns the same answer whenever it is run.
    SELECT MAX(recorded_date) AS as_of_date
    FROM fact_usage_metrics
),

live_contracts AS (
    -- What the account holds today. Mid-term expansions are co-terminus with
    -- their parent contract, so overlapping rows are additive, not duplicates.
    SELECT
        t.account_id,
        SUM(t.realized_price)    AS current_acv,
        SUM(t.contracted_seats)  AS contracted_seats,
        AVG(t.discount_pct)      AS avg_discount_pct,
        MIN(t.contract_end_date) AS next_renewal_date
    FROM fact_transactions AS t
    CROSS JOIN reporting_period AS r
    WHERE t.deal_stage = 'closed_won'
      AND t.contract_start_date <= r.as_of_date
      AND t.contract_end_date   >  r.as_of_date
    GROUP BY t.account_id
),

usage_scored AS (
    -- Historical months are scored against the CURRENT contract on purpose: the
    -- question is "how long has this account been over what it pays for today",
    -- and a common denominator also makes the momentum term a clean read on
    -- consumption rather than an artefact of past contract changes.
    SELECT
        u.account_id,
        u.recorded_date,
        u.active_seats,
        u.api_calls_count,
        u.storage_gb,
        e.contract_tier,
        e.tier_rank,
        e.included_seats,
        e.capacity_threshold_pct,
        lc.contracted_seats,
        u.active_seats::numeric    / lc.contracted_seats    AS seat_utilisation,
        u.api_calls_count::numeric / e.included_api_calls   AS api_utilisation,
        u.storage_gb               / e.included_storage_gb  AS storage_utilisation,
        ( 0.45 * u.active_seats::numeric    / lc.contracted_seats
        + 0.30 * u.api_calls_count::numeric / e.included_api_calls
        + 0.25 * u.storage_gb               / e.included_storage_gb ) AS utilisation_score
    FROM fact_usage_metrics    AS u
    JOIN dim_accounts          AS a  ON a.account_id    = u.account_id
    JOIN dim_tier_entitlements AS e  ON e.contract_tier = a.current_tier
    JOIN live_contracts        AS lc ON lc.account_id   = u.account_id
    WHERE a.account_status = 'active'
),

usage_windowed AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER w_desc              AS recency_rank,
        LAG(utilisation_score, 1) OVER w_asc  AS score_prev_month,
        LAG(utilisation_score, 3) OVER w_asc  AS score_prior_quarter,
        COUNT(*) OVER (PARTITION BY account_id) AS months_observed
    FROM usage_scored AS s
    WINDOW w_asc  AS (PARTITION BY account_id ORDER BY recorded_date),
           w_desc AS (PARTITION BY account_id ORDER BY recorded_date DESC)
),

candidates AS (
    SELECT
        w.account_id,
        a.company_name,
        a.industry,
        a.region,
        w.contract_tier,
        w.tier_rank,
        w.recorded_date                                  AS as_of_date,
        w.utilisation_score,
        w.seat_utilisation,
        w.api_utilisation,
        w.storage_utilisation,
        w.capacity_threshold_pct,
        w.utilisation_score - w.score_prior_quarter      AS momentum_qoq,
        w.active_seats,
        w.contracted_seats,
        w.included_seats,
        GREATEST(w.active_seats - w.contracted_seats, 0) AS seats_over_contracted,
        lc.current_acv,
        lc.next_renewal_date,
        lc.avg_discount_pct,
        nxt.contract_tier                                AS next_tier,
        cur.annual_list_price_per_seat                   AS current_tier_price_per_seat
    FROM usage_windowed        AS w
    JOIN dim_accounts          AS a   ON a.account_id      = w.account_id
    JOIN live_contracts        AS lc  ON lc.account_id     = w.account_id
    JOIN dim_tier_entitlements AS cur ON cur.contract_tier = w.contract_tier
    LEFT JOIN dim_tier_entitlements AS nxt ON nxt.tier_rank = w.tier_rank + 1
    WHERE w.recency_rank    = 1                              -- latest snapshot
      AND w.months_observed >= 4                             -- enough history to trend
      AND w.utilisation_score >= w.capacity_threshold_pct    -- over the line now
      AND w.score_prev_month  >= w.capacity_threshold_pct    -- and last month too
),

metrics AS (
    SELECT
        c.*,
        GREATEST(c.seat_utilisation, c.api_utilisation, c.storage_utilisation) AS binding_utilisation,
        CASE GREATEST(c.seat_utilisation, c.api_utilisation, c.storage_utilisation)
             WHEN c.seat_utilisation    THEN 'seats'
             WHEN c.api_utilisation     THEN 'api_calls'
             ELSE                            'storage'
        END AS binding_constraint
    FROM candidates AS c
),

scored AS (
    SELECT
        m.*,
        -- Only seat overage is priced. The price book in pricing_rules.json sells
        -- seats and nothing else, so an account over its API or storage pool is
        -- flagged for a commercial conversation but carries no revenue estimate -
        -- inventing an overage rate would put a number in front of a hiring
        -- manager that no rate card supports.
        ROUND(m.seats_over_contracted * m.current_tier_price_per_seat, 2)
            AS expansion_acv_opportunity,
        CASE
            -- Past the tier's seat ceiling with somewhere to go: move the account.
            WHEN m.active_seats > m.included_seats
             AND m.next_tier IS NOT NULL              THEN 'UPGRADE to ' || m.next_tier
            WHEN m.seats_over_contracted > 0          THEN 'SEAT EXPANSION'
            WHEN m.binding_utilisation >= 1.0         THEN 'CAPACITY OVERAGE - ' || m.binding_constraint
            ELSE                                           'PROACTIVE - approaching capacity'
        END AS recommended_action,
        PERCENT_RANK() OVER (ORDER BY m.utilisation_score)         AS pr_utilisation,
        PERCENT_RANK() OVER (ORDER BY COALESCE(m.momentum_qoq, 0)) AS pr_momentum,
        PERCENT_RANK() OVER (ORDER BY m.current_acv)               AS pr_value
    FROM metrics AS m
),

indexed AS (
    SELECT
        s.*,
        ROUND((100 * (0.50 * pr_utilisation
                    + 0.25 * pr_momentum
                    + 0.25 * pr_value))::numeric, 1) AS expansion_readiness_index
    FROM scored AS s
)

SELECT
    account_id,
    company_name,
    industry,
    region,
    contract_tier,
    as_of_date,
    expansion_readiness_index,
    CASE NTILE(4) OVER (ORDER BY expansion_readiness_index DESC)
         WHEN 1 THEN 'P1 - contact this week'
         WHEN 2 THEN 'P2 - this quarter'
         WHEN 3 THEN 'P3 - monitor'
         ELSE        'P4 - watchlist'
    END                                                     AS priority_band,
    RANK() OVER (PARTITION BY region
                 ORDER BY expansion_readiness_index DESC)   AS rank_in_region,

    binding_constraint,
    ROUND(utilisation_score   * 100, 1)                     AS utilisation_pct,
    ROUND(seat_utilisation    * 100, 1)                     AS seat_utilisation_pct,
    ROUND(api_utilisation     * 100, 1)                     AS api_utilisation_pct,
    ROUND(storage_utilisation * 100, 1)                     AS storage_utilisation_pct,
    ROUND(momentum_qoq        * 100, 1)                     AS momentum_qoq_pp,

    active_seats,
    contracted_seats,
    seats_over_contracted,
    ROUND(current_acv, 0)                                   AS current_acv,
    expansion_acv_opportunity,
    ROUND(expansion_acv_opportunity
          / NULLIF(current_acv, 0) * 100, 1)                AS uplift_on_current_acv_pct,
    ROUND(avg_discount_pct * 100, 1)                        AS avg_discount_pct,
    next_renewal_date,
    recommended_action,

    -- Running total, so a manager can see how much of the opportunity the top N
    -- accounts cover before deciding how far down the list to work. The window
    -- ordering must match the ORDER BY below or the running total will not be
    -- monotonic in the output.
    ROUND(SUM(expansion_acv_opportunity)
          OVER (ORDER BY expansion_readiness_index DESC, current_acv DESC, account_id
                ROWS UNBOUNDED PRECEDING), 0)               AS cumulative_acv_opportunity
FROM indexed
ORDER BY expansion_readiness_index DESC, current_acv DESC, account_id;
