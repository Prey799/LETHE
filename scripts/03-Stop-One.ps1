. "$PSScriptRoot\Common.ps1"
Require-Admin
$s=Read-State
if (-not $s) { Write-Host 'LETHE is already off.'; return }
Cleanup-LETHE $s
Write-Host 'Both managed engines stopped; own /32 route removed if created.' -ForegroundColor Green
