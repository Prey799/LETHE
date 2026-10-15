$ErrorActionPreference='Stop'
$target=Join-Path $PSScriptRoot 'scripts\Entry-One.ps1'
$cmd='-NoProfile -NoExit -ExecutionPolicy Bypass -File "'+$target+'" -Action stop'
Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd -Verb RunAs -ErrorAction Stop | Out-Null
