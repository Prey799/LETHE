. "$PSScriptRoot\Common.ps1"
$s=Read-State
if (-not $s) { Write-Host 'LETHE: OFF (no state file)'; return }
Write-Host ('LETHE session: '+$s.startedAt)
Write-Host ('Reported connected after exit-IP check: '+[bool]$s.connected)
Write-Host ('Naive process under LETHE control: '+[bool](Test-ManagedProcess ([int]$s.naivePid) $Naive))
Write-Host ('sing-box process under LETHE control: '+[bool](Test-ManagedProcess ([int]$s.enginePid) $SingBox))
Write-Host ('Exit IP when started: '+$s.exitIp)
Write-Host ('LETHE-owned /32 route created: '+[bool]$s.routeCreated)
Write-Host 'Note: current independent connectivity is not measured by this status action.'
