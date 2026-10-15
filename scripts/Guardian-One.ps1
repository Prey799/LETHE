. "$PSScriptRoot\Common.ps1"
try { Require-Admin } catch { exit 2 }
$failures=0
Start-Sleep -Seconds 20
while ($true) {
    if (-not (Test-Path -LiteralPath $StateFile)) { exit 0 }
    try {
        $s=Read-State
        if (-not (Test-ManagedProcess ([int]$s.enginePid) $SingBox)) { throw 'sing-box missing' }
        if (-not (Test-ManagedProcess ([int]$s.naivePid) $Naive)) { throw 'naive missing' }
        $c=Read-Settings
        $ip=Get-ExitIP
        if ($ip -ne [string]$c.exitIp) { throw 'Wrong or missing exit IP' }
        $failures=0
    } catch {
        $failures++
        # Avoid logging URLs, credentials and process command lines.
        [IO.File]::AppendAllText((Join-Path $Runtime 'guardian.log'),((Get-Date -Format 'o')+' health failure '+$failures+[Environment]::NewLine))
        $limit=5
        try { $limit=[Math]::Max(2,[Math]::Min(20,[int](Read-Settings).healthFailLimit)) } catch {}
        if ($failures -ge $limit) {
            # Do not race against manual START/STOP while attempting recovery.
            $guardMutex=[System.Threading.Mutex]::new($false,'Global\LETHE-One-Action')
            $ownsLock=$false
            try {
                try{$ownsLock=$guardMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsLock=$true}
                if ($ownsLock) {
                    $s=Read-State
                    try { Cleanup-LETHE $s } catch {
                       [IO.File]::AppendAllText((Join-Path $Runtime 'guardian.log'),((Get-Date -Format 'o')+' partial rollback, use STOP'+[Environment]::NewLine))
                    }
                }
            } finally {
                if ($ownsLock) { $guardMutex.ReleaseMutex() }
                $guardMutex.Dispose()
            }
            exit 1
        }
    }
    Start-Sleep -Seconds 20
}
