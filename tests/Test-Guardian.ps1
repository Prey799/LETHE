$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'scripts/Common.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-GuardianIdentity'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$exe=Join-Path $Root 'LETHE.exe'
if(-not(Test-GuardianIdentity ([pscustomobject]@{ExecutablePath=$exe;CommandLine=('"'+$exe+'" --guardian')}) $true)){throw 'Native guardian rejected'}
foreach($argsText in @('',' --action start',' --guardian --other',' --guardian-other')){
    if(Test-GuardianIdentity ([pscustomobject]@{ExecutablePath=$exe;CommandLine=('"'+$exe+'"'+$argsText)}) $true){throw 'Unrelated LETHE process accepted'}
}
if(Test-GuardianIdentity ([pscustomobject]@{ExecutablePath=(Join-Path $Root 'other.exe');CommandLine=('"'+$exe+'" --guardian')}) $true){throw 'Wrong executable accepted'}
Write-Host 'PASS: native guardian identity and unrelated process rejection.'
