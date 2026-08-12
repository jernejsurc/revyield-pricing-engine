# Run the Part 4 checkpoint queries against the live Power BI model.
# Must run under Windows PowerShell 5.1 - the ADOMD v100 client is .NET Framework.

$ErrorActionPreference = 'Stop'

$m = Get-Process msmdsrv -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
if (-not $m) { Write-Host "Power BI is not open with a model loaded"; exit 1 }
$port = (Get-NetTCPConnection -OwningProcess $m.Id -State Listen | Sort-Object LocalPort | Select-Object -First 1).LocalPort
Write-Host "connecting to localhost:$port"

Add-Type -Path "C:\Program Files\Microsoft.NET\ADOMD.NET\100\Microsoft.AnalysisServices.AdomdClient.dll"

$conn = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=localhost:$port")
$conn.Open()
Write-Host "connected. catalog: $($conn.Database)"

$dax = @'
EVALUATE
ROW(
    "BookedACV",        [Booked ACV],
    "UnitMarginPct",    [Realized Unit Margin %],
    "ActiveMRR",        [Active MRR],
    "WeightedPipeline", [Weighted Pipeline Forecast],
    "NRR",              [Net Revenue Retention %],
    "DealsWon",         [Deals Won],
    "ContractedSeats",  [Contracted Seats],
    "MeasureCount",     COUNTROWS( INFO.MEASURES() )
)
'@

$cmd = $conn.CreateCommand()
$cmd.CommandText = $dax
$rdr = $cmd.ExecuteReader()

$vals = @{}
while ($rdr.Read()) {
    for ($i = 0; $i -lt $rdr.FieldCount; $i++) {
        $name = $rdr.GetName($i) -replace '[\[\]]', ''
        $vals[$name] = $rdr.GetValue($i)
    }
}
$rdr.Close(); $conn.Close()

$expect = @{
    'BookedACV'        = 43679459
    'UnitMarginPct'    = 0.7015
    'ActiveMRR'        = 2921775
    'WeightedPipeline' = 1072890
    'NRR'              = 0.997
    'DealsWon'         = 1993
    'ContractedSeats'  = 359633
}

Write-Host ""
$fails = 0
foreach ($k in 'BookedACV','UnitMarginPct','ActiveMRR','WeightedPipeline','NRR','DealsWon','ContractedSeats') {
    $got = $vals[$k]
    $want = $expect[$k]
    $tol = if ($want -lt 10) { 0.0005 } else { 1 }
    $ok = ($got -ne $null) -and ([math]::Abs([double]$got - [double]$want) -le $tol)
    if (-not $ok) { $fails++ }
    "{0}  {1,-18} model {2,16:N4}   expected {3,16:N4}" -f $(if ($ok) { "ok  " } else { "FAIL" }), $k, $got, $want | Write-Host
}
Write-Host ""
Write-Host ("measures in model: {0}" -f $vals['MeasureCount'])
Write-Host ""
if ($fails -eq 0) {
    Write-Host "ALL CHECKPOINT VALUES MATCH - the DAX compiles and evaluates correctly"
} else {
    Write-Host "$fails MISMATCH(ES)"
}
exit $fails
