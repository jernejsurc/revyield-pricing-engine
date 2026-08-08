# RevYield — Build Plan

## Phase 1 — Database architecture & data generation
- [x] Confirm repo structure + toolchain (Python 3.11.9, psycopg 3.3.4)
- [x] `CLAUDE.md` — project spec, env commands, data dictionary, conventions
- [x] `data/pricing_rules.json` — single source of truth for tier economics, entitlements, elasticity coefficients, experiment design
- [x] `data/schema.sql` — PostgreSQL DDL (constraints, generated columns, indexes, comments)
- [x] `data/seed_data.py` — deterministic generator + psycopg v3 COPY loader
- [x] Verify generator offline (`--dry-run --summary`) so README claims are data-backed
- [x] Verify schema + loader end-to-end against a real PostgreSQL 16 (embedded `pgserver`)
- [x] Fix seat metering — `active_seats` now derives from contracted seats, not the tier ceiling
- [x] Load to Neon — done; all three queries return identical results on Neon PG 17.10 and local PG 16.2

## Phase 2 — Advanced SQL analytics
- [x] `sql/01_price_elasticity.sql` — A/B evaluation, E = %ΔQ / %ΔP, margin uplift, sample sizes
- [x] `sql/02_tier_expansion.sql` — Expansion Readiness Index (NTILE, LAG, capacity thresholds)
- [x] `sql/03_cohort_retention.sql` — MRR expansion/contraction, NRR by signup cohort
- [x] All three executed against real PostgreSQL 16 and validated

## Phase 3 — Automation
- [x] `automation/make_scenario_spec.json` — HubSpot → margin calc → Google Sheets + Neon
- [x] Both embedded SQL blocks executed against real PostgreSQL 16
- [x] Upsert proven idempotent; generated columns proven to recompute
- [x] Operations budget recomputed from its own inputs (766 / 1,000)

## Phase 4 — Power BI
- [x] `power_bi/measures.dax` — 66 measures: realized margin, elasticity uplift, NRR, weighted pipeline
- [x] Structural lint against the live warehouse schema (8 checks)
- [x] Every measure's semantics re-implemented in SQL and given a verified expected value
- [ ] Paste into Power BI Desktop and confirm the DAX compiles (needs the desktop app)

## Phase 5 — Documentation & positioning
- [x] `README.md` — badges, Mermaid architecture + ER diagram, findings, quick start, verification
- [x] `docs/executive_summary.md` — one-page commercial briefing
- [x] `docs/interview_prep.md` — 30-second pitch, 4 resume bullets, likely questions
- [x] `LICENSE` (MIT) — the README badge now points at something real
- [x] All 36 documented figures re-derived from Neon; no credential in any shipped file
- [ ] `README.md` — badges, Mermaid architecture, findings, quick start
- [ ] `docs/executive_summary.md` — 1-page commercial briefing
- [ ] Elevator pitch + 4 resume bullets

---

## Design decisions (Phase 1)

**Schema extensions beyond the brief** — each one is load-bearing, not decoration:

| Addition | Why it is required |
|---|---|
| `fact_transactions.win_probability`, `deal_stage` | Phase 4 DAX `Weighted Pipeline Forecast` references `win_probability`; a forecast needs open pipeline. |
| `fact_transactions.contracted_seats` | Price elasticity needs a **quantity** unit. Deal counts are a poor proxy (unequal exposure); contracted seats give a textbook `E = %ΔQ / %ΔP`. |
| `fact_transactions.contract_start_date`, `contract_term_months`, `contract_end_date` | Phase 3 NRR requires a monthly MRR series; it is derived from contract windows via `generate_series` rather than a 4th fact table. |
| `dim_tier_entitlements` | Phase 2 compares usage against *contract thresholds*. Those thresholds must live in the database, seeded from `pricing_rules.json`. |
| `dim_date` | Star-schema date spine for Power BI relationships and gap-free monthly cohorts. |
| `dim_accounts.region`, `account_status`, `churn_date` | NRR needs churn; `region` is the primary Power BI slicer for the European narrative. |

**Experiment design** — `pricing_variant ∈ ('control', 'test', 'not_in_test')`. Accounts are randomly assigned 50/50, stratified by tier. Only new-business and expansion deals closing in the test window enter the experiment; renewals are grandfathered on the legacy price card and flagged `not_in_test`. That exclusion is deliberate experiment hygiene, not missing data.

**Determinism** — the generator is seeded (`--seed 42`). Every number quoted in the README is reproducible and printed by `python data/seed_data.py --dry-run --summary`.

---

## Design decisions (Phase 2)

**Three bugs found by executing the SQL, not by reading it.** Each would have shipped a wrong
number to a hiring manager:

| Bug | Symptom | Fix |
|---|---|---|
| `active_seats` generated from the tier's seat ceiling, independent of what the account bought | accounts using 4.5× their contracted seats; the expansion query had no defensible denominator | usage now derives from contracted seats; ratios fall to 0.05–2.12× |
| `sql/03` tested contract liveness at month **start** | every account signing after the 1st was invisible in its own cohort month, inflating retention to 1603% | liveness evaluated at month end, matching how usage is snapshotted |
| `sql/02` running total ordered differently from the output | `cumulative_acv_opportunity` went 126,720 → 101,040 | window `ORDER BY` aligned with the final `ORDER BY` |

**Only seat overage carries a revenue estimate.** `pricing_rules.json` sells seats and nothing
else. Accounts breaching an API or storage pool are surfaced with `binding_constraint` named and
`expansion_acv_opportunity = 0` rather than sized against an overage rate that does not exist.

**Confidence intervals are reported because they change the story.** At n≈130 per arm only the
Starter volume response clears zero (95% CI [−3.11, −0.34]). Growth [−2.05, 0.44] and Enterprise
[−1.26, 0.79] do not. The *margin* verdict still holds — realized price is measured precisely —
but the elasticity point estimates must not be quoted as settled facts.

---

## Design decisions (Phase 3)

**It is a specification, not a Make.com blueprint export.** A real export embeds account-scoped
connection IDs and module UUIDs. Publishing one either leaks credentials or ships a file that
fails to import. Every connection is a `{{CONN_*}}` placeholder.

**Free-tier constraints drove the architecture, and one of them nearly broke it.** Make allows
1,000 operations/month. The natural implementation of duplicate suppression — search HubSpot once
per candidate account — is an N+1: 25 operations per run, ~550/month, which with Scenario 1 put
the total at ~1,270 and would have silently stalled both scenarios mid-month. Fetching the open-deal
set in **one** call and matching in memory costs 1 operation instead of 25. Final budget **766/1,000**,
recomputed from its own stated inputs rather than asserted.

**HubSpot free tier has no webhooks and no workflows** — those need a public developer app or
Operations Hub. The trigger is therefore a poll against the CRM Search API on `hs_lastmodifieddate`,
which a free private app can do. Stated plainly in `known_limitations` rather than glossed.

**The database constraints are the integration contract.** Rather than validating in Make and
hoping, the pipeline maps `dealstage` deliberately and lets Postgres reject anything malformed into
the error branch. `ck_txn_prob_settled` forces `win_probability` to exactly 1/0 on closed deals;
`ck_txn_contract` forces contract dates to be present only on won deals.

**No generated column appears in any INSERT.** `discount_pct`, `gross_margin`, `gross_margin_pct`,
`realized_price_per_seat`, `list_price_per_seat` and `mrr` are recomputed by Postgres — which is
why Make's arithmetic cannot drift from Power BI's. Verified by test, not by inspection.

**Only seat overage gets a revenue estimate**, consistent with `sql/02`. The rate card sells seats
and nothing else.

---

## Design decisions (Phase 4)

**Both example measures in the brief were unsafe against this model, for the same reason.**
`fact_transactions` is a deal *ledger* — 1,993 won, 283 lost, 283 open — so unfiltered aggregation
counts revenue that was never booked:

| Measure | Unfiltered | Correct | Error |
|---|---|---|---|
| `Realized Unit Margin %` inputs | ACV €48,580,713 | €43,679,459 | +11.2% |
| `Weighted Pipeline Forecast` | €44,752,349 | €1,072,890 | **42×** |

The forecast case is the severe one: `ck_txn_prob_settled` forces `win_probability = 1` on won
deals, so an unfiltered `SUMX(price × probability)` returns every euro ever booked *plus* the
pipeline. Every money/seat measure now filters `deal_stage`; a lint check enforces it transitively.

**`Price Elasticity Uplift` as specified (test revenue − control revenue) is not a valid read.**
The arms don't carry equal exposure (321 vs 324 opportunities, and far wider once a slicer is
applied), so a raw difference mixes the price effect with an accident of assignment. Implemented as
revenue-per-opportunity re-inflated on control exposure, which answers what the price card would
have earned on the same book.

**Post-stratification had to reach the semantic layer too.** `% Price Change` and `% Quantity
Change` were stratified but the GM-per-opportunity measures weren't — which would have put Power BI
at odds with `sql/01`. The control side needs no stratification (it collapses algebraically, since
the weights *are* control exposure); the test side does. Fixed, with the algebra documented inline.

**Two "helper measures" returning tables were invalid DAX** — a measure must return a scalar.
`_Experiment Strata` and `_Prior Year Customer Base` are inlined as `VAR`s instead; a calculated
table would have been evaluated once at refresh and gone blind to slicers.

**`dim_tier_entitlements` is deliberately not related to `dim_accounts`** — relating it to both that
and `fact_transactions[contract_tier]` creates two paths to the fact table and Power BI rejects the
model as ambiguous. Entitlements reach `dim_accounts` via `LOOKUPVALUE` calculated columns instead.

**Known gap:** DAX *syntax* is unverified. There is no headless DAX engine here, so compilation
needs a paste into Power BI Desktop. What is verified is every measure's semantics and expected value.

### Verification performed

- `sql/01` reproduces the Python estimator on **33/33 metrics** across all tiers and the portfolio row.
- `sql/03` MRR movement identity (`starting + new + expansion − contraction − churn = ending`)
  holds on **all 465 rows**; latest-month MRR agrees across three independent derivations
  (cohort rollup 2,921,776 · ledger 2,921,775 · Python 2,921,775).
- All 30 schema constraints re-validated after the generator change.
- Phase 3: 18 spec checks pass — JSON validity, no credential-shaped strings, all 4 SQL blocks
  parse and execute, `field_mapping` covers exactly the writable columns of `fact_transactions`
  with zero generated-column leakage, sweep query returns a true subset of `sql/02` (105 ⊂ 238),
  upsert replayed three times inserts exactly one row, and a stale `open` replay cannot reopen a
  closed-won deal. Test rows rolled back.
- Phase 4: 8 lint checks pass — all 20 distinct `table[column]` references resolve against the live
  `information_schema`, every `[Measure]` reference is defined, brackets balance in all 66 measures,
  no measure returns a table, every money/seat measure filters `deal_stage` transitively, and the
  pipeline measures scope to open deals. Expected values recorded in section 08 of `measures.dax`;
  the A/B block reproduces `sql/01` exactly and Active MRR agrees with `sql/03` to €1.
