$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Test-SettingsPersistence.ps1')
& (Join-Path $PSScriptRoot 'Test-DependencyBindings.ps1')
& (Join-Path $PSScriptRoot 'Test-DeployDiagnostics.ps1')
& (Join-Path $PSScriptRoot 'Test-ConnectionGate.ps1')
& (Join-Path $PSScriptRoot 'Test-ActionReport.ps1')
foreach($file in Get-ChildItem $root -Filter '*.ps1' -Recurse){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($file.Name+': '+$errors[0].Message)}
}
foreach($name in @('LETHE.exe','engine\naive.exe','engine\sing-box.exe','engine\wintun.dll','lib\Lethe.Ui.dll','lib\Lethe.SshTransport.dll','lib\Renci.SshNet.dll','server\deploy.py','server\removal.py','server\bootstrap.sh')){
    if(-not(Test-Path -LiteralPath (Join-Path $root $name))){throw ('Missing '+$name)}
}
# Config check invokes sing-box's validator only, no TUN/route creation.
& (Join-Path $root 'engine\sing-box.exe') check -c (Join-Path $root 'scripts\tun.template.json')
if($LASTEXITCODE -ne 0){throw 'sing-box configuration rejected'}
$previousAppData=$env:LOCALAPPDATA
$testAppData=Join-Path ([IO.Path]::GetTempPath()) ('LETHE-test-'+[Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=$testAppData
try {
. (Join-Path $root 'scripts\Profile.ps1')
Validate-ProxyUrl 'https://user:fake-test-secret@vpn.example.net:443' 'vpn.example.net'
$rejected=$false
try{Validate-ProxyUrl 'https://user:fake@other.example.net:443' 'vpn.example.net'}catch{$rejected=$true}
if(-not $rejected){throw 'Host validation failed'}
# Compile/load SSH dependencies in the exact Windows PowerShell runtime.
. (Join-Path $root 'scripts\Deploy-Core.ps1')
Import-SshTransport
$t=[Lethe.SshTransport]::new('127.0.0.1',22,'test','','','','')
$t.Dispose()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $root 'lib\Lethe.Ui.dll')
$field=[Lethe.RoundedField]::new();$field.Text='test';$field.UseSystemPasswordChar=$true
if($field.Input.Text -ne 'test' -or -not $field.Input.UseSystemPasswordChar){throw 'Rounded field binding failed'}
$field.Dispose()
$engine=[Lethe.NativeProcess]::Start((Join-Path $root 'engine\sing-box.exe'),'version',$root,(Join-Path $testAppData 'engine-out.txt'),(Join-Path $testAppData 'engine-error.txt'))
if(-not $engine.WaitForExit(10000) -or $engine.ExitCode -ne 0){throw 'Hidden engine launch failed'}
$engine.Dispose()
if((Get-Item (Join-Path $testAppData 'engine-out.txt')).Length -eq 0){throw 'Hidden engine log was not written'}
$native=Start-Process -FilePath (Join-Path $root 'LETHE.exe') -ArgumentList '--action status' -PassThru -Wait
if($native.ExitCode -ne 0){throw 'Native embedded host did not start. See app-startup.log in the temporary data directory.'}
$result=Get-Content (Join-Path $testAppData 'LETHE-One\runtime\last-action.json') -Raw | ConvertFrom-Json
if(-not $result.success -or $result.action -ne 'status'){throw 'Native status operation failed'}
} finally {
 $env:LOCALAPPDATA=$previousAppData
 if(Test-Path -LiteralPath $testAppData){Remove-Item -LiteralPath $testAppData -Recurse -Force}
}
Write-Host 'PASS: syntax, package files, sing-box config, profile validation, SSH/UI library load, native embedded host.'
exit 0
