# Mutable files live outside Program Files. DPAPI identity remains the Windows user.
$LetheRoot = Split-Path -Parent $PSScriptRoot
$LetheData = Join-Path $env:LOCALAPPDATA 'LETHE-One'
function Initialize-LethePaths {
    if (-not (Test-Path -LiteralPath $LetheData)) { [void](New-Item -ItemType Directory -Path $LetheData -Force) }
    foreach ($folder in @('runtime','logs')) { [void](New-Item -ItemType Directory -Path (Join-Path $LetheData $folder) -Force) }
    foreach ($name in @('settings.json','ui-settings.json')) {
        $target=Join-Path $LetheData $name
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath (Join-Path $LetheRoot $name) -Destination $target }
    }
}
Initialize-LethePaths
