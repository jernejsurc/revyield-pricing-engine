-- =============================================================================
-- RevYield - B2B Pricing Elasticity & Revenue Optimization Engine
-- File:    data/schema.sql
-- Target:  PostgreSQL 15+ (developed against Neon Serverless Postgres, free tier)
-- Purpose: Star-schema DDL for pricing, usage and revenue analytics.
--
-- Run with:  psql "$DATABASE_URL" -f data/schema.sql
--        or: python data/seed_data.py --apply-schema --load
--
-- Design notes
--   * Money is numeric(14,2) - never float. Pricing analysis is settlement-grade.
--   * list_price / realized_price / unit_cost are ANNUALISED CONTRACT VALUES for
--     the full contracted volume (not per-seat). Per-seat economics are derived
--     by dividing by contracted_seats.
--   * Derived economics (discount %, gross margin, MRR) are GENERATED columns so
--     that Power BI, ad-hoc SQL and the automation layer can never disagree.
--   * Every table is dropped and rebuilt, so this file is safely re-runnable.
-- =============================================================================

BEGIN;

DROP TABLE IF EXISTS fact_transactions      CASCADE;
DROP TABLE IF EXISTS fact_usage_metrics     CASCADE;
DROP TABLE IF EXISTS dim_tier_entitlements  CASCADE;
DROP TABLE IF EXISTS dim_accounts           CASCADE;
DROP TABLE IF EXISTS dim_date               CASCADE;


-- =============================================================================
-- 1. dim_date - conformed date spine
--    Gives Power BI a single date dimension to hang every fact off, and gives
--    the cohort SQL a gap-free monthly grain (months with zero activity still
--    have to appear in an NRR series).
-- =============================================================================
CREATE TABLE dim_date (
    date_key        date        PRIMARY KEY,
    day_of_month    smallint    NOT NULL,
    month_number    smallint    NOT NULL,
    month_start     date        NOT NULL,
    month_end       date        NOT NULL,
    month_name      text        NOT NULL,
    quarter_number  smallint    NOT NULL,
    quarter_label   text        NOT NULL,
    year_number     smallint    NOT NULL,
    year_month      text        NOT NULL,   -- 'YYYY-MM', the natural cohort key
    is_month_end    boolean     NOT NULL
);

COMMENT ON TABLE  dim_date IS 'Conformed date dimension. Mark as the Power BI date table.';
COMMENT ON COLUMN dim_date.year_month IS 'YYYY-MM cohort key used by sql/03_cohort_retention.sql.';


-- =============================================================================
-- 2. dim_accounts - the customer master
-- =============================================================================
CREATE TABLE dim_accounts (
    account_id      integer     PRIMARY KEY,
    company_name    text        NOT NULL UNIQUE,
    industry        text        NOT NULL,
    region          text        NOT NULL,
    employee_count  integer     NOT NULL,
    signup_date     date        NOT NULL,
    current_tier    text        NOT NULL,
    account_status  text        NOT NULL DEFAULT 'active',
    churn_date      date,

    CONSTRAINT ck_accounts_employees   CHECK (employee_count > 0),
    CONSTRAINT ck_accounts_tier        CHECK (current_tier   IN ('Starter', 'Growth', 'Enterprise')),
    CONSTRAINT ck_accounts_status      CHECK (account_status IN ('active', 'churned')),
    -- A churned account must carry a churn date, and an active one must not.
    CONSTRAINT ck_accounts_churn_pair  CHECK ((account_status = 'churned') = (churn_date IS NOT NULL)),
    CONSTRAINT ck_accounts_churn_order CHECK (churn_date IS NULL OR churn_date >= signup_date)
);

CREATE INDEX ix_accounts_tier    ON dim_accounts (current_tier);
CREATE INDEX ix_accounts_signup  ON dim_accounts (signup_date);
CREATE INDEX ix_accounts_region  ON dim_accounts (region, industry);

COMMENT ON TABLE  dim_accounts IS 'Customer master. Grain: one row per account.';
COMMENT ON COLUMN dim_accounts.current_tier IS 'Tier of the most recent closed-won contract, not the tier at signup.';
COMMENT ON COLUMN dim_accounts.churn_date   IS 'Contract end date of the final non-renewed contract. NULL while retained.';


-- =============================================================================
-- 3. dim_tier_entitlements - the pricing rulebook, in-database
--    Seeded from data/pricing_rules.json. Phase 2 measures usage against these
--    contractual thresholds, so they cannot live only in application code.
-- =============================================================================
CREATE TABLE dim_tier_entitlements (
    contract_tier               text        PRIMARY KEY,
    tier_rank                   smallint    NOT NULL UNIQUE,
    annual_list_price_per_seat  numeric(12,2) NOT NULL,
    annual_cost_per_seat        numeric(12,2) NOT NULL,
    included_seats              integer     NOT NULL,
    included_api_calls          bigint      NOT NULL,
    included_storage_gb         numeric(12,2) NOT NULL,
    elasticity_coefficient      numeric(6,3) NOT NULL,
    test_list_uplift_pct        numeric(6,4) NOT NULL,
    capacity_threshold_pct      numeric(6,4) NOT NULL DEFAULT 0.85,
    target_gross_margin_pct     numeric(6,4) NOT NULL,

    CONSTRAINT ck_tier_name        CHECK (contract_tier IN ('Starter', 'Growth', 'Enterprise')),
    CONSTRAINT ck_tier_prices      CHECK (annual_list_price_per_seat > 0 AND annual_cost_per_seat >= 0),
    CONSTRAINT ck_tier_capacity    CHECK (capacity_threshold_pct > 0 AND capacity_threshold_pct <= 1),
    CONSTRAINT ck_tier_entitlement CHECK (included_seats > 0 AND included_api_calls > 0 AND included_storage_gb > 0)
);

COMMENT ON TABLE  dim_tier_entitlements IS 'Contractual capacity limits and unit economics per tier. Source of truth: data/pricing_rules.json.';
COMMENT ON COLUMN dim_tier_entitlements.elasticity_coefficient IS 'Prior elasticity estimate used to design the price test. sql/01 recovers the observed value empirically.';


-- =============================================================================
-- 4. fact_usage_metrics - monthly product consumption
--    Grain: one row per account per month.
-- =============================================================================
CREATE TABLE fact_usage_metrics (
    metric_id        bigserial   PRIMARY KEY,
    account_id       integer     NOT NULL REFERENCES dim_accounts (account_id) ON DELETE CASCADE,
    recorded_date    date        NOT NULL,
    active_seats     integer     NOT NULL,
    api_calls_count  bigint      NOT NULL,
    storage_gb       numeric(12,2) NOT NULL,

    CONSTRAINT ck_usage_nonneg CHECK (active_seats >= 0 AND api_calls_count >= 0 AND storage_gb >= 0),
    CONSTRAINT uq_usage_grain  UNIQUE (account_id, recorded_date)
);

CREATE INDEX ix_usage_account_date ON fact_usage_metrics (account_id, recorded_date DESC);
CREATE INDEX ix_usage_date         ON fact_usage_metrics (recorded_date);

COMMENT ON TABLE  fact_usage_metrics IS 'Month-end product consumption snapshot. Grain: account x month.';
COMMENT ON COLUMN fact_usage_metrics.recorded_date IS 'Month-end snapshot date. Snapshots stop at churn_date.';


-- =============================================================================
-- 5. fact_transactions - the deal ledger
--    Grain: one row per commercial deal (CRM opportunity).
-- =============================================================================
CREATE TABLE fact_transactions (
    transaction_id       bigserial     PRIMARY KEY,
    account_id           integer       NOT NULL REFERENCES dim_accounts (account_id) ON DELETE CASCADE,
    deal_id              text          NOT NULL UNIQUE,          -- HubSpot deal reference
    contract_tier        text          NOT NULL REFERENCES dim_tier_entitlements (contract_tier),
    deal_type            text          NOT NULL,
    deal_stage           text          NOT NULL,
    pricing_variant      text          NOT NULL,
    contracted_seats     integer       NOT NULL,
    list_price           numeric(14,2) NOT NULL,                 -- annualised, full contracted volume
    realized_price       numeric(14,2) NOT NULL,                 -- annualised, net of discount
    unit_cost            numeric(14,2) NOT NULL,                 -- annualised cost to serve
    win_probability      numeric(5,4)  NOT NULL,
    contract_term_months smallint      NOT NULL,
    contract_start_date  date,
    contract_end_date    date,
    close_date           date          NOT NULL,

    -- ---- Derived economics: computed once, consistent everywhere -------------
    discount_pct    numeric(9,6)  GENERATED ALWAYS AS
                        ((list_price - realized_price) / NULLIF(list_price, 0)) STORED,
    gross_margin    numeric(14,2) GENERATED ALWAYS AS
                        (realized_price - unit_cost) STORED,
    gross_margin_pct numeric(9,6) GENERATED ALWAYS AS
                        ((realized_price - unit_cost) / NULLIF(realized_price, 0)) STORED,
    realized_price_per_seat numeric(14,4) GENERATED ALWAYS AS
                        (realized_price / NULLIF(contracted_seats, 0)) STORED,
    list_price_per_seat numeric(14,4) GENERATED ALWAYS AS
                        (list_price / NULLIF(contracted_seats, 0)) STORED,
    mrr             numeric(14,2) GENERATED ALWAYS AS
                        (realized_price / 12) STORED,

    CONSTRAINT ck_txn_tier      CHECK (contract_tier   IN ('Starter', 'Growth', 'Enterprise')),
    CONSTRAINT ck_txn_type      CHECK (deal_type       IN ('new_business', 'expansion', 'renewal', 'upgrade')),
    CONSTRAINT ck_txn_stage     CHECK (deal_stage      IN ('closed_won', 'closed_lost', 'open')),
    -- 'not_in_test' is an explicit exclusion bucket, not missing data: renewals
    -- and mid-term upgrades were grandfathered onto the legacy price card.
    CONSTRAINT ck_txn_variant   CHECK (pricing_variant IN ('control', 'test', 'not_in_test')),
    CONSTRAINT ck_txn_seats     CHECK (contracted_seats > 0),
    CONSTRAINT ck_txn_prices    CHECK (list_price > 0 AND realized_price > 0 AND unit_cost >= 0),
    CONSTRAINT ck_txn_discount  CHECK (realized_price <= list_price),
    CONSTRAINT ck_txn_prob      CHECK (win_probability >= 0 AND win_probability <= 1),
    -- Base contracts run 12/24/36 months; mid-term expansions are sold
    -- co-terminus with the parent contract and therefore have odd terms.
    CONSTRAINT ck_txn_term      CHECK (contract_term_months BETWEEN 1 AND 60),
    -- Won deals must carry a contract window; lost and open deals must not.
    CONSTRAINT ck_txn_contract  CHECK (
        (deal_stage = 'closed_won' AND contract_start_date IS NOT NULL AND contract_end_date IS NOT NULL)
        OR
        (deal_stage <> 'closed_won' AND contract_start_date IS NULL AND contract_end_date IS NULL)
    ),
    CONSTRAINT ck_txn_window    CHECK (contract_end_date IS NULL OR contract_end_date > contract_start_date),
    -- A closed deal is settled: probability is exactly 1 or 0.
    CONSTRAINT ck_txn_prob_settled CHECK (
        (deal_stage = 'closed_won'  AND win_probability = 1)
        OR (deal_stage = 'closed_lost' AND win_probability = 0)
        OR (deal_stage = 'open')
    )
);

CREATE INDEX ix_txn_account        ON fact_transactions (account_id);
CREATE INDEX ix_txn_close_date     ON fact_transactions (close_date);
CREATE INDEX ix_txn_experiment     ON fact_transactions (contract_tier, pricing_variant, close_date)
                                   WHERE pricing_variant IN ('control', 'test');
CREATE INDEX ix_txn_contract_span  ON fact_transactions (contract_start_date, contract_end_date)
                                   WHERE deal_stage = 'closed_won';
CREATE INDEX ix_txn_open_pipeline  ON fact_transactions (close_date, win_probability)
                                   WHERE deal_stage = 'open';

COMMENT ON TABLE  fact_transactions IS 'Deal ledger. Grain: one row per CRM opportunity (won, lost or open).';
COMMENT ON COLUMN fact_transactions.list_price      IS 'Annualised list value of the full contracted volume, before discount.';
COMMENT ON COLUMN fact_transactions.realized_price  IS 'Annualised contract value actually booked, net of discount. This is ACV.';
COMMENT ON COLUMN fact_transactions.unit_cost       IS 'Annualised fully-loaded cost to serve the contracted volume.';
COMMENT ON COLUMN fact_transactions.pricing_variant IS 'A/B assignment: control = legacy price card, test = FY26-H1 uplift, not_in_test = excluded (grandfathered).';
COMMENT ON COLUMN fact_transactions.win_probability IS 'CRM-stage probability. Forced to 1/0 once closed; genuine forecast weight only while open.';
COMMENT ON COLUMN fact_transactions.mrr             IS 'Monthly recurring revenue contribution = realized_price / 12.';


-- =============================================================================
-- 6. Reference data - populate the date spine
--    generate_series keeps this declarative; no seed script involvement needed.
-- =============================================================================
INSERT INTO dim_date (
    date_key, day_of_month, month_number, month_start, month_end, month_name,
    quarter_number, quarter_label, year_number, year_month, is_month_end
)
SELECT
    d::date                                                        AS date_key,
    EXTRACT(DAY     FROM d)::smallint                              AS day_of_month,
    EXTRACT(MONTH   FROM d)::smallint                              AS month_number,
    DATE_TRUNC('month', d)::date                                   AS month_start,
    (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date    AS month_end,
    TO_CHAR(d, 'Mon')                                              AS month_name,
    EXTRACT(QUARTER FROM d)::smallint                              AS quarter_number,
    TO_CHAR(d, '"Q"Q YYYY')                                        AS quarter_label,
    EXTRACT(YEAR    FROM d)::smallint                              AS year_number,
    TO_CHAR(d, 'YYYY-MM')                                          AS year_month,
    d::date = (DATE_TRUNC('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::date AS is_month_end
FROM generate_series(DATE '2024-01-01', DATE '2027-12-31', INTERVAL '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Post-install sanity check (safe to run any time):
--
--   SELECT 'dim_date' AS t, COUNT(*) FROM dim_date
--   UNION ALL SELECT 'dim_accounts',          COUNT(*) FROM dim_accounts
--   UNION ALL SELECT 'dim_tier_entitlements', COUNT(*) FROM dim_tier_entitlements
--   UNION ALL SELECT 'fact_usage_metrics',    COUNT(*) FROM fact_usage_metrics
--   UNION ALL SELECT 'fact_transactions',     COUNT(*) FROM fact_transactions;
-- =============================================================================
