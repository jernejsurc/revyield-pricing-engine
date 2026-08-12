# How RevYield works — the plain-English version

No SQL knowledge needed. If you want the technical detail, the
[README](../README.md) has it.

---

## 1 · The problem

A software company sells its product on a subscription, in three packages —
**Starter** (small businesses), **Growth** (mid-size), and **Enterprise** (large
corporations).

Management wants to raise prices. The obvious worry: *raise them too far and
customers leave.* The obvious question nobody can answer without evidence:
**how far is too far, and is it the same answer for all three packages?**

Guessing is expensive in both directions. Price too low and you leave money on
the table forever. Price too high and you lose customers who took years to win.

## 2 · How you find out for real

You run an experiment, the same way a website tests two versions of a page.

Split the customers randomly into two groups:

- **Group A (control)** — keeps the old prices
- **Group B (test)** — gets the new, higher prices

Wait six months. Then compare. Because the two groups were split at random, any
difference between them is caused by the price change and not by something else.

That is exactly what this project does — with one addition that makes it
unusual, explained in section 4.

## 3 · What's in the box

Five pieces, in the order data moves through them.

| # | Piece | What it does, plainly |
|---|---|---|
| 1 | **The database** | A structured store for customers, what they bought, and how much they use the product. Think of it as a very disciplined set of spreadsheets that refuse to accept nonsense. |
| 2 | **The data generator** | Invents a realistic company: 1,400 customers, 2,559 deals, two and a half years of history. |
| 3 | **Three analyses** | Answer three business questions — did the price rise work, who should we upsell, are we keeping our revenue. |
| 4 | **The automation** | A blueprint for connecting the sales CRM so this runs by itself instead of someone re-doing it monthly. |
| 5 | **The dashboard layer** | 66 pre-built calculations so Power BI can show all of this visually. |

## 4 · Why the data is invented — and why that's the point

The customers are not real. That sounds like a weakness. It is actually the
strongest thing about the project.

When you analyse **real** data, nobody knows the true answer. If your analysis
says "customers are quite price-sensitive," there is no way to check whether
that is right — you just have to trust it.

Here, the fake customers were built with a **known** price sensitivity baked in.
So the analysis can be **marked like an exam**:

| Package | True answer, built into the data | What the analysis found |
|---|---|---|
| Starter | −1.65 | **−1.80** |
| Growth | −0.95 | **−0.86** |
| Enterprise | −0.35 | **−0.30** |

Close on all three. That is evidence the method works — evidence real data can
never give you.

*(Those numbers are "price elasticity." −1.65 means: raise the price 1%, lose
1.65% of sales volume. Anything past −1 means the price rise loses you money.
Closer to zero means customers barely notice.)*

## 5 · What it found

**The finding that matters:** a price rise across the whole customer base looks
like a **9.4% improvement in profit**. That number is misleading, and seeing why
is the entire point.

Split by package, the picture is completely different:

| Package | Price went up | Customers bought | Profit effect | Verdict |
|---|---|---|---|---|
| **Starter** | +7% | **13% less** | **−2.4%** 🔴 | Don't do it |
| **Growth** | +7% | 6% less | +3.7% 🟡 | Worth doing |
| **Enterprise** | +13% | 4% less | **+13.1%** 🟢 | Definitely do it |

**Enterprise barely flinched.** A 13% price rise cost only 4% of volume. Large
companies have the software wired into their operations — switching is a project,
not a decision.

**Small businesses walked.** A 7% rise cost 13% of their volume. And because it
costs the same to serve a customer whether they stay or go, profit went
*backwards*. You lose customers *and* make less money.

**So the honest recommendation is: raise prices on large customers, leave small
ones alone.** A single company-wide number would have said "yes, raise
everything," and quietly shrunk the small-customer base that feeds future growth.

### Two other things it found

- **€881,640 of revenue is already being given away.** 238 customers use more
  seats than they pay for. That is money on the table needing no price rise at all
  — just a conversation.
- **Revenue retention is 99.7%.** For every €100 of subscriptions a year ago,
  there is €99.70 today. Losses from cancellations are almost exactly offset by
  existing customers buying more.

## 6 · The honest caveat

Six months is not long, and each group held only 67–132 deals depending on the
package — Enterprise, the one with the best result, had the fewest.

The profit findings are solid — money in and money out were both measured
directly. But the *price sensitivity numbers* for Growth and Enterprise are not
precise enough to state as fact. The correct phrasing is:

> "Enterprise showed no measurable drop in volume at +13%, and profit rose 13.1%."

Not:

> "Enterprise price elasticity is −0.30."

The difference matters. The first survives a sharp follow-up question; the
second doesn't. That caveat is written into the README and the executive summary
rather than buried, because a result you can poke holes in yourself is worth more
than one you can't.

## 7 · Where to look

| If you want to see… | Open |
|---|---|
| The short business version | [`docs/executive_summary.md`](executive_summary.md) — a one-page briefing to a CFO |
| The full technical write-up | [`README.md`](../README.md) |
| The price experiment itself | [`sql/01_price_elasticity.sql`](../sql/01_price_elasticity.sql) — the comments explain the reasoning |
| How the fake company was built | [`data/seed_data.py`](../data/seed_data.py) |
| The pricing rules | [`data/pricing_rules.json`](../data/pricing_rules.json) — plain text, readable without code |

You can run the whole thing without a database or a password:

```bash
python data/seed_data.py --dry-run --summary
```

That prints the results table, including the "true answer vs found answer"
comparison from section 4.

## 8 · Glossary

| Term | Plain meaning |
|---|---|
| **ACV** | Annual Contract Value — what a customer pays per year |
| **MRR** | Monthly Recurring Revenue — total subscription income per month |
| **Gross margin** | Revenue minus the cost of serving the customer. What's actually left. |
| **Price elasticity** | How much sales volume drops when price goes up. Past −1, the rise costs more than it earns. |
| **NRR** | Net Revenue Retention — is last year's customer base worth more or less today? Over 100% means existing customers grew. |
| **Churn** | A customer leaving |
| **Expansion** | An existing customer buying more |
| **Seat** | One user licence. Most B2B software is priced per seat. |
| **Control / test group** | The two halves of the experiment — old prices vs new prices |
| **Tier** | A pricing package (Starter, Growth, Enterprise) |
| **Pipeline** | Deals being negotiated but not yet won |

---

*The data is simulated. The company and its customers are fictional. The methods
are the ones you would use on real data.*
