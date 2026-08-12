# Building the RevYield report in Power BI — step by step

Assumes no prior Power BI knowledge. Every click is spelled out. Roughly 75 minutes.

Keep this open in a browser beside Power BI Desktop and work down it.

---

## Before you start

**You need:**

- Power BI Desktop (already installed)
- The Neon database, already loaded — `python data/seed_data.py --dry-run --summary` reproduces the
  numbers if you ever need to check
- Your connection details, from `.env` in the repo root

**Orientation.** Down the far left of Power BI Desktop are three small icons. You will move between
them constantly:

| Icon | Name | What it's for |
|---|---|---|
| 📊 chart | **Report** view | Building pages and visuals |
| ▦ grid | **Table** view | Looking at the raw rows |
| 🔗 diagram | **Model** view | Joining tables together |

Two panes sit on the right in Report view: **Visualizations** (the chart type picker) and **Data**
(your tables and fields). If either is missing, drag the right-hand edge of the window wider.

---

# Part 1 · Connect to the database

### 1.1 Start the connection

**Home** ribbon → **Get data** → **More…** → in the left list choose **Database** → **PostgreSQL
database** → **Connect**.

### 1.2 Fill in the server

| Field | Value |
|---|---|
| **Server** | `ep-bitter-wind-b1cvibg7.c-5.eu-central-1.aws.neon.tech:5432` |
| **Database** | `neondb` |

Expand **Advanced options** only if you want to check them — leave everything blank.

Under **Data Connectivity mode**, choose **Import**.

> **Why Import and not DirectQuery?** Import copies the data into the file once. DirectQuery queries
> the database live on every click. This dataset is small (~21,000 rows) and Neon puts its compute
> to sleep when idle, so DirectQuery would wake it constantly and feel broken. Import is the right
> answer here and it is not close.

Click **OK**.

### 1.3 Enter credentials

A dialog appears with tabs down the left. Choose the **Database** tab (not Windows).

| Field | Value |
|---|---|
| **User name** | `neondb_owner` |
| **Password** | the password from your `.env` file |

Click **Connect**.

> **Where is the password?** Open `.env` in the repo root. The line looks like
> `DATABASE_URL=postgresql://neondb_owner:PASSWORD@ep-...`. The password is the part between the
> colon after `neondb_owner` and the `@`.

### 1.4 If you get an encryption error

You may see *"We were unable to connect because this combination of encryption and server settings
is not supported."*

Reopen the dialog and try the **Encryption** / **Encrypt connections** option in the other position.
Neon requires SSL, so encrypted should work — but Power BI occasionally negotiates it awkwardly and
needs to be told explicitly.

### 1.5 Choose the tables

The **Navigator** window opens with a list on the left. Tick exactly these five:

- `dim_accounts`
- `dim_date`
- `dim_tier_entitlements`
- `fact_transactions`
- `fact_usage_metrics`

Click any table name to preview it and confirm data is really coming through.

Click **Load** — *not* Transform Data. No cleaning is needed; the database already enforces it.

### 1.6 Wait

The status dialog counts rows. `fact_usage_metrics` is the big one at 16,985. A minute or two is
normal, longer if Neon was asleep.

**Checkpoint.** In the **Data** pane on the right you should now see five tables. Click the ▦
**Table** view icon and select `fact_transactions` — you should see 2,559 rows with columns like
`realized_price` and `gross_margin`.

---

# Part 2 · Build the model

This is the part beginners skip and then wonder why the numbers are wrong. It takes ten minutes.

### 2.1 Open Model view

Click the 🔗 **Model** icon on the far left. You'll see the five tables as boxes with lines between
some of them. Power BI guessed at relationships when it loaded, and **its guesses are usually wrong**.

### 2.2 Delete every existing relationship

For each line between tables: right-click it → **Delete** → confirm.

Keep going until there are no lines at all. Starting clean is faster than auditing guesses.

### 2.3 Create the five correct relationships

You create a relationship by **dragging a field from one table onto the matching field in another**.

Build these five, one at a time:

| # | Drag this | Onto this |
|---|---|---|
| 1 | `fact_transactions[account_id]` | `dim_accounts[account_id]` |
| 2 | `fact_transactions[contract_tier]` | `dim_tier_entitlements[contract_tier]` |
| 3 | `fact_transactions[close_date]` | `dim_date[date_key]` |
| 4 | `fact_usage_metrics[account_id]` | `dim_accounts[account_id]` |
| 5 | `fact_usage_metrics[recorded_date]` | `dim_date[date_key]` |

After each one, **double-click the new line** and confirm the dialog reads:

- **Cardinality:** Many to one (\*:1)
- **Cross filter direction:** Single
- **Make this relationship active:** ticked

Fix it if not, then **OK**.

> ### ⚠️ The one mistake that breaks everything
>
> **Do not create a relationship between `dim_accounts[current_tier]` and
> `dim_tier_entitlements[contract_tier]`.**
>
> It looks sensible — both hold tier names. But `dim_tier_entitlements` is already joined to
> `fact_transactions`, so adding this creates *two different routes* from tiers to the deal table.
> Power BI cannot decide which to use and will either refuse the relationship or silently produce
> wrong totals. Power BI's auto-detect loves suggesting exactly this one.
>
> Part 2.5 solves the same problem the safe way.

**Checkpoint.** Five lines, each with a `1` at the dimension end and a `*` at the fact end.

### 2.4 Mark the date table

Still in Model view, click the `dim_date` table to select it.

**Table tools** ribbon (appears at the top when a table is selected) → **Mark as date table** →
**Mark as date table** → in the dropdown choose **`date_key`** → **OK**.

> **Why this matters.** It tells Power BI "this is *the* calendar". Without it, anything involving
> time comparisons — such as retention measured against twelve months ago — silently misbehaves.

### 2.5 Add two calculated columns

These pull tier limits onto the account table, replacing the relationship you deliberately avoided.

In the **Data** pane, right-click `dim_accounts` → **New column**. A formula bar appears at the top.
Delete what's there, paste the first formula, press **Enter**:

```
Included API Calls = LOOKUPVALUE( dim_tier_entitlements[included_api_calls], dim_tier_entitlements[contract_tier], dim_accounts[current_tier] )
```

Repeat — right-click `dim_accounts` → **New column** — for the second:

```
Included Storage GB = LOOKUPVALUE( dim_tier_entitlements[included_storage_gb], dim_tier_entitlements[contract_tier], dim_accounts[current_tier] )
```

> **Note there is no "Included Seats" column, and that is deliberate.** Seats are measured against
> what each customer actually *bought*, not against the tier's ceiling. "You pay for 240 seats and
> use 310" is a sales conversation; "you're under the Enterprise cap" is not.

### 2.6 Make tiers sort correctly

By default Power BI sorts tiers alphabetically — Enterprise, Growth, Starter — which is meaningless.

Click the ▦ **Table** view → select `dim_tier_entitlements` → click the **`contract_tier`** column
heading → **Column tools** ribbon → **Sort by column** → choose **`tier_rank`**.

Now they order Starter → Growth → Enterprise everywhere.

---

# Part 3 · Add the measures

A **measure** is a saved calculation. There are 66 of them, already written in
`power_bi/measures.dax`.

## Option A — the fast way (recommended)

### 3.1 Install Tabular Editor 2

The free version is **Tabular Editor 2**. The winget id ends in `.2` — the `.3` package is the paid
product, don't install that.

```bash
winget install --id TabularEditor.TabularEditor.2 --scope user --silent --skip-dependencies --accept-source-agreements --accept-package-agreements
```

`--skip-dependencies` is required. Without it winget tries to install a .NET Framework 4.6.2
*developer pack* that is no longer published, and the whole install aborts. The 4.8 *runtime* ships
with Windows 11 and satisfies the real requirement — Tabular Editor runs fine.

**Then give yourself a way to launch it.** winget installs the *portable* build, which creates no
Start menu entry and no desktop icon — searching the Start menu for "Tabular" finds nothing. Run
this once to add a shortcut (no admin needed):

```powershell
$exe = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\TabularEditor.TabularEditor.2_Microsoft.Winget.Source_8wekyb3d8bbwe\TabularEditor.exe"
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tabular Editor 2.lnk")
$s.TargetPath = $exe; $s.WorkingDirectory = Split-Path $exe; $s.Save()
```

It will then appear as **Tabular Editor 2** in the Start menu. Alternatively, winget registered a
command alias, so typing `TabularEditor` in a **newly opened** terminal also launches it.

### 3.2 Open your model in Tabular Editor

The **External Tools** ribbon in Power BI needs a registration file written to
`C:\Program Files (x86)\...`, which requires administrator rights — and the Microsoft Store build of
Power BI Desktop doesn't create that folder at all. Skip it. Connecting directly works, needs no
admin, and takes thirty seconds.

**First, make sure your .pbix is open in Power BI Desktop with the data loaded.** Power BI runs a
private database engine behind the scenes while a file is open, and that is what you are connecting
to. Close Power BI and the connection dies.

**Find the port.** Power BI's engine runs as a process called `msmdsrv`. Ask it which port it is
listening on — in PowerShell:

```powershell
$m = Get-Process msmdsrv -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
if ($m) { Get-NetTCPConnection -OwningProcess $m.Id -State Listen | Sort-Object LocalPort | Select-Object -First 1 | ForEach-Object { "localhost:$($_.LocalPort)" } } else { "Power BI is not open with a model loaded" }
```

It prints something like `localhost:54790`. **The number changes every time Power BI restarts**, so
re-run this if you reconnect later.

> Many guides tell you to read `msmdsrv.port.txt` out of `%LOCALAPPDATA%`. That fails on the
> Microsoft Store build of Power BI, which keeps its workspace under
> `%USERPROFILE%\Microsoft\Power BI Desktop Store App\AnalysisServicesWorkspaces\` instead. Asking
> the process which port it holds works on every build.

> Prints "not open"? Power BI isn't running, or no file is loaded. Finish Part 1 first.

**Connect.** Launch Tabular Editor (Start menu shortcut from 3.1) → **File → Open → From DB…** →
paste `localhost:54790` (your number) into **Server** → leave authentication as Windows → **OK** →
the database appears in the dropdown, pick it → **OK**.

The model tree (Tables, Measures) appears on the left.

### 3.3 Run the script

In Tabular Editor, click the **Advanced Scripting** tab (bottom of the window, beside "Expression
Editor").

Open `power_bi/create_measures.csx` from the repo in Notepad, copy **everything**, paste into the
scripting area.

Press **F5**.

A message box appears. It must say:

```
parsed  : 66   (expected 66)
```

- **Says 66** → good. Close the box, press **Ctrl+S** to save back into Power BI, then close
  Tabular Editor.
- **Says anything else** → **do not save.** Close Tabular Editor without saving and use Option B.

> **Ctrl+S writes straight into the running Power BI model.** There is no undo. That is why the
> script refuses to look successful unless it parsed exactly 66.

### 3.4 Confirm

Back in Power BI Desktop, the **Data** pane should show measures under `fact_transactions` — a
calculator icon (▣) rather than a column icon — grouped into folders like `01 BASE` and
`02 A/B PRICE TEST`.

If they don't appear immediately, click any other table and back again to refresh the pane.

## Option B — by hand

Add just these 14. They drive every visual in this guide; the rest can wait.

`Booked ACV` · `Cost to Serve` · `Gross Margin` · `Realized Unit Margin %` · `Contracted Seats` ·
`Deals Won` · `Active MRR` · `Active Customers` · `Net Revenue Retention %` · `Open Pipeline ACV` ·
`Weighted Pipeline Forecast` · `Control GM per Opportunity` · `Test GM per Opportunity` ·
`Price Test Margin Uplift %`

For each one: **Home** ribbon → **New measure** → open `power_bi/measures.dax`, find the measure by
name, and copy the whole block including the name and `=` into the formula bar. Press **Enter**.

Copy them exactly. The `deal_stage` filters inside are what keep the numbers correct — the table
holds lost and in-progress deals alongside won ones.

---

# Part 4 · ✅ Verify before you build anything

**Do not skip this.** It is the only step that can genuinely fail, and finding out now beats finding
out after you've built four pages.

Click the 📊 **Report** view icon. On the blank page:

1. In the **Visualizations** pane, click the **Card** visual (a single large number, ▭ icon)
2. In the **Data** pane, expand `fact_transactions` and tick **`Booked ACV`**
3. Read the number

Repeat for each row below — click blank canvas first so you get a new card each time:

| Measure | Must show |
|---|---|
| `Booked ACV` | **43,679,459** |
| `Realized Unit Margin %` | **70.15%** |
| `Active MRR` | **2,921,775** |
| `Weighted Pipeline Forecast` | **1,072,890** |
| `Net Revenue Retention %` | **99.7%** |

Formatting may differ (43.68M, 70.15, 0.7015). It's the digits that matter.

**All five match** → the model and the measures are correct. Delete the cards and carry on.

**One or more don't** → stop. Note which, and how it differs. A wrong `Booked ACV` usually means a
missing `deal_stage` filter; a wrong `Active MRR` usually means the date table wasn't marked.

---

# Part 5 · Build the four pages

Tabs along the bottom are pages. The **+** adds one. Double-click a tab to rename it.

**How to make any visual:** click blank canvas → click a chart type in **Visualizations** → drag
fields from **Data** into the wells beneath (X-axis, Y-axis, Values…). Drag the visual's corners to
resize.

---

## Page 1 — "Executive Overview"

Rename the first page to `Executive Overview`.

### A row of five cards across the top

Five **Card** visuals, one measure each:

`Booked ACV` · `Realized Unit Margin %` · `Active MRR` · `Net Revenue Retention %` ·
`Weighted Pipeline Forecast`

For each: select it → **Format** pane (paint-roller icon) → **Callout value** → set text size ~28 →
under **General → Title**, turn it on and give it a plain name like "Booked ACV".

### Revenue by tier — Clustered column chart

| Well | Field |
|---|---|
| X-axis | `dim_tier_entitlements[contract_tier]` |
| Y-axis | `Booked ACV` |

### Margin by tier — Clustered column chart

| Well | Field |
|---|---|
| X-axis | `dim_tier_entitlements[contract_tier]` |
| Y-axis | `Realized Unit Margin %` |

### MRR over time — Line chart

| Well | Field |
|---|---|
| X-axis | **`dim_date[month_end]`** |
| Y-axis | `Active MRR` |

> **Use `month_end`, not `month_start`.** `Active MRR` asks "which contracts were running on the
> latest date in view?". With `month_start` that date is the 1st, so anything signed mid-month
> vanishes — exactly the bug that once made this project's retention read 1603%. `month_end` gives
> the correct month-end snapshot.

### Revenue by region — Stacked bar chart

| Well | Field |
|---|---|
| Y-axis | `dim_accounts[region]` |
| X-axis | `Booked ACV` |

### Three slicers along the bottom

Add three **Slicer** visuals with `dim_accounts[region]`, `dim_accounts[industry]`, and
`dim_tier_entitlements[contract_tier]`.

---

## Page 2 — "Price Test"

**This is the page that gets you hired.** Everything else is competent reporting; this is analysis.

### The results matrix

Add a **Matrix** visual.

| Well | Field |
|---|---|
| Rows | `dim_tier_entitlements[contract_tier]` |
| Values | `Control Opportunities`, `Test Opportunities`, `% Price Change`, `% Quantity Change`, `Price Elasticity`, `Control GM per Opportunity`, `Test GM per Opportunity`, `Price Test Margin Uplift %` |

> ### ⚠️ Turn the totals row off
>
> **Format** pane → **Row subtotals** → **Off**.
>
> Percent change and elasticity are per-tier measures. Pooled across tiers they average three
> different price cards into a number that means nothing. `sql/01` suppresses exactly these on its
> portfolio row for the same reason. Leaving the total visible is the kind of detail an interviewer
> will spot.

You should be reading:

| Tier | %ΔP | %ΔQ | Elasticity | Uplift |
|---|---|---|---|---|
| Starter | 7.1 | −12.7 | −1.80 | −2.4% |
| Growth | 6.9 | −5.9 | −0.86 | +3.7% |
| Enterprise | 12.9 | −3.9 | −0.30 | +13.1% |

### The verdict card

A **Card** visual with `Price Test Verdict`. It shows text, not a number — it reads the margin
outcome and returns ADOPT / REJECT.

### Control vs test — Clustered column chart

| Well | Field |
|---|---|
| X-axis | `dim_tier_entitlements[contract_tier]` |
| Y-axis | `Control GM per Opportunity`, `Test GM per Opportunity` |

Two bars per tier. Starter's test bar is visibly *shorter* — the whole finding in one picture.

### The falsification check

A **Card** with `Win Rate Gap (pp)`. Title it "Win-rate gap (must be ≈0)".

> **Why show a number that's supposed to be boring?** Win rates were held equal between the two
> groups by design. If this card showed something large, the experiment would be broken. Publishing
> the check beside the result says you tried to prove yourself wrong.

### A text box with the caveat

**Insert** ribbon → **Text box**. Paste:

> Only the Starter volume response is statistically significant (95% CI −3.11 to −0.34). Growth and
> Enterprise intervals include zero, and Enterprise — carrying the strongest recommendation — has
> the smallest sample. Margin findings are robust: realised price is measured directly. Elasticity
> figures are directional.

---

## Page 3 — "Expansion Pipeline"

### Two cards

`Accounts Over Capacity` and `Expansion ACV Opportunity`.

### The target list — Table visual

| Well | Field |
|---|---|
| Columns | `dim_accounts[company_name]`, `dim_accounts[region]`, `dim_tier_entitlements[contract_tier]`, `Seat Utilisation %`, `Seats Over Contract`, `Expansion ACV Opportunity` |

Then:

1. Click the **`Expansion ACV Opportunity`** column header twice to sort descending
2. **Filters** pane → drag `Expansion ACV Opportunity` into *Filters on this visual* → **Show items
   when the value** → **is greater than** → `0` → **Apply**
3. Select the visual → **Format** → **Cell elements** → Series `Seat Utilisation %` → **Data bars**
   → **On**

### By region — Stacked bar chart

| Well | Field |
|---|---|
| Y-axis | `dim_accounts[region]` |
| X-axis | `Expansion ACV Opportunity` |

---

## Page 4 — "Retention"

### Three cards

`Net Revenue Retention %`, `Gross Revenue Retention %`, `Logo Retention %`.

### Customers and revenue over time — Line chart

| Well | Field |
|---|---|
| X-axis | `dim_date[month_end]` |
| Y-axis | `Active MRR`, `Active Customers` |

### MRR movement — Stacked column chart

| Well | Field |
|---|---|
| X-axis | `dim_date[month_end]` |
| Y-axis | `New MRR`, `Expansion MRR`, `Contraction MRR`, `Churned MRR` |

Gains sit above the line, losses below.

> **If this one is slow:** those four measures check all 1,400 customers twice for every month.
> Drag `dim_date[month_end]` into the visual's **Filters** and restrict it to the last 12 months.

---

# Part 6 · Polish

1. **View** ribbon → **Themes** → pick one. Any consistent theme beats default.
2. Give every visual a title: select it → **Format** → **General** → **Title** → On.
3. On each page, **Insert → Text box** and add a one-line description of what the page answers.
4. Add a footer text box: *"Simulated data. Generated from a known demand model so the analysis can
   be validated against ground truth."* — this pre-empts the first question anyone will ask.

---

# Part 7 · Save and capture

### 7.1 Save

**File → Save as** → navigate to the repo → the `power_bi` folder → filename `revyield` → **Save**.

You should end up with `power_bi/revyield.pbix`.

### 7.2 Screenshots

Create a folder `power_bi/screenshots`.

For each of the first two pages:

1. **View** ribbon → **Page view** → **Fit to page**
2. `Windows key + Shift + S` → drag around the report canvas only (not the ribbon or panes)
3. Paste into Paint → save as PNG

Name them `overview.png` and `price-test.png`.

### 7.3 Tell me

Say "done" and I'll embed the screenshots in the README, document the model, remove the "DAX
unverified" caveat from the verification table, then commit and push.

---

# Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `winget`: "No package found matching input criteria" | The id ends in `.2` — `TabularEditor.TabularEditor.2`. |
| `winget`: "No suitable installer found for manifest: Microsoft.DotNet.Framework.DeveloperPack.4.6" | Add `--skip-dependencies`. The developer pack is unpublished; the .NET 4.8 runtime in Windows 11 satisfies the real requirement. |
| No **External Tools** ribbon in Power BI | Expected on the Microsoft Store build. Use the direct connection in 3.2 instead — it needs no admin. |
| Port finder prints nothing at all | You searched for `msmdsrv.port.txt`. The Store build does not put it under `%LOCALAPPDATA%`. Use the `Get-NetTCPConnection` version in 3.2. |
| Tabular Editor: "cannot connect to localhost:NNNNN" | The .pbix must be open in Power BI. The port changes on every restart, so re-run the finder. |
| "Unable to connect… encryption" | Reopen credentials and flip the encryption setting. Neon requires SSL. |
| Connection times out | Neon suspends when idle. Try again — the second attempt wakes it. |
| A measure shows *(Blank)* | Usually a missing relationship. Recheck Part 2.3. |
| A measure errors on a column name | The paste was truncated. Recopy the whole block from `measures.dax`. |
| Ambiguity error when creating a relationship | You created the `current_tier` → `dim_tier_entitlements` link. Delete it. |
| Tiers sort alphabetically | Part 2.6 wasn't done. |
| Retention measures blank or absurd | `dim_date` wasn't marked as a date table. Part 2.4. |
| MRR line chart looks wrong | Axis is `month_start` instead of `month_end`. See Page 1. |
| Everything is slow | Confirm Import, not DirectQuery: **Home → Transform data → Data source settings**. |
| Numbers don't match Part 4 | Stop and report which. Don't build on top of it. |

---

*Every expected figure here comes from `power_bi/measures.dax` section 08 and reproduces from
`python data/seed_data.py --dry-run --summary`.*
