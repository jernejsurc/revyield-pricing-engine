# Lessons

Engineering patterns from building RevYield, kept so they are not relearned. Most were paid for by
a defect that reached a document or a database before it was caught.

---

## Credentials

**Say "replace the entire `DATABASE_URL=` line", never "update the password".**
Swapping only the secret leaves the old hostname in place, and the hostname *is* the project
identifier. The result is a valid-looking connection string pointing at the wrong database — which
fails silently, because it still connects. Any instruction about a connection string must name every
component being replaced.

**Name the exact file, and say which one is tracked.** `.gitignore` carries `!.env.example` so the
template is published, which makes it the worst possible place for a live secret. `.env` and
`.env.example` differ by one word and one is world-readable; never refer to "the env file".

**Move secrets programmatically, never by retyping.** If a credential lands in the wrong file,
relocate it with a script that reads and rewrites in place. Retyping it copies it somewhere new.

**Prefer deleting a resource over rotating its credential.** Deleting a cloud project retires its
password permanently and leaves nothing to forget. Rotation leaves a live target behind.

**Scan staged content, not the working tree, before the first commit.** `git diff --cached` is what
is actually about to be published. The pre-commit scan covered eight credential shapes plus an
explicit `git ls-files --error-unmatch .env` check.

---

## Verifying external state

**A connection probe cannot prove a cloud resource was deleted.** Neon returns
`password authentication failed` for endpoints that do not exist — anti-enumeration behaviour. This
was only caught by running the same probe against a *known-live* endpoint and getting a byte-identical
error. Any "is it gone?" heuristic needs a positive control before its output means anything.
For deletion, the console is authoritative.

**Always run the control.** The bug above was a wrong answer delivered with confidence, which is
worse than no answer. If a test distinguishes A from B, verify it actually produces different output
for A and B before trusting either verdict.

---

## Verification generally

**Execute everything executable.** Parse-checking is not running. Every real defect this build found
came from execution:

| Found by | Defect |
|---|---|
| Running the generator | Deal-mix bias inverted the Starter elasticity, +0.11 against a true −1.65 |
| Inspecting loaded data | `active_seats` derived from tier ceiling, not contracted seats — accounts at 4.5× |
| Running `sql/03` | Liveness tested at month *start*, inflating retention to 1603% |
| Reading query output | `cumulative_acv_opportunity` non-monotonic — window `ORDER BY` ≠ output `ORDER BY` |
| Arithmetic on own claims | Automation budget was ~1,270 ops against a 1,000 cap, not the 766 asserted |

**Two independent implementations beat one careful one.** `sql/01` was checked against a separate
Python estimator on 33 metrics; Active MRR against three derivations. Agreement across
implementations catches what re-reading never will.

**Recompute stated numbers from their own inputs.** The operations budget was wrong in a file that
also contained every input needed to falsify it. Any document asserting a derived figure should have
that figure recomputed by a script.

**Where the engine cannot be run, verify semantics instead.** No headless DAX engine exists, so every
measure's meaning was re-implemented in SQL and given an expected value, plus a structural lint
resolving column references against live `information_schema`. Say plainly what remains unverified —
DAX *syntax* still needs Power BI Desktop.

---

## Analysis

**Post-stratify before comparing groups.** New-business deals are several times larger than expansion
add-ons; a chance mix imbalance between arms flipped the sign of a headline elasticity. Combine
strata with control-arm exposure weights.

**Report the falsification check next to the result.** Win rates were held equal by construction, so
a win-rate gap near zero is evidence the pipeline works. A result with no way to be wrong is not a
result.

**State confidence intervals when they change the conclusion.** Only one of three tiers had a
statistically significant volume response. The margin findings survive because margin is *observed*;
the elasticities are directional. Publishing the point estimates alone would not have survived the
first competent question.

**Never price something the rate card does not sell.** Accounts breaching API or storage pools are
surfaced with the binding constraint named and no revenue estimate, because `pricing_rules.json`
sells seats only. Inventing an overage rate would have put an indefensible number in front of a
reader.
