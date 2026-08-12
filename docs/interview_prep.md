# Interview Positioning — RevYield

Talking points for Pricing Analyst · Revenue Analyst · Commercial Analyst · RevOps roles.

---

## 30-second elevator pitch

> "RevYield answers the question I used to get asked at Digital Charging Solutions: *we want to
> raise prices — which segments can absorb it?*
>
> It's a full pricing stack on free-tier infrastructure — a Postgres warehouse, a generator with a
> known demand curve built in, SQL that has to recover it, and a Power BI layer on top.
>
> The finding is the interesting part. A blanket increase reads +9.4% gross margin. But the entire
> gain is Enterprise — on SMB the same uplift costs 13% of contracted volume and moves margin
> backwards. The whole point is that a blended number hides that, and a tier-level read finds it."

*~85 words. Land on the last sentence — it is the one that says you think like a pricing analyst
rather than a report builder.*

**One-line version for a recruiter screen:**
"A B2B SaaS pricing engine that runs a real A/B price test end to end and shows why a single
portfolio margin number is the wrong thing to look at."

---

## Four resume bullets

Place under **Projects**. Each is metric-led and survives a follow-up question.

**1.** Built an end-to-end pricing analytics engine (Neon PostgreSQL, Python/`psycopg` v3, 67 DAX
measures in Power BI) evaluating an A/B list-price test across three SaaS tiers; recovered demand
elasticities from **−1.80 to −0.30** and produced a differentiated price card worth **+13.1% gross
margin on Enterprise** while identifying a **−2.4% margin loss** from the same uplift on SMB.

**2.** Designed the experiment to withstand scrutiny — matched-pair randomisation on tier, cohort
month and deal size; post-stratification on deal type, which corrected a deal-mix bias severe enough
to **invert the measured SMB elasticity from +0.11 to −1.80**; plus a win-rate falsification check
and 95% confidence intervals via the delta method.

**3.** Authored modular PostgreSQL analytics (CTEs, window functions, `GROUPING SETS`, `FILTER`)
producing an Expansion Readiness Index that surfaced **€881,640 of unbilled seat overage across 238
accounts**, with **84% of the value concentrated in the top-ranked quartile**.

**4.** Specified a Make.com automation contract (HubSpot → margin calculation → Google Sheets +
Neon) with idempotent upserts and database-enforced integrity; re-architected duplicate suppression
from an N+1 into a single batched call, cutting the workload from **~1,270 to 766 operations/month**
to fit the free tier.

**Optional fifth**, if the role leans BI: Modelled a Power BI star schema with 67 production DAX
measures, including point-in-time MRR via the events-in-progress pattern, cohort-based NRR/GRR, and
a weighted pipeline forecast — catching a stage-filter omission that would have overstated the
forecast by a factor of 42.

---

## The bridge to your actual experience

The project is deliberately a mirror of the DCS role. Say so — it is the strongest thing you have.

| On the CV | In RevYield |
|---|---|
| "Led A/B testing for rate-structure changes, achieving a pricing uplift and €55K incremental revenue" | The FY26-H1 price test, with the statistics done properly |
| "Identified €200K in annual revenue leakage" | €881,640 of unbilled seat overage from the Expansion Readiness Index |
| "Built dynamic revenue dashboards in Power BI (Snowflake SQL) for C-level" | 67 DAX measures on a Postgres star schema |
| "Developed segment-specific pricing models using demand signals and price elasticity" | Tier-level elasticity with confidence intervals |

**How to frame it:** *"I've done this work with real revenue at DCS. What I couldn't show from that
role was the code, because it belongs to them. So I rebuilt the method end to end on synthetic data
where the ground truth is known — which means you can actually check whether the analysis is right."*

---

## Questions you will get

**"Isn't this just fake data?"**
Yes, and deliberately. The generator implements an explicit demand model, `Q_test = Q_control ×
(1 + E × %ΔP)`, so there is a known right answer. The SQL is graded on whether it recovers it —
design −1.65/−0.95/−0.35 against recovered −1.80/−0.86/−0.30. You cannot do that with real data,
because with real data nobody knows the true elasticity.

**"Your confidence intervals include zero on two of three tiers. So what have you actually shown?"**
The right question, and it is in the README rather than buried. Margin is *observed*, not inferred —
realized price is measured precisely, so +13.1% on Enterprise stands. The elasticity coefficients are
directional. The defensible claim is "Enterprise did not detectably lose volume at +12.9% while
margin rose 13.1%", not "Enterprise elasticity is −0.30". I would extend the arm two more quarters
before publishing a coefficient.

**"Walk me through a bug you found."**
Pick the deal-mix one — it is the best story. New-business deals are several times larger than
expansion add-ons. A chance imbalance in mix between arms was large enough to flip the Starter
elasticity to **+0.11**, i.e. the data appeared to say customers buy *more* when you raise prices.
Post-stratifying on deal type and recombining with control-arm exposure weights fixed it. It only
surfaced because the generator has a known ground truth to check against.

**"How do you know the numbers are right?"**
Every artefact was executed. `sql/01` reproduces an independent Python implementation on 33/33
metrics. Active MRR agrees across three derivations to €1. The whole thing was then run against Neon
**PostgreSQL 17.10** and the local **PostgreSQL 16.2** with identical output.

**"Why free-tier tools?"**
Constraints force real decisions. Make's 1,000 ops/month cap exposed an N+1 in my duplicate
suppression that would have silently stalled both scenarios mid-month. HubSpot's free tier has no
webhooks, so the trigger is a poll — documented as a limitation rather than hidden.

---

## What to have open when screen-sharing

1. `README.md` — the headline table
2. `sql/01_price_elasticity.sql` — the post-stratification comment block
3. `docs/executive_summary.md` — proof you can write for a CFO, not just a console
4. Terminal running `python data/seed_data.py --dry-run --summary` — observed against design, live
