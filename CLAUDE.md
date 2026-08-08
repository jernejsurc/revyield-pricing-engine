# CLAUDE.md — RevYield

Build and maintenance guide for **RevYield: B2B Pricing Elasticity & Revenue Optimization Engine**.

## What this project is

A commercial analytics engine for a fictional European B2B SaaS company, built end-to-end on
free-tier infrastructure. It answers one question a pricing team is actually paid to answer:

> **We want to raise prices. Which tiers can absorb it, and what does it do to gross margin?**

The repository ships the whole chain: schema → simulated-but-coherent data → SQL analytics →
automation contract → Power BI semantic layer → recruiter-facing documentation.

**Portfolio target:** Pricing Analyst, Revenue Analyst, Commercial Analyst, RevOps/GTM Data Analyst.

## Stack

| Layer | Tool | Notes |
|---|---|---|
| Warehouse | Neon Serverless PostgreSQL (free tier) | SSL required |
| Ingestion | Python 3.11+ / `psycopg` **v3** | `COPY` for bulk load |
| Analytics | PostgreSQL 15+ SQL | CTEs, window functions, `FILTER`, `generate_series` |
| Automation | Make.com (free tier) + HubSpot free CRM + Google Sheets | spec only, no secrets |
| BI | Power BI Desktop | DAX measures, star schema |
| Docs | Markdown + Mermaid | rendered natively by GitHub |

## Commands

```bash
# Inspect the generated economics without touching a database (no credentials needed)
python data/seed_data.py --dry-run --summary
```

```bash
# Build schema and load Neon in one shot
python data/seed_data.py --apply-schema --load --summary
```

```bash
# Schema only, via psql
psql "$DATABASE_URL" -f data/schema.sql
```

```bash
# Export flat files for Power BI / Google Sheets without a database
python data/seed_data.py --dry-run --csv-out ./exports
```

```bash
# Run the analytics
psql "$DATABASE_URL" -f sql/01_price_elasticity.sql
```

### Verifying without Neon

The SQL is a work sample, so it must be *run*, not just eyeballed. Two local options, neither of
which needs credentials:

```bash
# Grammar check against the real PostgreSQL parser (libpg_query)
pip install pglast && python -c "import pglast,glob; [pglast.parse_sql(open(f,encoding='utf-8').read()) for f in glob.glob('sql/*.sql')]"
```

```bash
# Full execution against a throwaway PostgreSQL 16
pip install pgserver
python -c "import pgserver; print(pgserver.get_server('/tmp/revyield-pg', cleanup_mode=None).get_uri())"
python data/seed_data.py --apply-schema --load --database-url '<uri-from-above>?sslmode=disable'
```

`sslmode=disable` is required for the local server; `ensure_ssl()` leaves any DSN that already
names an `sslmode` untouched, so Neon behaviour is unaffected.

Connection string resolution order: `--database-url` → `$DATABASE_URL` → `.env`.
Neon rejects non-SSL connections; `sslmode=require` is appended automatically if absent.

```
DATABASE_URL=postgresql://user:pw@ep-xxx.eu-central-1.aws.neon.tech/revyield?sslmode=require
```

## Repository layout

```
├── CLAUDE.md                       this file
├── README.md                       recruiter-facing pitch, architecture, findings
├── data/
│   ├── pricing_rules.json          tier economics, entitlements, experiment design
│   ├── schema.sql                  PostgreSQL DDL — constraints, generated columns, indexes
│   └── seed_data.py                deterministic generator + psycopg v3 COPY loader
├── sql/
│   ├── 01_price_elasticity.sql     A/B evaluation, E = %ΔQ / %ΔP, margin uplift
│   ├── 02_tier_expansion.sql       Expansion Readiness Index
│   └── 03_cohort_retention.sql     MRR movement and NRR by cohort
├── automation/
│   └── make_scenario_spec.json     HubSpot → margin calc → Google Sheets + Neon
├── power_bi/
│   └── measures.dax                production DAX measures
├── docs/
│   └── executive_summary.md        one-page commercial briefing
└── tasks/
    └── todo.md                     build plan and design decisions
```

## Data model

Star schema. `dim_date` is the conformed date dimension; mark it as the date table in Power BI.

```
dim_date ──┐
           ├─< fact_usage_metrics >── dim_accounts
dim_tier_entitlements ─< fact_transactions >──┘
```

### `dim_accounts` — customer master, one row per account
`account_id` · `company_name` · `industry` · `region` · `employee_count` · `signup_date` ·
`current_tier` · `account_status` · `churn_date`

`current_tier` reflects the most recent closed-won contract, **not** the tier at signup — accounts
migrate up through `upgrade` deals.

### `dim_tier_entitlements` — the pricing rulebook, in-database
`contract_tier` · `tier_rank` · `annual_list_price_per_seat` · `annual_cost_per_seat` ·
`included_seats` · `included_api_calls` · `included_storage_gb` · `elasticity_coefficient` ·
`test_list_uplift_pct` · `capacity_threshold_pct` · `target_gross_margin_pct`

Seeded from `data/pricing_rules.json`. Phase 2 measures usage against these contractual
thresholds, so they cannot live only in application code.

### `fact_usage_metrics` — month-end consumption, one row per account × month
`metric_id` · `account_id` · `recorded_date` · `active_seats` · `api_calls_count` · `storage_gb`

Snapshots stop at `churn_date`. Values above entitlement are legitimate — over-capacity is the
expansion signal Phase 2 hunts for.

**Seats and platform quotas are metered against different denominators, and this is deliberate.**
`active_seats` is generated from, and must be compared against, the seats the account actually
**contracted**; `api_calls_count` and `storage_gb` are compared against the tier's included pools
in `dim_tier_entitlements`. "You are paying for 240 seats and using 310" is a commercial
conversation. "You are below the Enterprise seat cap" is not. An earlier version generated
`active_seats` from the tier's seat ceiling instead, which produced accounts consuming 4.5× the
seats they had bought and made `sql/02` indefensible. `included_seats` still does real work: it is
the tier ceiling whose breach routes an account to an *upgrade* rather than a seat top-up.

### `fact_transactions` — deal ledger, one row per CRM opportunity
`transaction_id` · `account_id` · `deal_id` · `contract_tier` · `deal_type` · `deal_stage` ·
`pricing_variant` · `contracted_seats` · `list_price` · `realized_price` · `unit_cost` ·
`win_probability` · `contract_term_months` · `contract_start_date` · `contract_end_date` · `close_date`

Generated columns (computed once in the database, so BI and ad-hoc SQL can never disagree):
`discount_pct` · `gross_margin` · `gross_margin_pct` · `realized_price_per_seat` ·
`list_price_per_seat` · `mrr`

## Conventions that must not be broken

**Money is `numeric`, never `float`.** Pricing analysis is settlement-grade.

**`list_price`, `realized_price` and `unit_cost` are annualised values for the full contracted
volume** — not per-seat, not total-contract-value. `realized_price` *is* ACV. Per-seat economics
come from dividing by `contracted_seats`; `mrr` is `realized_price / 12`.

**Derived economics live in generated columns**, not in each query. If a new derived measure is
needed in more than one place, add it to the DDL.

**`deal_stage` drives nullability.** Won deals carry a contract window and `win_probability = 1`;
lost deals carry no window and `win_probability = 0`; only open deals carry a genuine forecast
weight. Enforced by `ck_txn_contract` and `ck_txn_prob_settled`.

**`pricing_variant = 'not_in_test'` is an explicit exclusion bucket, not missing data.** Renewals
and mid-term upgrades were grandfathered onto the legacy price card. Every elasticity query must
filter `pricing_variant IN ('control','test')`.

**Never commit credentials.** `.env` is git-ignored. `automation/make_scenario_spec.json` uses
placeholder connection IDs only.

## The experiment, and why the analysis is shaped the way it is

`data/pricing_rules.json` defines a FY26-H1 price test: a list uplift plus tighter discount
governance, rolled out to a random half of the book. The generator implements an explicit demand
model, `Q_test = Q_control × (1 + E × %ΔP)`, so **the data has a known ground truth and the SQL is
graded on whether it recovers it.** `--summary` prints observed against design side by side.

Two design choices in the generator exist because the naive version produced wrong answers, and
both have direct analytical consequences:

1. **Post-stratification on `deal_type` is mandatory.** New-business deals are several times
   larger than expansion add-ons. A chance imbalance in deal mix between the arms biases a naive
   tier-level average badly enough to *invert the sign* of the Starter elasticity (measured at
   +0.11 against a true −1.65 before this was fixed). Strata are combined with control-arm
   exposure weights. Any new elasticity query must do the same.

2. **Assignment is matched-pair, not simple 50/50.** Twins share tier, cohort month and baseline
   seat count, with one twin per arm. Simple randomisation left residual noise of the same order
   as the effect being measured.

The modelled demand response acts on **contracted volume, not win rate**. Win rates are held equal
across arms and dealt from an exact quota, so a win-rate gap between arms is a red flag that
something in the pipeline is wrong — `sql/01` reports it as a falsification check.

## Working agreements

- **Determinism is a feature.** The generator is seeded; `--seed 42` at 1,400 accounts is the
  canonical dataset. Every figure quoted in `README.md` and `docs/executive_summary.md` must be
  reproducible from `python data/seed_data.py --dry-run --summary`. Never hand-write a headline
  number that the tooling does not produce.
- **Simulated data, stated plainly.** The dataset is synthetic and the documentation says so.
  Do not present findings as real customer outcomes.
- **SQL is modular and standalone.** Each file in `sql/` runs independently against a seeded
  database, opens with a comment block stating its question, method and output grain, and returns
  a result set rather than creating objects.
- **Prefer window functions and CTEs over procedural workarounds.** The SQL is a work sample.
- Regenerating the dataset changes every number downstream. Re-run `--summary` and update the
  documentation in the same commit.
