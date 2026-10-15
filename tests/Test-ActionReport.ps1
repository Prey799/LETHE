$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LETHE-report-test-'+[guid]::NewGuid().ToString('N'))
$oldAppData=$env:LOCALAPPDATA
try{
    $scripts=Join-Path $temp 'scripts';[void][IO.Directory]::CreateDirectory($scripts)
    foreach($name in @('Paths.ps1','Entry-One.ps1')){Copy-Item (Join-Path $root ('scripts/'+$name)) (Join-Path $scripts $name)}
    foreach($name in @('settings.json','ui-settings.json')){Copy-Item (Join-Path $root $name) (Join-Path $temp $name)}
    $failure=@'
try{throw 'Synthetic failure https://test:REPORT-SECRET@example.net:443'}
catch{$_.Exception.Data['LetheStage']='naive-proxy-verification';throw}
'@
    [IO.File]::WriteAllText((Join-Path $scripts '02-Start-One.ps1'),$failure,[Text.UTF8Encoding]::new($true))
    $env:LOCALAPPDATA=Join-Path $temp 'data'
    $hostName=if($PSVersionTable.PSEdition -eq 'Core'){if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'pwsh.exe'}else{'pwsh'}}else{'powershell.exe'}
    & (Join-Path $PSHOME $hostName) -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scripts 'Entry-One.ps1') -Action start
    if($LASTEXITCODE -ne 1){throw 'Failed action exit code not propagated'}
    $report=Get-Content (Join-Path $env:LOCALAPPDATA 'LETHE-One/runtime/last-action.json') -Raw | ConvertFrom-Json
    if($report.success -or $report.stage -ne 'naive-proxy-verification' -or $report.info -notmatch 'Synthetic failure'){throw 'Failure detail or stage missing from report'}
    $log=Get-Content (Join-Path $env:LOCALAPPDATA ('LETHE-One/logs/'+$report.log)) -Raw
    if($report.info.Contains('REPORT-SECRET') -or $log.Contains('REPORT-SECRET')){throw 'URL secret leaked into diagnostics'}
    if($log -notmatch 'LETHE v0.7.2'){throw 'Wrong version in log'}
    Write-Host 'PASS: failed action exit, persisted stage/detail, redacted URL credentials, current log version.'
}finally{
    $env:LOCALAPPDATA=$oldAppData
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
