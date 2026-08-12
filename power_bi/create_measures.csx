/*
 * RevYield · power_bi/create_measures.csx
 *
 * Tabular Editor 2 (free) advanced script. Reads power_bi/measures.dax and
 * creates every measure in the open Power BI model, with display folders taken
 * from the section headers.
 *
 * WHY THIS EXISTS
 *   Power BI Desktop has no bulk measure import. There are 66 measures. Typing
 *   them by hand is an hour of transcription errors, and measures.dax stays the
 *   single source of truth this way - re-running the script updates in place
 *   rather than duplicating.
 *
 * HOW TO RUN
 *   1. Open the .pbix in Power BI Desktop (model loaded, relationships set).
 *   2. External Tools ribbon > Tabular Editor.
 *   3. Advanced Scripting tab, paste this whole file.
 *   4. Edit DaxFilePath below if your repo is not at the default location.
 *   5. F5 to run, then File > Save (Ctrl+S) to push changes back to Power BI.
 *   6. Back in Power BI Desktop, the measures appear under fact_transactions.
 *
 * SAFETY
 *   Creates or updates by name. Never deletes. Re-runnable.
 *
 * NOTE
 *   This script has not been executed - there is no headless Tabular Editor to
 *   test it against. If the parse count printed at the end is not 66, stop and
 *   check the regex against your copy of measures.dax rather than saving.
 */

using System.IO;
using System.Text;
using System.Text.RegularExpressions;

// ---- edit if your checkout lives elsewhere --------------------------------
var DaxFilePath = @"C:\Users\Jernej\Desktop\RevYield B2B Pricing Elasticity & Revenue Optimization Engine\power_bi\measures.dax";

// Measures are homed on the fact table. Everything is a model-level measure, so
// the host table is cosmetic - it only decides where they sit in the field list.
var HostTable = "fact_transactions";

// ---------------------------------------------------------------------------
if (!File.Exists(DaxFilePath))
{
    Error("measures.dax not found at:\n" + DaxFilePath);
    return;
}
if (!Model.Tables.Contains(HostTable))
{
    Error("Table '" + HostTable + "' is not in the model. Load the data first.");
    return;
}

// A measure definition starts at column 0 and is not VAR or RETURN. Body lines
// are indented, or begin with a character that cannot start an identifier.
var defPattern = new Regex(@"^(?!\s)(?!VAR\b)(?!RETURN\b)([A-Za-z_%][A-Za-z0-9 _%()\.]*?)\s*=\s*(.*)$");
var folderPattern = new Regex(@"^//\s*(\d\d)\s*[·\.]\s*([A-Z][A-Za-z &/]+)");

var names = new List<string>();
var bodies = new List<string>();
var folders = new List<string>();

string curFolder = "";
string curName = null;
var buf = new StringBuilder();

foreach (var rawLine in File.ReadAllLines(DaxFilePath))
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
            names.Add(curName); bodies.Add(buf.ToString().Trim()); folders.Add(curFolder);
        }
        curName = dm.Groups[1].Value.Trim();
        buf = new StringBuilder();
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
    names.Add(curName); bodies.Add(buf.ToString().Trim()); folders.Add(curFolder);
}

// ---- apply ---------------------------------------------------------------
var table = Model.Tables[HostTable];
int created = 0, updated = 0, skipped = 0;
var log = new StringBuilder();

for (int i = 0; i < names.Count; i++)
{
    if (bodies[i].Length == 0) { skipped++; log.AppendLine("SKIP (empty body): " + names[i]); continue; }

    Measure m = null;
    foreach (var existing in Model.AllMeasures)
        if (existing.Name == names[i]) { m = existing; break; }

    if (m == null) { m = table.AddMeasure(names[i]); created++; }
    else updated++;

    m.Expression = bodies[i];
    if (folders[i].Length > 0) m.DisplayFolder = folders[i];
}

// Formatting rules from section 07 of measures.dax.
foreach (var m in Model.AllMeasures)
{
    var n = m.Name;
    if (n.EndsWith("%") || n.Contains("Retention") || n.Contains("Utilisation")
        || n == "Win Rate %" || n == "Discount %")
        m.FormatString = "0.0%";
    else if (n == "Price Elasticity")
        m.FormatString = "0.00";
    else if (n == "Win Rate Gap (pp)")
        m.FormatString = "+0.0;-0.0;0.0";
    else if (n == "Average Win Probability")
        m.FormatString = "0.00";
    else if (n.Contains("ACV") || n.Contains("MRR") || n.Contains("ARR")
             || n.Contains("Margin") || n.Contains("Pipeline") || n.Contains("Cost")
             || n.Contains("per Seat") || n.Contains("per Opportunity") || n.Contains("ARPA")
             || n.Contains("Uplift") || n == "Average Deal Size")
        m.FormatString = "#,##0";
}

log.AppendLine();
log.AppendLine("parsed  : " + names.Count + "   (expected 66)");
log.AppendLine("created : " + created);
log.AppendLine("updated : " + updated);
log.AppendLine("skipped : " + skipped);
log.AppendLine();
log.AppendLine(names.Count == 66
    ? "Parse count matches. Ctrl+S to push into Power BI Desktop."
    : "PARSE COUNT MISMATCH - do NOT save. Check measures.dax against defPattern.");

Info(log.ToString());
