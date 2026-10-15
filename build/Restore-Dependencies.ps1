# Optional recovery of the bundled SSH dependencies from pinned NuGet packages.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$items=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LETHE-deps-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try{
    foreach($item in $items){
        $file=Join-Path $temp ($item.id+'.nupkg')
        Invoke-WebRequest -UseBasicParsing -Uri $item.url -OutFile $file -TimeoutSec 120
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $item.sha256){throw ('SHA256 mismatch: '+$item.id)}
        $zip=[IO.Compression.ZipFile]::OpenRead($file)
        try{
            foreach($name in $item.files){
                $entry=$zip.GetEntry($name)
                if(-not $entry){throw ('Missing package member: '+$name)}
                $dest=Join-Path (Join-Path $root 'lib') ([IO.Path]::GetFileName($name))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
            }
        }finally{$zip.Dispose()}
    }
    Write-Host 'SSH dependencies restored. Run BUILD.cmd to rebuild Lethe.SshTransport.dll.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
