param([ValidateSet('start','stop','status')][string]$Action='status')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Paths.ps1"
$root=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path $LetheData 'runtime'
$logDir=Join-Path $LetheData 'logs'
New-Item -ItemType Directory -Force -Path $runtime,$logDir | Out-Null
$logFile=Join-Path $logDir ('LETHE-'+$Action+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
$report=Join-Path $runtime 'last-action.json'
$ok=$false
$err=''
$failedStage=''
$started=Get-Date
$mutex=[System.Threading.Mutex]::new($false,'Global\LETHE-One-Action')
$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if (-not $locked) { throw 'Another LETHE action is still running. Wait for it to finish.' }
    ('LETHE v0.7.2 / '+$Action.ToUpper()) | Out-File -LiteralPath $logFile -Encoding UTF8 -Width 4096
    # Stream redirection works with the embedded host; no console/transcript host is required.
    & {
        if ($Action -eq 'start') { & (Join-Path $PSScriptRoot '02-Start-One.ps1') }
        elseif ($Action -eq 'stop') { & (Join-Path $PSScriptRoot '03-Stop-One.ps1') }
        else { & (Join-Path $PSScriptRoot '04-Status-One.ps1') }
    } *>&1 | Out-File -LiteralPath $logFile -Append -Encoding UTF8 -Width 4096
    $ok=$true
    Write-Host 'Action succeeded' -ForegroundColor Green
} catch {
    # Must not echo request URLs, user names, passwords or NaiveProxy raw errors.
    $safe=[regex]::Replace([string]$_.Exception.Message,'(?i)https://[^\s@]+@','https://[REDACTED]@')
    $err=$safe
    $cause=$_.Exception
    for($i=0;$cause -and $i -lt 12;$i++){
        if($cause.Data.Contains('LetheStage')){$failedStage=[string]$cause.Data['LetheStage']}
        $cause=$cause.InnerException
    }
    $safe | Out-File -LiteralPath $logFile -Append -Encoding UTF8 -Width 4096
} finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
    $stage=''
    $statePath=Join-Path $runtime 'state.json'
    if (Test-Path -LiteralPath $statePath) {
        try { $st=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; $stage=[string]$st.stage } catch {}
    }
    if($failedStage){$stage=$failedStage}
    $obj=[ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); action=$Action; success=$ok; log=[IO.Path]::GetFileName($logFile); stage=$stage; info=$err }
    [IO.File]::WriteAllText($report,($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
if (-not $ok) { exit 1 }
