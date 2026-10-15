$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Storage.ps1')
$previousAppData=$env:LOCALAPPDATA
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LETHE-save-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$env:LOCALAPPDATA=$temp
try {
    $target=Join-Path $temp 'existing.dpapi';$source=Join-Path $temp 'write.tmp'
    foreach($value in @('first','second','third')){
        [IO.File]::WriteAllText($source,$value)
        Complete-LetheFileWrite $source $target
        if([IO.File]::ReadAllText($target) -cne $value -or (Test-Path -LiteralPath $source)){throw 'Repeated atomic save failed'}
    }
    $failed=$false
    try {Complete-LetheFileWrite (Join-Path $temp 'missing.tmp') $target}catch{$failed=$true}
    if(-not $failed -or [IO.File]::ReadAllText($target) -cne 'third'){throw 'Failed replacement did not preserve saved data'}
    . (Join-Path $root 'scripts/Profile.ps1')
    $url=ConvertTo-ProxyUrl 'vpn.example.net' 'test@example' 'a:b/@% test'
    $uri=[Uri]$url;$parts=$uri.UserInfo.Split(@(':'),2)
    if([Uri]::UnescapeDataString($parts[0]) -cne 'test@example' -or [Uri]::UnescapeDataString($parts[1]) -cne 'a:b/@% test'){throw 'Manual credential encoding failed'}
    Validate-ProxyUrl $url 'vpn.example.net'
    Write-Host 'PASS: first/repeated atomic saves, failed replacement preserves data, manual credential encoding.'
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
        . (Join-Path $root 'scripts/Deploy-Core.ps1')
        foreach($value in @('first-test-password','replacement-test-password')){
            $profile=ConvertTo-ProxyUrl 'vpn.example.net' 'test' $value
            Save-ProxyUrl $profile 'vpn.example.net'
            if((Read-ProxyUrl 'vpn.example.net') -cne $profile){throw 'Encrypted profile round trip failed'}
            Save-DeploySecrets ([ordered]@{sshPassword=$value;keyPassphrase='test-key'})
            if((Read-DeploySecrets).sshPassword -cne $value){throw 'Encrypted SSH secret round trip failed'}
        }
        Write-Host 'PASS: Windows DPAPI create/update/read for VPN and SSH secrets.'
    }else{Write-Host 'SKIP: Windows DPAPI/ACL round trip (requires Windows).'}
}finally{
    $env:LOCALAPPDATA=$previousAppData
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
