# Making the RevYield report clear, usable and good-looking

Picks up after the four pages exist and `power_bi/revyield_theme.json` is applied.
Roughly 50 minutes, in six parts. Each part stands alone — stop after any of them
and the report is better than when you started.

**The test this guide is aiming at:** someone who has never seen the report opens
page 2 and understands the finding within five seconds, without asking you a
single question.

---

## What the theme already did

Don't redo these by hand:

| Already handled | |
|---|---|
| Colour palette | One accent blue, green/red reserved for good and bad |
| Fonts | Segoe UI throughout, consistent sizes |
| Cards | 30pt semibold value, grey label, **display units None** |
| Bar/column charts | Value axis off, gridlines off, data labels on |
| Line charts | 3px stroke, markers on, dotted gridlines |
| Tables/matrix | Dark header, banded rows, subtotals off |
| Every visual | White fill, 8px rounded corners, soft shadow, hairline border |
| Page canvas | `#F4F6F8`, so white cards read as raised |

What a theme **cannot** touch is everything below: what things are called, how
they are arranged, how the reader moves around, and what the report explains
about itself.

---

# Part A · Correctness first

Styling on top of wrong numbers is wasted work. Six fixes, five minutes.

| # | Fix | How |
|---|---|---|
| A1 | Industry slicer → **Dropdown** | Select it → chevron **⌄** top-right → Dropdown. Long labels cannot render as tiles — that is why it looked empty |
| A2 | Delete the report-level `month_end` filter | Filters pane → *Filters on all pages* → hover → **✕**. It was blanking Weighted Pipeline Forecast, because open deals close after June 2026 |
| A3 | Expansion table → `dim_accounts[current_tier]` | Remove `dim_tier_entitlements[contract_tier]`, drag in `current_tier`. Stops every upgraded account appearing twice |
| A4 | Expansion table → **Totals: Off** | Format → Totals. A summed-percentage total is meaningless |
| A5 | Price Test matrix → **Row subtotals: Off** | Format → Row subtotals. Pools three price cards into a nonsense average |
| A6 | Price Test matrix → sort by tier | Click the **contract_tier** header until it reads Starter → Growth → Enterprise |

> A2 is safe to delete now. `Active MRR` returns blank for months after the data
> ends, so the line chart stops on its own — the filter is doing nothing except
> hiding your pipeline.

---

# Part B · Make it read as one product

### B1 · A header bar on every page

1. **Insert → Shapes → Rectangle**. Stretch across the top, about 60px tall
2. **Format shape → Style → Fill** `#1A4D6D`, **Border** off
3. **Insert → Text box** on top, white, size 18, bold — the page title
4. Second text box beside it, white at 70% transparency, size 10 — the subtitle

| Page | Title | Subtitle |
|---|---|---|
| 1 | RevYield · Executive Overview | Booked performance, recurring revenue and open pipeline |
| 2 | RevYield · FY26-H1 Price Test | Did the price rise work, and for whom? |
| 3 | RevYield · Expansion Pipeline | Accounts consuming more than they contracted |
| 4 | RevYield · Retention | What the existing customer base did |

Build it once on page 1, select all three objects, `Ctrl+C`, then `Ctrl+V` on
each other page and edit the text. Identical placement is the point.

### B2 · Retitle every visual

Power BI names visuals after their fields. A field list is not a title.

**Where the setting lives:**

1. Click the visual once so its selection handles appear
2. **Visualizations** pane → the **paint-roller icon** 🖌️ (*"Format your visual"*),
   under the grid of chart types
3. Two sub-tabs appear — **Visual** and **General**. Click **General**
4. Expand **Title**
5. Type into the **Text** field

> **The Text box will look empty**, even though a title is plainly showing on the
> visual. Power BI auto-generates one from the field names whenever the box is
> blank, so there is nothing to find and edit — just type over the emptiness and
> it overrides permanently.
>
> Font, size and colour sit in the same section, but the theme already sets them.
> Only **Text** needs touching.

Replace as follows:

| Auto-generated | Use instead |
|---|---|
| Booked ACV by contract_tier | Where the revenue is |
| Realized Unit Margin % by contract_tier | Margin improves with tier size |
| Active MRR by month_end | Recurring revenue |
| Booked ACV by region | Revenue by region |
| Control GM per Opportunity and Test GM per Opportunity by contract_tier | **Test arm beats control everywhere except Starter** |
| Expansion ACV Opportunity by region | Where the unbilled seats are |
| Active MRR and Active Customers by month_end | Customers and revenue both compounding |
| New MRR, Expansion MRR and Churned MRR by month_end | MRR movement, month by month |

The bolded one carries the whole report. A title that states the finding means
the reader gets it even if they never study the bars.

### B3 · Give the page a focal point

Right now every card on page 1 is the same size, so nothing leads. Make
**Booked ACV** and **Realized Unit Margin %** about 1.4× the others and put them
first. On a pricing dashboard, revenue and margin are the headline; pipeline and
retention are support.

Same on page 2: the matrix is the star. Give it the full width of the page and
put everything else underneath it.

---

# Part C · Make it navigable

This is the part that separates "four disconnected tabs" from something that
feels like an application.

### C1 · A navigation bar

**Insert → Buttons → Navigator → Page navigator.**

Power BI generates a button per page automatically and keeps it in sync if you
rename or add pages. Place it inside the header bar on the right.

Then style it: **Format → Style → State: Selected** → fill white, text `#1A4D6D`.
**State: Default** → fill transparent, text white. Now the current page is
obvious at a glance.

Copy it to all four pages in the same position.

### C2 · Sync the slicers

Right now filtering by region on page 1 does nothing to pages 2–4, which will
confuse anyone who tries it.

1. **View → Sync slicers** (opens a pane)
2. Select the region slicer
3. Tick **Sync** for all four pages; tick **Visible** only for page 1

Repeat for industry and tier. Filters now follow the reader around, but the
slicers themselves only take up space on page 1.

### C3 · A reset button

Once people start filtering, they need a way back.

1. Clear all slicers so the report is in its default state
2. **View → Bookmarks → Add**, rename it `Reset`
3. On the bookmark's **…** menu, make sure **Data** is ticked and **Display** is unticked
4. **Insert → Buttons → Reset**, place it in the header bar
5. **Format → Action → On**, Type **Bookmark**, Bookmark `Reset`

### C4 · Control what filters what

By default every visual cross-filters every other one, which produces surprising
results — clicking a region bar silently changes your price-test matrix.

Select the region bar chart → **Format ribbon → Edit interactions**. Icons appear
on every other visual. Set the cards to **None** (a filtered KPI headline is
misleading) and leave the charts on **Filter**.

On page 2, set the matrix to **None** from everything. It is the result of a
controlled experiment; nobody should be able to slice it by accident.

---

# Part D · Make the report explain itself

### D1 · Conditional formatting that carries the argument

**Page 2 matrix** — select it → **Format → Cell elements**.

Choose series `Price Test Margin Uplift %` → **Background colour → On → fx**:
- Format style **Rules**
- If value `< 0` → `#FADBD8` (pale red)
- If value `>= 0` → `#D5F5E3` (pale green)

Choose series `Price Elasticity` → **Font colour → On → fx**:
- If value `< -1` → `#C0392B`
- If value `>= -1` → `#2E8B57`

Starter turns red, the other two green. The recommendation becomes visible
without a sentence of explanation — this is the single highest-value five
minutes in the whole guide.

**Page 3 table** — `Seat Utilisation %` → **Data bars → On**, positive bar
`#D4A017`. A reader scans bar lengths far faster than numbers.

### D2 · Richer tooltips

Hovering should answer the obvious follow-up question.

Select the "Where the revenue is" chart → in the **Visualizations** pane find the
**Tooltips** well → drag in `Deals Won`, `Realized Price per Seat`, `Discount %`.

Hovering a tier bar now shows revenue *plus* how many deals, at what price, at
what discount. Same idea on page 3: add `current_acv` and `next_renewal_date`.

### D3 · Explain the two things nobody will guess

**Page 2**, under the matrix — **Insert → Text box**, background `#FEF9E7`,
border `#D4A017`:

> **Read with care.** Only the Starter volume response is statistically
> significant (95% CI −3.11 to −0.34). Growth and Enterprise intervals include
> zero, and Enterprise — which carries the strongest recommendation — has the
> smallest sample. Margin findings are robust: realised price is measured
> directly. Elasticity figures are directional.

**Page 2**, beside the win-rate card — small grey text, size 9:

> Win rates were held equal across both arms by design. A gap near zero confirms
> the experiment ran cleanly.

That second one turns a boring number into evidence of rigour. Most people
delete the card because it "looks like nothing"; the note is why it stays.

### D4 · A footer

Page 1, bottom, grey, size 9:

> Simulated data, generated from a known demand model so the analysis can be
> validated against ground truth · github.com/jernejsurc/revyield-pricing-engine

Pre-empts the first question anyone asks, and puts the repository in front of
whoever is looking at the screen.

---

# Part E · Accessibility

Quick, and it is the kind of thing an interviewer notices because almost nobody
does it.

**E1 · Alt text.** Select each visual → **Format → General → Alt text** → one
sentence describing what it shows. Screen readers use it; so does anyone who
exports the report.

**E2 · Tab order.** **View → Selection pane → Tab order** tab. Drag so the header
comes first, then KPI cards, then charts. Send decorative shapes to the bottom
and mark them **hidden in tab order**.

**E3 · Don't rely on colour alone.** Red/green is roughly 8% of men to some
degree. The matrix already carries the numbers alongside the colour, so it is
fine — but if you add a chart where colour is the only signal, add a label too.

**E4 · Check contrast.** The theme's `#34495E` on white and white on `#1A4D6D`
both clear WCAG AA. If you introduce new colours, keep them at 4.5:1 or better
against their background.

---

# Part F · Alignment, then ship

Sloppy alignment is the most common tell in portfolio dashboards, and it is
entirely mechanical.

1. **View → Show gridlines** and **Snap to grid**, both on
2. `Ctrl+click` a row of visuals → **Format ribbon → Align → Align top**
3. Same selection → **Distribute horizontally**

Rules that work on the default 1280×720 canvas:

- 20px outer margin on all four sides
- 16px between visuals, consistently
- Cards in one row, equal height
- Charts on a 2-column grid, equal widths
- Nothing overlapping, nothing touching an edge

### Final checklist

- [ ] No visual titled with a field list
- [ ] Every page has the same header bar and navigator, in the same place
- [ ] Slicers sync across pages; only visible on page 1
- [ ] Reset button works
- [ ] Cards do not get cross-filtered by chart clicks
- [ ] Page 2 matrix cannot be filtered by anything
- [ ] Elasticity and uplift are colour-coded
- [ ] The caveat box is on page 2
- [ ] Alt text on every visual
- [ ] Nothing overlaps; nothing touches the edge
- [ ] Slicers reset to All before screenshots

Then **View → Page view → Fit to page**, and capture pages 1 and 2 into
`power_bi/screenshots/` as `overview.png` and `price-test.png`.

---

## What a reviewer actually notices

Roughly in order of impact:

1. **Titles that state findings** rather than field names
2. **Conditional formatting that makes the argument visible** without reading
3. **Consistent colour with meaning** — one accent, red and green reserved
4. **Navigation that works** — it feels like a product, not four exports
5. **Alignment and whitespace** — the fastest signal of care
6. **Precision** — `43,679,459`, not `44M`
7. **The caveat box** — nothing reads as senior like flagging your own limits

Conspicuously absent: chart variety. Six charts of two types, styled identically,
beat a donut, a gauge, a treemap and a funnel every time. Reach for a new chart
type only when the shape of the data demands it — not to fill space.
