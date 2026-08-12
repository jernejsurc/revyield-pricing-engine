/*
 * RevYield · power_bi/create_measures.csx
 *
 * Tabular Editor 2 script. Reads power_bi/measures.dax and creates every
 * measure in the connected Power BI model, with display folders taken from the
 * section headers.
 *
 * WHY THIS EXISTS
 *   Power BI Desktop has no bulk measure import. There are 67 measures. Typing
 *   them by hand is an hour of transcription errors, and measures.dax stays the
 *   single source of truth this way - re-running the script updates in place
 *   rather than duplicating.
 *
 * HOW TO RUN
 *   1. Open the .pbix in Power BI Desktop with the model built (Part 2 of
 *      docs/powerbi_build_guide.md - five relationships, date table marked).
 *   2. Find the model port:
 *        $m = Get-Process msmdsrv | Sort-Object StartTime -Descending |
 *             Select-Object -First 1
 *        Get-NetTCPConnection -OwningProcess $m.Id -State Listen |
 *             Select-Object -First 1 LocalPort
 *   3. Tabular Editor > File > Open > From DB > localhost:<port>
 *   4. Paste this whole file into the "C# Script" tab and press F5.
 *   5. Confirm it reports 67, then Ctrl+S to write into Power BI.
 *
 * NOTE ON SYNTAX
 *   Tabular Editor compiles this inside a method body, so `using` directives
 *   are illegal here - they parse as `using (x) {}` statements and fail with
 *   CS1003/CS1026. Every type below is therefore fully qualified.
 *
 * SAFETY
 *   Creates or updates by name. Never deletes. Re-runnable.
 */

// ---- edit if your checkout lives elsewhere --------------------------------
var DaxFilePath = @"C:\Users\Jernej\Desktop\RevYield B2B Pricing Elasticity & Revenue Optimization Engine\power_bi\measures.dax";

// Measures are homed on the fact table. They are model-level measures, so the
// host table only decides where they sit in the Power BI field list.
var HostTable = "fact_transactions";

// ---------------------------------------------------------------------------
if (!System.IO.File.Exists(DaxFilePath))
{
    Error("measures.dax not found at:\n" + DaxFilePath);
    return;
}
if (!Model.Tables.Contains(HostTable))
{
    Error("Table '" + HostTable + "' is not in the model. Load the data first (Part 1).");
    return;
}

// A measure definition starts at column 0 and is not VAR or RETURN. Body lines
// are indented, or begin with a character that cannot start an identifier.
var defPattern = new System.Text.RegularExpressions.Regex(
    @"^(?!\s)(?!VAR\b)(?!RETURN\b)([A-Za-z_%][A-Za-z0-9 _%()\.]*?)\s*=\s*(.*)$");

// Section headers look like:  // 01 · BASE  ·  booked economics
//
// The separator must be a non-word, non-space character. Matching any
// non-space (\S) is too loose: section 08 recaps the sections as plain
// "//   01 BASE" with no separator, and \S then swallows the first letter,
// producing folders like "06 XPANSION READINESS".
var folderPattern = new System.Text.RegularExpressions.Regex(
    @"^//\s*(\d\d)\s*[^\w\s]\s*([A-Z][A-Za-z &/]+)");

var names = new List<string>();
var bodies = new List<string>();
var folders = new List<string>();

string curFolder = "";
// The folder in force when the CURRENT measure started. A measure is committed
// only once the next one begins, by which point curFolder may have moved on -
// so the last measure in every section would otherwise inherit the next
// section's folder.
string pendingFolder = "";
string curName = null;
var buf = new System.Text.StringBuilder();

foreach (var rawLine in System.IO.File.ReadAllLines(DaxFilePath))
{
    var line = rawLine.TrimEnd();
    var trimmed = line.TrimStart();

    if (trimmed.StartsWith("//"))
    {
        var fm = folderPattern.Match(trimmed);
        if (fm.Success) curFolder = fm.Groups[1].Value + " " + fm.Groups[2].Value.Trim();
        continue;
    }

    if (trimmed.Length == 0)
    {
        if (curName != null) buf.AppendLine();
        continue;
    }

    var dm = defPattern.Match(line);
    if (dm.Success)
    {
        if (curName != null)
        {
            names.Add(curName);
            bodies.Add(buf.ToString().Trim());
            folders.Add(pendingFolder);
        }
        curName = dm.Groups[1].Value.Trim();
        pendingFolder = curFolder;
        buf = new System.Text.StringBuilder();
        var tail = dm.Groups[2].Value.Trim();
        if (tail.Length > 0) buf.AppendLine(tail);
    }
    else if (curName != null)
    {
        buf.AppendLine(line);
    }
}
if (curName != null)
{
    names.Add(curName);
    bodies.Add(buf.ToString().Trim());
    folders.Add(pendingFolder);
}

// ---- apply ---------------------------------------------------------------
var table = Model.Tables[HostTable];
int created = 0, updated = 0, skipped = 0;

for (int i = 0; i < names.Count; i++)
{
    if (bodies[i].Length == 0) { skipped++; continue; }

    Measure m = null;
    foreach (var existing in Model.AllMeasures)
    {
        if (existing.Name == names[i]) { m = existing; break; }
    }

    if (m == null) { m = table.AddMeasure(names[i]); created++; }
    else updated++;

    m.Expression = bodies[i];
    if (folders[i].Length > 0) m.DisplayFolder = folders[i];
}

// ---- formatting, per section 07 of measures.dax --------------------------
foreach (var m in Model.AllMeasures)
{
    var n = m.Name;
    if (n.EndsWith("%") || n.Contains("Retention") || n.Contains("Utilisation"))
        m.FormatString = "0.0%";
    else if (n == "Price Elasticity" || n == "Average Win Probability")
        m.FormatString = "0.00";
    else if (n == "Win Rate Gap (pp)")
        m.FormatString = "+0.0;-0.0;0.0";
    else if (n.Contains("ACV") || n.Contains("MRR") || n.Contains("ARR")
             || n.Contains("Margin") || n.Contains("Pipeline") || n.Contains("Cost")
             || n.Contains("per Seat") || n.Contains("per Opportunity")
             || n.Contains("ARPA") || n.Contains("Uplift") || n == "Average Deal Size")
        m.FormatString = "#,##0";
}

var report =
    "parsed  : " + names.Count + "   (expected 67)\n" +
    "created : " + created + "\n" +
    "updated : " + updated + "\n" +
    "skipped : " + skipped + "\n\n" +
    (names.Count == 67
        ? "Parse count matches. Close this box, then Ctrl+S to push into Power BI Desktop."
        : "PARSE COUNT MISMATCH - do NOT save. Report the number instead.");

Info(report);
