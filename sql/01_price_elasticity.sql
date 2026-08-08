-- =============================================================================
-- RevYield  ·  sql/01_price_elasticity.sql
--
-- QUESTION
--   The FY26-H1 price test raised list prices and tightened discount governance
--   for a random half of the book. Which tiers absorbed it, and what did it do
--   to gross margin?
--
-- METHOD
--   Post-stratified A/B evaluation.
--     Q = contracted seats per opportunity   (lost deals contribute zero seats,
--         so the measure captures both order-size and win-rate effects)
--     P = volume-weighted realized price per seat
--     E = %ΔQ / %ΔP
--
--   Every figure is computed inside (contract_tier × deal_type) strata and then
--   recombined using control-arm exposure weights. This is not optional:
--   new-business deals are several times larger than expansion add-ons, and a
--   chance imbalance in deal mix between the arms is large enough to invert the
--   sign of the Starter elasticity. An unstratified average of the same data
--   reports +0.11 where the truth is roughly -1.7.
--
--   A 95% interval on %ΔQ is carried through to the elasticity by the delta
--   method, so a tier whose result is indistinguishable from zero says so
--   instead of quoting a spuriously precise coefficient.
--
-- FALSIFICATION CHECK
--   The demand response in this dataset acts on contracted volume, and win rates
--   were dealt from an exact quota that is identical across arms. win_rate_gap_pp
--   must therefore sit near zero. A material gap means the assignment or the
--   pipeline is broken, not that the price test moved win rates.
--
-- OUTPUT GRAIN
--   One row per contract_tier, plus a PORTFOLIO roll-up row.
-- =============================================================================

WITH stratum AS (
    -- One cell per (tier × deal_type × arm). Renewals and mid-term upgrades were
    -- grandfathered onto the legacy price card and carry 'not_in_test'; they are
    -- an explicit exclusion bucket, not missing data.
    SELECT
        t.contract_tier,
        t.deal_type,
        t.pricing_variant,
        COUNT(*)                                                          AS opportunities,
        COUNT(*) FILTER (WHERE t.deal_stage = 'closed_won')               AS wins,
        COALESCE(SUM(t.contracted_seats)
                 FILTER (WHERE t.deal_stage = 'closed_won'), 0)::numeric  AS seats,
        COALESCE(SUM(t.realized_price)
                 FILTER (WHERE t.deal_stage = 'closed_won'), 0)           AS revenue,
        COALESCE(SUM(t.gross_margin)
                 FILTER (WHERE t.deal_stage = 'closed_won'), 0)           AS gross_margin,
        -- Per-opportunity seat contribution: a lost deal is a real zero, not a
        -- missing observation, so it belongs in both the mean and the variance.
        AVG(CASE WHEN t.deal_stage = 'closed_won'
                 THEN t.contracted_seats ELSE 0 END)::numeric             AS seat_mean,
        COALESCE(VAR_SAMP(CASE WHEN t.deal_stage = 'closed_won'
                               THEN t.contracted_seats ELSE 0 END), 0)::numeric AS seat_var
    FROM fact_transactions AS t
    WHERE t.pricing_variant IN ('control', 'test')
    GROUP BY t.contract_tier, t.deal_type, t.pricing_variant
),

paired AS (
    -- Pivot the arms side by side and keep only strata observed in both, so a
    -- deal type present in one arm alone cannot leak into the comparison.
    -- Stratum weights come from control-arm exposure.
    SELECT
        c.contract_tier,
        c.deal_type,
        c.opportunities                                              AS c_opp,
        t.opportunities                                              AS t_opp,
        c.wins                                                       AS c_wins,
        t.wins                                                       AS t_wins,
        c.seats                                                      AS c_seats,
        t.seats                                                      AS t_seats,
        c.seat_mean                                                  AS c_seat_mean,
        t.seat_mean                                                  AS t_seat_mean,
        c.seat_var                                                   AS c_seat_var,
        t.seat_var                                                   AS t_seat_var,
        c.revenue / c.seats                                          AS c_price_per_seat,
        t.revenue / t.seats                                          AS t_price_per_seat,
        c.revenue      / c.opportunities                             AS c_rev_per_opp,
        t.revenue      / t.opportunities                             AS t_rev_per_opp,
        c.gross_margin / c.opportunities                             AS c_gm_per_opp,
        t.gross_margin / t.opportunities                             AS t_gm_per_opp,
        SUM(c.opportunities) OVER (PARTITION BY c.contract_tier)     AS tot_opp,
        SUM(c.seats)         OVER (PARTITION BY c.contract_tier)     AS tot_seats
    FROM stratum AS c
    JOIN stratum AS t
      ON t.contract_tier = c.contract_tier
     AND t.deal_type     = c.deal_type
     AND t.pricing_variant = 'test'
    WHERE c.pricing_variant = 'control'
      AND c.seats > 0
      AND t.seats > 0
),

tier_stats AS (
    SELECT
        contract_tier,
        SUM(c_opp)                                          AS control_opportunities,
        SUM(t_opp)                                          AS test_opportunities,
        SUM(c_seats)                                        AS control_seats,
        SUM(t_seats)                                        AS test_seats,

        -- Stratified quantity: seats per opportunity, control-weighted.
        SUM(c_opp / tot_opp * c_seat_mean)                  AS control_q,
        SUM(c_opp / tot_opp * t_seat_mean)                  AS test_q,

        -- Stratified price: realized per seat, weighted by control seat volume.
        SUM(c_seats / tot_seats * c_price_per_seat)         AS control_p,
        SUM(c_seats / tot_seats * t_price_per_seat)         AS test_p,

        -- Variance of the stratified quantity estimator: Var = Σ (w/W)² · s²/n
        SUM(POWER(c_opp / tot_opp, 2) * c_seat_var / c_opp) AS control_q_var,
        SUM(POWER(c_opp / tot_opp, 2) * t_seat_var / t_opp) AS test_q_var,

        SUM(c_opp / tot_opp * c_gm_per_opp)                 AS control_gm_per_opp,
        SUM(c_opp / tot_opp * t_gm_per_opp)                 AS test_gm_per_opp,
        SUM(c_opp / tot_opp * c_rev_per_opp)                AS control_rev_per_opp,
        SUM(c_opp / tot_opp * t_rev_per_opp)                AS test_rev_per_opp,
        SUM(c_opp / tot_opp * c_wins / c_opp)               AS control_win_rate,
        SUM(c_opp / tot_opp * t_wins / t_opp)               AS test_win_rate
    FROM paired
    GROUP BY contract_tier
),

effects AS (
    SELECT
        s.*,
        e.elasticity_coefficient                            AS design_elasticity,
        e.tier_rank,
        test_p / control_p - 1                              AS pct_price_change,
        test_q / control_q - 1                              AS pct_quantity_change,
        -- Delta method on the log ratio: Var(ln(Qt/Qc)) ≈ Var(Qt)/Qt² + Var(Qc)/Qc²
        SQRT(test_q_var    / POWER(test_q, 2)
           + control_q_var / POWER(control_q, 2))           AS ln_ratio_se
    FROM tier_stats AS s
    JOIN dim_tier_entitlements AS e ON e.contract_tier = s.contract_tier
),

bounded AS (
    SELECT
        *,
        EXP(LN(test_q / control_q) - 1.96 * ln_ratio_se) - 1 AS pct_quantity_change_lo,
        EXP(LN(test_q / control_q) + 1.96 * ln_ratio_se) - 1 AS pct_quantity_change_hi
    FROM effects
)

SELECT
    CASE WHEN GROUPING(contract_tier) = 1
         THEN 'PORTFOLIO' ELSE MIN(contract_tier) END                 AS contract_tier,

    -- ---- exposure -------------------------------------------------------
    SUM(control_opportunities)::int                                   AS control_opps,
    SUM(test_opportunities)::int                                      AS test_opps,
    SUM(control_seats)::int                                           AS control_seats,
    SUM(test_seats)::int                                              AS test_seats,

    -- ---- the experiment read --------------------------------------------
    -- Price and quantity are per-seat measures on different price cards, so they
    -- are meaningless pooled across tiers and are suppressed on the roll-up row.
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(control_p), 2) END                            AS control_eur_per_seat,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(test_p), 2) END                               AS test_eur_per_seat,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(pct_price_change) * 100, 1) END               AS pct_price_change,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(pct_quantity_change) * 100, 1) END            AS pct_quantity_change,

    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(pct_quantity_change    / NULLIF(pct_price_change, 0)), 2) END AS elasticity,
    -- %ΔP is positive in both arms of this test, so the ordering of the %ΔQ
    -- bounds carries straight through the division.
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(pct_quantity_change_lo / NULLIF(pct_price_change, 0)), 2) END AS elasticity_ci_lo,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(pct_quantity_change_hi / NULLIF(pct_price_change, 0)), 2) END AS elasticity_ci_hi,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(design_elasticity), 2) END                    AS design_elasticity,

    -- Does the 95% interval on the volume response clear zero?
    CASE WHEN GROUPING(contract_tier) = 1                  THEN NULL
         WHEN MIN(pct_quantity_change_hi) < 0              THEN 'significant decline'
         WHEN MIN(pct_quantity_change_lo) > 0              THEN 'significant increase'
         ELSE 'not significant'
    END                                                               AS volume_effect,

    -- ---- falsification check: must be ~0 --------------------------------
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND((MIN(test_win_rate) - MIN(control_win_rate)) * 100, 1) END AS win_rate_gap_pp,

    -- ---- the commercial answer (exposure-weighted, so it rolls up) ------
    ROUND(SUM(control_gm_per_opp * control_opportunities)
          / SUM(control_opportunities), 0)                            AS control_gm_per_opp,
    ROUND(SUM(test_gm_per_opp * control_opportunities)
          / SUM(control_opportunities), 0)                            AS test_gm_per_opp,
    ROUND(( SUM(test_gm_per_opp    * control_opportunities)
          / SUM(control_gm_per_opp * control_opportunities) - 1) * 100, 1) AS gm_uplift_pct,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(control_gm_per_opp / NULLIF(control_rev_per_opp, 0)) * 100, 1) END AS control_gm_pct,
    CASE WHEN GROUPING(contract_tier) = 0
         THEN ROUND(MIN(test_gm_per_opp / NULLIF(test_rev_per_opp, 0)) * 100, 1) END       AS test_gm_pct,

    -- ---- recommendation --------------------------------------------------
    CASE
        WHEN GROUPING(contract_tier) = 1 THEN 'see per-tier rows'
        WHEN SUM(test_gm_per_opp    * control_opportunities)
           < SUM(control_gm_per_opp * control_opportunities)          THEN 'REJECT - margin dilutive'
        WHEN SUM(test_gm_per_opp    * control_opportunities)
          >= SUM(control_gm_per_opp * control_opportunities) * 1.05   THEN 'ADOPT'
        ELSE 'ADOPT - marginal'
    END                                                               AS recommendation
FROM bounded
GROUP BY GROUPING SETS ((contract_tier), ())
ORDER BY GROUPING(contract_tier), MIN(tier_rank);
