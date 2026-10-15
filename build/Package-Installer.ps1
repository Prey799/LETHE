param([string]$Compiler='makensis',[string]$OutputFile='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $OutputFile){$OutputFile=Join-Path $root 'dist/LETHE-Setup-0.7.2-x64.exe'}
$OutputFile=[IO.Path]::GetFullPath($OutputFile)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputFile))
if(-not(Get-Command $Compiler -ErrorAction SilentlyContinue)){
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$Compiler=Join-Path ${env:ProgramFiles(x86)} 'NSIS/makensis.exe'}
    if(-not(Test-Path -LiteralPath $Compiler)){throw 'Install NSIS 3.09+ or pass -Compiler with its full path.'}
}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('LETHE-package-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
function Nsis-String([string]$value){return $value.Replace('$','$$').Replace('"','$\"')}
try{
    $files=@(Get-ChildItem $root -Recurse -File | Where-Object {
        $rel=$_.FullName.Substring($root.Length+1).Replace('\','/')
        $rel -notmatch '^(dist/|\.git)' -and $rel -notmatch '(^|/)__pycache__/' -and $_.Extension -ne '.pyc' -and $_.Name -ne 'SHA256-FILES.json'
    } | Sort-Object FullName)
    $hashes=[ordered]@{}
    foreach($file in $files){
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse point in build tree'}
        $rel=$file.FullName.Substring($root.Length+1).Replace('\','/')
        $hashes[$rel]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest=Join-Path $root 'SHA256-FILES.json'
    [IO.File]::WriteAllText($manifest,([ordered]@{version='0.7.2';packaging='setup-1';algorithm='SHA256';files=$hashes} | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $files+=Get-Item -LiteralPath $manifest
    $install=New-Object 'System.Collections.Generic.List[string]'
    $uninstall=New-Object 'System.Collections.Generic.List[string]'
    $directories=@{};$size=0L
    foreach($file in $files){
        $rel=$file.FullName.Substring($root.Length+1).Replace('/','\')
        $index=$rel.LastIndexOf('\');$dir=if($index -ge 0){$rel.Substring(0,$index)}else{''}
        $target='$INSTDIR'+$(if($dir){'\'+(Nsis-String $dir)}else{''})
        $install.Add(('SetOutPath "'+$target+'"'))
        $install.Add(('File "'+(Nsis-String $file.FullName)+'"'))
        $dest='$INSTDIR\'+(Nsis-String $rel)
        $uninstall.Add(('Delete "'+$dest+'"'))
        $uninstall.Add(('IfFileExists "'+$dest+'" 0 +2'))
        $uninstall.Add('StrCpy $DeleteFailed 1')
        while($dir){$directories[$dir]=$true;$index=$dir.LastIndexOf('\');$dir=if($index -ge 0){$dir.Substring(0,$index)}else{''}}
        $size+=$file.Length
    }
    [IO.File]::WriteAllLines((Join-Path $temporary 'install-files.nsh'),$install,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $temporary 'uninstall-files.nsh'),$uninstall,[Text.UTF8Encoding]::new($false))
    $removeDirs=@($directories.Keys | Sort-Object Length -Descending | ForEach-Object {'RMDir "$INSTDIR\'+(Nsis-String $_)+'"'})
    [IO.File]::WriteAllLines((Join-Path $temporary 'uninstall-directories.nsh'),[string[]]$removeDirs,[Text.UTF8Encoding]::new($false))
    $prefix=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'/'}else{'-'}
    $argsList=@(($prefix+'V3'),($prefix+'DGENERATED_DIR='+$temporary),($prefix+'DOUTPUT_FILE='+$OutputFile),($prefix+'DINSTALLED_KB='+[Math]::Ceiling($size/1024)),(Join-Path $PSScriptRoot 'installer.nsi'))
    & $Compiler @argsList
    if($LASTEXITCODE -ne 0){throw 'NSIS compilation failed'}
    Write-Host ('Installer: '+$OutputFile+'; '+$files.Count+' payload files.')
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
