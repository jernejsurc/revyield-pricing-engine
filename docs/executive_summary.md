# FY26-H1 Price Card Test — Commercial Briefing

**To:** VP Revenue · CFO · Head of Product Marketing
**From:** Pricing Analytics
**Re:** Results of the FY26-H1 list uplift test, and the FY27 price card recommendation
**Status:** Decision required before the FY27 card is published

> Prepared on a simulated dataset for portfolio purposes. Method and reasoning are production-grade;
> the company and its customers are fictional.

---

## The decision in one line

**Take the uplift on Enterprise, take it on Growth with tighter discount governance, and leave
Starter alone.** A blanket increase looks like +9.4% margin. It is not — the whole gain is
Enterprise, and the Starter arm of the same test destroyed value.

---

## What we ran

From 1 January 2026 we raised list prices and tightened discount approval on a randomly assigned
half of new-business and expansion deals. Assignment was **matched-pair at account level** — twins
sharing tier, cohort month and baseline seat count, one to each arm — so no customer ever saw two
price cards. Renewals were grandfathered onto the legacy card and excluded.

Six months, **321 control against 324 test opportunities**, ~€6.6m of booked ACV in scope.

## What happened

| | Realized price/seat | Contracted volume | Gross margin per opportunity |
|---|---|---|---|
| **Starter** | €226.65 → €242.65 · **+7.1%** | **−12.7%** | €2,101 → €2,049 · **−2.4%** |
| **Growth** | €136.54 → €145.93 · **+6.9%** | −5.9% | €8,175 → €8,480 · **+3.7%** |
| **Enterprise** | €106.10 → €119.78 · **+12.9%** | −3.9% | €36,765 → €41,577 · **+13.1%** |

Three tiers, three different demand curves.

**Enterprise barely noticed.** A 12.9% realized increase cost 3.9% of volume. Procurement cycles,
integration depth and switching costs blunt price sensitivity, and the tier absorbed the largest
increase we tested while expanding margin 13.1%.

**Starter walked.** A 7.1% increase cost 12.7% of contracted volume — and because cost to serve does
not fall when a customer leaves, margin per opportunity went *backwards*. We paid 12.7% of our SMB
volume for a 2.4% margin loss.

**Growth sits between them,** and its gain came as much from discount governance as from list price.

## Why the blended number is a trap

The portfolio reads **+9.4% gross margin per opportunity**. Enterprise generates effectively all of
it. Reported as a single number, a blanket increase would look like a clear win while quietly
shrinking the SMB base that feeds tomorrow's Growth and Enterprise cohorts. Starter volume is not
just revenue — it is the top of the expansion funnel, and our own NRR of 99.7% depends on it.

## Recommendation

| Tier | FY27 action | Rationale |
|---|---|---|
| **Enterprise** | Adopt the full uplift | +13.1% margin, no detectable volume loss |
| **Growth** | Adopt, lead with discount governance | +3.7%; the discipline, not the list price, did the work |
| **Starter** | Hold the legacy card | Elastic; the increase costs volume and returns nothing |

Beyond the card, **238 accounts are consuming more seats than they contracted — €881,640 of
unbilled overage already in the base.** The top priority band is 25% of those accounts and 84% of
the money. That is a faster, lower-risk margin gain than any list-price move, and it requires no
customer to accept a price rise.

## What would change our minds

**Sample size is the honest limitation.** At ~130 opportunities per arm, only the Starter volume
response is statistically significant (95% CI on elasticity [−3.11, −0.34]). Growth [−2.05, 0.44]
and Enterprise [−1.26, 0.79] both include zero.

This does not undermine the margin findings — realized price is measured precisely and margin is
observed rather than inferred. It does mean the **elasticity coefficients are directional**. The
defensible claim is "Enterprise did not detectably lose volume at +12.9% while margin rose 13.1%",
not "Enterprise elasticity is −0.30".

Two further caveats worth naming:

- The test ran six months. Price increases can produce delayed churn that shows up at renewal, not
  at signature. Starter's true elasticity may be **worse** than measured.
- Win rates were equal across arms by design, so this test measures the effect on *order size*, not
  on close rates. A card change that also affects win rate needs a separate read.

## Next steps

1. **Publish the differentiated FY27 card** — Enterprise +12%, Growth +6%, Starter unchanged.
2. **Work the overage list** — 60 P1 accounts, €740,520, ahead of any card change.
3. **Extend the Enterprise arm two more quarters** to tighten the interval and catch renewal-cycle churn.
4. **Instrument win rate explicitly** so the next test separates order-size and close-rate effects.

---

*Method and full result set: [`sql/01_price_elasticity.sql`](../sql/01_price_elasticity.sql).
Every figure reproduces from `python data/seed_data.py --dry-run --summary`.*
