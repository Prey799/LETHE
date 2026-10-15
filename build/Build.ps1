param([switch]$Installer)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not [Environment]::Is64BitOperatingSystem){throw 'Требуется Windows x64.'}
$csc=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $csc)){throw 'Установите .NET Framework 4.8.'}
foreach($f in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Ошибка PowerShell в '+$f.Name+': '+$errors[0].Message)}
}
$references=@(Get-ChildItem (Join-Path $root 'lib') -Filter '*.dll' | Where-Object {$_.Name -ne 'Lethe.SshTransport.dll'} | ForEach-Object {'/reference:'+$_.FullName})
& $csc /nologo /target:library /optimize+ /platform:anycpu ('/out:'+(Join-Path $root 'lib\Lethe.SshTransport.dll')) $references (Join-Path $root 'src\SshTransport.cs')
if($LASTEXITCODE -ne 0){throw 'Не удалось собрать SSH-библиотеку.'}
Add-Type -AssemblyName System.Management.Automation
$automation=[Management.Automation.PowerShell].Assembly.Location
& $csc /nologo /target:library /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll ('/out:'+(Join-Path $root 'lib\Lethe.Ui.dll')) (Join-Path $root 'src\Ui.cs')
if($LASTEXITCODE -ne 0){throw 'Не удалось собрать библиотеку интерфейса.'}
& $csc /nologo /target:winexe /optimize+ /platform:x64 /reference:System.Windows.Forms.dll ('/reference:'+$automation) ('/win32manifest:'+(Join-Path $PSScriptRoot 'app.manifest')) ('/out:'+(Join-Path $root 'LETHE.exe')) (Join-Path $root 'src\AppHost.cs')
if($LASTEXITCODE -ne 0){throw 'Не удалось собрать LETHE.exe.'}
& (Join-Path $PSScriptRoot 'Update-Bindings.ps1')
$testScript=Join-Path $root 'tests\Test-Project.ps1'
& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $testScript
if($LASTEXITCODE -ne 0){throw 'Проверки проекта не пройдены.'}
if($Installer){
    & (Join-Path $PSScriptRoot 'Package-Installer.ps1')
}
Write-Host 'Готово: LETHE.exe. Запускайте вместе со всеми папками проекта.' -ForegroundColor Green
