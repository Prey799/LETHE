# UTF-8 / Windows PowerShell 5.1. Do not print the credential or proxy URL.
. "$PSScriptRoot\Storage.ps1"
$ProfileHome = Join-Path $env:LOCALAPPDATA 'LETHE-One'
$EncryptedProfilePath = Join-Path $ProfileHome 'profile.dpapi'
function Protect-PrivateFile([string]$path) {
    $acl=New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $rights=[System.Security.AccessControl.FileSystemRights]::FullControl
    $type=[System.Security.AccessControl.AccessControlType]::Allow
    $self=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $system=New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
    $admins=New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
    foreach($sid in @($self,$system,$admins)) {
        $rule=New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList @($sid,$rights,$type)
        $acl.AddAccessRule($rule)
    }
    [System.IO.File]::SetAccessControl($path,$acl)
}
function Validate-ProxyUrl([string]$value,[string]$expectedDomain) {
    $uri=$null
    if (-not [Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)) { throw 'Нужна полная ссылка доступа VPN: https://логин:пароль@домен:443.' }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ine $expectedDomain -or $uri.Port -ne 443) { throw 'Домен в строке доступа должен совпадать с полем «Домен Caddy». Используйте HTTPS и порт 443.' }
    if (-not $uri.UserInfo -or $uri.UserInfo.IndexOf(':') -lt 1 -or $uri.UserInfo.EndsWith(':')) { throw 'В строке доступа отсутствует логин или пароль VPN. Используйте «Ввести логин / пароль VPN».' }
    if ($value -match '[\r\n]') { throw 'Ссылка доступа должна занимать одну строку.' }
}
function Save-ProxyUrl([string]$value,[string]$expectedDomain) {
    Validate-ProxyUrl $value $expectedDomain
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $bytes=[Text.Encoding]::UTF8.GetBytes($value)
    $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    if (-not (Test-Path -LiteralPath $ProfileHome)) { [void](New-Item -ItemType Directory -Path $ProfileHome -Force) }
    $tmp=Join-Path $ProfileHome ('profile-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($tmp,[Convert]::ToBase64String($cipher),(New-Object Text.UTF8Encoding($false)))
        Protect-PrivateFile $tmp
        Complete-LetheFileWrite $tmp $EncryptedProfilePath
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Read-StoredProxyUrl {
    if (-not (Test-Path -LiteralPath $EncryptedProfilePath)) { throw 'Нет профиля VPN. Откройте «Настройки → Доступ VPN» и импортируйте windows-01.zip, вставьте ссылку или введите действующие логин и пароль.' }
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    try {
        $cipher=[Convert]::FromBase64String([IO.File]::ReadAllText($EncryptedProfilePath))
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect($cipher,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $value=[Text.Encoding]::UTF8.GetString($bytes)
    } catch { throw 'Could not decrypt DPAPI profile for this Windows user.' }
    $u=[Uri]$value
    Validate-ProxyUrl $value $u.Host
    return $value
}
function Read-ProxyUrl([string]$expectedDomain) {
    $value=Read-StoredProxyUrl
    Validate-ProxyUrl $value $expectedDomain
    return $value
}
function New-ProxyUrl([string]$domain) {
    $bytes=New-Object byte[] 24;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    $value='https://lethe:'+([Uri]::EscapeDataString([Convert]::ToBase64String($bytes)))+'@'+$domain+':443'
    Validate-ProxyUrl $value $domain
    return $value
}
function Set-ManualProfile([string]$domain,[string]$username,[string]$password) {
    Save-ProxyUrl (ConvertTo-ProxyUrl $domain $username $password) $domain
}
function ConvertTo-ProxyUrl([string]$domain,[string]$username,[string]$password) {
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrEmpty($password)) { throw 'Username and password are required.' }
    $name=[Uri]::EscapeDataString($username)
    $pw=[Uri]::EscapeDataString($password)
    $proxy=('https://'+$name+':'+$pw+'@'+$domain+':443')
    Validate-ProxyUrl $proxy $domain
    return $proxy
}
function Read-ImportJson([string]$path) {
    if ([IO.Path]::GetExtension($path) -ieq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entries=@($archive.Entries | Where-Object { ([IO.Path]::GetFileName($_.FullName) -ieq 'profile.json') -and $_.Length -le 1048576 })
            if ($entries.Count -ne 1) { throw 'ZIP should contain exactly one profile.json (max 1 MiB).' }
            $stream=$entries[0].Open()
            try {
                $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
                try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
        } finally { $archive.Dispose() }
    }
    if ([IO.Path]::GetExtension($path) -ine '.json') { throw 'Choose profile.json or windows-01.zip.' }
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Profile file too large.' }
    return [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
}
function Find-ProxyUrlInObject($obj,[int]$depth=0) {
    if ($depth -gt 8 -or $null -eq $obj) { return $null }
    if ($obj -is [string]) {
        if ($obj -match '^https://[^\s]+@[^\s]+') { return $obj }
        return $null
    }
    if ($obj -is [array]) {
        foreach($item in $obj) { $found=Find-ProxyUrlInObject $item ($depth+1); if ($found) { return $found } }
        return $null
    }
    foreach($prop in $obj.PSObject.Properties) {
        if ($prop.Name -match '(?i)^(proxy|proxyUrl|proxy_url|naiveUrl|naive_url|endpoint|url)$') {
            $found=Find-ProxyUrlInObject $prop.Value ($depth+1)
            if ($found) { return $found }
        }
    }
    foreach($prop in $obj.PSObject.Properties) {
        $found=Find-ProxyUrlInObject $prop.Value ($depth+1)
        if ($found) { return $found }
    }
    # Support JSON with separated username and password fields.
    $names=@{}; foreach($prop in $obj.PSObject.Properties) { $names[$prop.Name.ToLowerInvariant()]=$prop.Value }
    $user=''; foreach($key in @('username','user','login')) { if ($names.ContainsKey($key) -and $names[$key] -is [string]) { $user=[string]$names[$key]; break } }
    $pass=''; foreach($key in @('password','pass')) { if ($names.ContainsKey($key) -and $names[$key] -is [string]) { $pass=[string]$names[$key]; break } }
    $serverName=''; foreach($key in @('domain','hostname','host','server')) { if ($names.ContainsKey($key) -and $names[$key] -is [string]) { $serverName=[string]$names[$key]; break } }
    if ($user -and $pass -and $serverName -match '^[a-zA-Z0-9.-]+$') {
       return ('https://'+[Uri]::EscapeDataString($user)+':'+[Uri]::EscapeDataString($pass)+'@'+$serverName+':443')
    }
    return $null
}
function Import-LetheProfile([string]$path,[string]$expectedDomain) {
    $raw=Read-ImportJson $path
    try { $doc=ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { throw 'Invalid JSON in selected profile.' }
    $value=Find-ProxyUrlInObject $doc
    if (-not $value) { throw 'No HTTPS NaiveProxy URL found. Use the manual credentials dialog.' }
    Save-ProxyUrl $value $expectedDomain
}
