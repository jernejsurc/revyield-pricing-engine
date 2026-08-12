# Making the RevYield report look professional

Follow after the four pages exist. Roughly 45 minutes, and it is the difference
between "someone learning Power BI" and "someone who has shipped dashboards".

The default Power BI look is not neutral — it actively reads as unfinished. Grey
gridlines, auto-generated titles like *"Control GM per Opportunity and Test GM
per Opportunity by contract_tier"*, and a bright multi-colour palette all say the
same thing: nobody made a decision here.

---

## Step 0 · Fix these first, before any styling

Cosmetics on top of wrong numbers is wasted effort.

| Fix | Where |
|---|---|
| Industry slicer → **Dropdown** | Long labels cannot render as tiles |
| Delete the report-level `month_end` filter | It blanks Weighted Pipeline Forecast |
| Expansion table → `dim_accounts[current_tier]` | Stops every account appearing twice |
| Expansion table → **Totals: Off** | A summed-percentage total is meaningless |
| Price Test matrix → **Row subtotals: Off** | Pools three price cards into a nonsense average |
| Price Test matrix → sort by `contract_tier` | Click the column header, not a value column |

---

## Step 1 · One theme, one accent colour

**View → Themes → Customize current theme.**

Set these under **Name and colours → Theme colours**:

| Slot | Hex | Used for |
|---|---|---|
| Colour 1 | `#1A4D6D` | Deep blue — the default for everything |
| Colour 2 | `#2E8B57` | Green — positive / test arm |
| Colour 3 | `#C0392B` | Red — negative / warnings |
| Colour 4 | `#7F8C8D` | Grey — context and secondary series |
| Colour 5 | `#D4A017` | Amber — "needs attention" |
| Colour 6 | `#34495E` | Slate |

Then **Text → General**: font **Segoe UI**, size **10**.
**Text → Title**: size **14**, colour `#1A4D6D`, bold.

> **Why one accent instead of a rainbow.** Colour should carry meaning. If
> everything is coloured, nothing is emphasised. Deep blue is the default; green
> and red are reserved for good and bad. A reader learns that in about four
> seconds and then reads the whole report faster.

---

## Step 2 · Page backgrounds and a title bar

For each page: click empty canvas → **Format → Canvas background** → colour
`#F4F6F8`, transparency **0%**.

Then give each page a header:

1. **Insert → Shapes → Rectangle**, stretch across the top, ~60px tall
2. Fill `#1A4D6D`, no border
3. **Insert → Text box** on top of it, white text, size 18, bold

| Page | Title | Subtitle (size 10, white, 70% opacity) |
|---|---|---|
| 1 | RevYield · Executive Overview | Booked performance, recurring revenue and open pipeline |
| 2 | RevYield · FY26-H1 Price Test | Did the price rise work, and for whom? |
| 3 | RevYield · Expansion Pipeline | Accounts consuming more than they contracted |
| 4 | RevYield · Retention | What the existing customer base did |

Consistent headers across four pages is the single cheapest thing that makes a
report look designed.

---

## Step 3 · Make the cards look like KPIs

Your cards currently sit on white with a thin border. Select each, then:

**Format → General → Effects**
- **Background**: white, 0% transparency
- **Visual border**: On, colour `#E1E5EA`, rounded corners **8**
- **Shadow**: On, preset *Outer → Bottom right*, 20% transparency

**Format → Callout value**
- Font size **32**, bold, colour `#1A4D6D`
- **Display units: None** for anything under 10 million — `43,679,459` is more
  credible than `44M`, and precision is the point on a pricing dashboard

**Format → Category label**
- Font size **11**, colour `#7F8C8D`

Do it once, then use the **format painter** (Home ribbon) to copy that styling to
every other card.

> **Set display units to None deliberately.** "44M" on a margin dashboard invites
> "44 million what, and rounded how?" Show the number.

---

## Step 4 · Kill the auto-generated titles

Power BI names visuals after their fields. *"Control GM per Opportunity and Test
GM per Opportunity by contract_tier"* is a field list, not a title.

Select each visual → **Format → General → Title** → write what the chart *means*:

| Auto-generated | Replace with |
|---|---|
| Booked ACV by contract_tier | Where the revenue is |
| Realized Unit Margin % by contract_tier | Margin improves with tier size |
| Active MRR by month_end | Recurring revenue |
| Booked ACV by region | Revenue by region |
| Control GM per Opportunity and Test GM per Opportunity by contract_tier | **Test arm beats control everywhere except Starter** |
| Expansion ACV Opportunity by region | Where the unbilled seats are |
| New MRR, Expansion MRR and Churned MRR by month_end | MRR movement |

Title font: **12**, bold, `#1A4D6D`.

The bolded one matters most. A title that states the finding means the reader
gets it even if they never look at the bars.

---

## Step 5 · Strip the chart clutter

For every bar and column chart:

- **Y axis → Gridlines: Off**
- **Y axis → Title: Off** (the visual title already says it)
- **X axis → Title: Off**
- **Data labels: On**, size 9 — then **Y axis: Off** entirely

Labels on the bars beat an axis the reader has to trace across. One or the other,
never both.

For the two line charts:

- **Lines → Stroke width: 3**, **Shape → Smooth: Off** — smoothing invents data
  points between months that do not exist
- **Gridlines**: horizontal only, `#E1E5EA`, dotted
- **Markers: On** for the MRR line, so each month-end reading is a real point

---

## Step 6 · Colour that carries meaning

**Page 2, the control-vs-test chart.** This is the most important visual in the
report — set the colours by hand:

- `Control GM per Opportunity` → grey `#7F8C8D`
- `Test GM per Opportunity` → green `#2E8B57`

Then **conditional formatting on the Starter test bar is not possible per-column
in a clustered chart** — instead, add a text callout beside it:

> **Insert → Text box:** "Starter is the exception: the test arm earns *less* per
> opportunity."

**Page 2, the matrix.** Select it → **Format → Cell elements**:

- Series `Price Test Margin Uplift %` → **Background colour → On** → **Rules**:
  - if value `< 0` → `#FADBD8` (pale red)
  - if value `>= 0` → `#D5F5E3` (pale green)
- Series `Price Elasticity` → **Font colour → Rules**:
  - `< -1` → `#C0392B` (elastic — a price rise loses money)
  - `>= -1` → `#2E8B57` (inelastic — a price rise earns)

That single rule turns the matrix into the argument: Starter red, the others
green, no explanation needed.

**Page 3, the target list.** Series `Seat Utilisation %` → **Data bars → On**,
positive bar `#D4A017`.

---

## Step 7 · Alignment

Sloppy alignment is what most portfolio dashboards get wrong, and it is entirely
mechanical to fix.

1. Select several visuals with `Ctrl+click`
2. **Format** ribbon → **Align** → *Align top* / *Align left*
3. **Distribute horizontally** to even the gaps

Rules that work on a 1280×720 canvas:

- Cards in one row, equal width, 16px gaps
- Charts in a 2-column grid, equal widths
- Slicers together along one edge — never scattered
- Nothing overlapping, nothing touching the canvas edge
- 20px outer margin on all four sides

**View → Show gridlines** and **Snap to grid** make this almost automatic.

---

## Step 8 · The caveat text box

On page 2, below the matrix. **Insert → Text box**, background `#FEF9E7`, border
`#D4A017`:

> **Read with care.** Only the Starter volume response is statistically
> significant (95% CI −3.11 to −0.34). Growth and Enterprise intervals include
> zero, and Enterprise — which carries the strongest recommendation — has the
> smallest sample. Margin findings are robust: realised price is measured
> directly. Elasticity figures are directional.

And a footer on page 1, grey, size 9:

> Simulated data, generated from a known demand model so the analysis can be
> validated against ground truth. github.com/jernejsurc/revyield-pricing-engine

---

## Step 9 · Final pass

Walk all four pages and check:

- [ ] No visual titled with a field list
- [ ] No axis titled with a column name
- [ ] Every card uses display units **None**
- [ ] Tiers read Starter → Growth → Enterprise everywhere
- [ ] No total row that sums percentages
- [ ] Every page has the same header bar
- [ ] Nothing overlaps; nothing touches the edge
- [ ] Slicers reset to "All" before screenshots
- [ ] The green/red usage is consistent on every page

Then **View → Page view → Fit to page**, and screenshot pages 1 and 2 into
`power_bi/screenshots/`.

---

## What a reviewer actually notices

In rough order of impact:

1. **Consistent colour with meaning** — one accent, red and green reserved
2. **Titles that state findings**, not field names
3. **Alignment** — the fastest tell of care
4. **Whitespace** — cramped dashboards read as anxious
5. **Precision** — `43,679,459`, not `44M`
6. **The caveat box** — nothing signals seniority like flagging your own limits

Notably absent: chart variety. Four bar charts and two line charts, all styled
identically, beat a donut, a gauge, a treemap and a funnel. Reach for a new chart
type only when the shape of the data demands it.
