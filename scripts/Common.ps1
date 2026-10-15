$ErrorActionPreference='Stop'
. "$PSScriptRoot\Paths.ps1"
$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $LetheData 'runtime'
$StateFile = Join-Path $Runtime 'state.json'
$ConfigFile = Join-Path $Runtime 'tun.json'
$HostPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostMarker = '# LETHE-V041-OWNED'
$SingBox = Join-Path $Root 'engine\sing-box.exe'
$Naive = Join-Path $Root 'engine\naive.exe'
$NaiveConfig = Join-Path $Runtime 'naive.secret.json'

function Require-Admin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges required. Use buttons 1/3/4.' }
}
function Read-Settings {
    $filename=Join-Path $LetheData 'settings.json'
    if (-not (Test-Path -LiteralPath $filename)) { throw "Missing settings: $filename" }
    $c=Get-Content -LiteralPath $filename -Raw -Encoding UTF8 | ConvertFrom-Json
    $ip=$null
    if (-not [System.Net.IPAddress]::TryParse([string]$c.vpsIp,[ref]$ip) -or $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Invalid vpsIp' }
    if ([int]$c.socksPort -lt 1 -or [int]$c.socksPort -gt 65535) { throw 'Invalid socksPort' }
    if ([string]$c.vpsDomain -notmatch '^[a-zA-Z0-9.-]+$') { throw 'Invalid vpsDomain' }
    if (-not [Net.IPAddress]::TryParse([string]$c.exitIp,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Invalid exitIp' }
    if ([int]$c.tunMtu -lt 1280 -or [int]$c.tunMtu -gt 9000) { throw 'tunMtu must be 1280..9000' }
    if ([int]$c.healthFailLimit -lt 2 -or [int]$c.healthFailLimit -gt 20) { throw 'healthFailLimit must be 2..20' }
    return $c
}
function Read-State {
    if (Test-Path -LiteralPath $StateFile) { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}
function Write-State($state) {
    New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
    $tmp="$StateFile.tmp"
    ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}
function Get-PhysicalGateway($c) {
    $alias=[string]$c.physicalInterface
    if ([string]::IsNullOrWhiteSpace($alias)) {
        $candidates=@()
        foreach($adapter in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {$_.Status -eq 'Up'})) {
            $routes=@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            $metric=Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            foreach($r in $routes){$candidates += [pscustomobject]@{Alias=$adapter.Name;Cost=([int]$r.RouteMetric+[int]$metric.InterfaceMetric)}}
        }
        if(-not $candidates){throw 'No active physical adapter with an IPv4 gateway. Select it in Settings.'}
        $alias=[string]($candidates | Sort-Object Cost | Select-Object -First 1).Alias
    }
    $cfg=Get-NetIPConfiguration -InterfaceAlias $alias -ErrorAction Stop
    if (-not $cfg.IPv4DefaultGateway -or -not $cfg.IPv4DefaultGateway.NextHop) { throw "No IPv4 gateway on $alias. Select the interface in Settings." }
    $ad=Get-NetAdapter -InterfaceIndex ([int]$cfg.InterfaceIndex) -ErrorAction Stop
    if ($ad.Status -ne 'Up' -or ([string]$ad.InterfaceDescription -match 'TAP|Wintun|WireGuard|TUN|VPN|CSQTT')) { throw "Adapter not considered physical/up: $alias" }
    if ($alias -match 'CSQTT|LETHE|Wintun|VPN|TUN') { throw "VPN adapter selected: $alias" }
    $ips=@(Get-NetIPAddress -InterfaceIndex ([int]$cfg.InterfaceIndex) -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($ips.Count -eq 0) { throw "No valid IPv4 address on $alias" }
    return [pscustomobject]@{ Index=[int]$cfg.InterfaceIndex; Gateway=[string]$cfg.IPv4DefaultGateway.NextHop; Alias=$alias; Ips=@($ips | ForEach-Object { [string]$_.IPAddress }) }
}
function Assert-NoForeignHostRoute($c,$p) {
    $routes=@(Get-NetRoute -DestinationPrefix "$($c.vpsIp)/32" -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach($r in $routes){
        if ([int]$r.InterfaceIndex -ne $p.Index -or [string]$r.NextHop -ne $p.Gateway) {
            throw "Existing foreign VPS /32 route: $($r.InterfaceAlias) -> $($r.NextHop). No changes made."
        }
    }
    return $routes
}
function Add-TemporaryRoute($c,$p) {
    $existing=@(Assert-NoForeignHostRoute $c $p)
    if ($existing.Count -gt 0) { Write-Host 'Existing matching /32 route preserved.'; return $false }
    New-NetRoute -DestinationPrefix "$($c.vpsIp)/32" -InterfaceIndex $p.Index -NextHop $p.Gateway -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    return $true
}
function Remove-OwnRoute($state) {
    if (-not $state.routeCreated) { return }
    $routes=@(Get-NetRoute -DestinationPrefix "$($state.vpsIp)/32" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { [int]$_.InterfaceIndex -eq [int]$state.ifIndex -and [string]$_.NextHop -eq [string]$state.gateway })
    if ($routes.Count -eq 0) { return }
    foreach($r in $routes) {
        Remove-NetRoute -DestinationPrefix "$($state.vpsIp)/32" -InterfaceIndex ([int]$state.ifIndex) -NextHop ([string]$state.gateway) -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop
    }
}
function Assert-RoutePhysical($c,$p) {
    # Find-NetRoute outputs selected address and route; select the MSFT_NetRoute instance.
    $items=@(Find-NetRoute -RemoteIPAddress ([string]$c.vpsIp) -ErrorAction Stop)
    $routes=@($items | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' })
    if ($routes.Count -eq 0) { throw "Cannot identify winning route to $($c.vpsIp)" }
    if ([int]$routes[0].InterfaceIndex -ne $p.Index) { throw "Wrong VPS route: $($routes[0].InterfaceAlias), expected $($p.Alias)" }
}
function Test-TcpDirect($c,$p,[int]$port=443) {
    $socket=[Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $result=$socket.BeginConnect([string]$c.vpsIp,$port,$null,$null)
        if (-not $result.AsyncWaitHandle.WaitOne(8000)) { throw 'Direct TCP connect timed out' }
        $socket.EndConnect($result)
        $localIP=[string]$socket.Client.LocalEndPoint.Address
        if ($p.Ips -notcontains $localIP) { throw "Unexpected source IP: $localIP (expected physical adapter)" }
        # This probe only checks reachability and the physical source address.
        # The managed NaiveProxy engine performs TLS/SNI/certificate/authentication
        # checks. Its real HTTPS exit-IP probe MUST pass before the TUN is started.
        # Windows Schannel may not support the TLS version supported by NaiveProxy.
        Write-Host "Direct TCP PASS: local=$localIP; remote=$($c.vpsIp):$port. TLS and VPN authentication will be checked by NaiveProxy." -ForegroundColor Green
        return $true
    } finally { $socket.Close() }
}
function Add-TemporaryHosts($c) {
    # Only write one uniquely marked line; cleanup will never restore entire hosts from an old copy.
    $lines=@(Get-Content -LiteralPath $HostPath -ErrorAction Stop)
    if (@($lines | Where-Object { $_ -match [regex]::Escape($HostMarker) }).Count -gt 0) { throw 'Own hosts marker already present. Stop/recover first.' }
    foreach($line in $lines) {
        if ($line -notmatch '^\s*#' -and $line -match ('(?i)(^|\s)'+[regex]::Escape([string]$c.vpsDomain)+'(\s|#|$)')) { throw 'Hosts already has a VPS domain entry; stop and inspect.' }
    }
    $utf8=New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($HostPath,"`r`n$($c.vpsIp) $($c.vpsDomain) $HostMarker`r`n",$utf8)
    & ipconfig.exe /flushdns | Out-Null
}
function Remove-TemporaryHosts {
    if (-not (Test-Path -LiteralPath $HostPath)) { return }
    $encoding=[System.Text.Encoding]::Default
    $data=[System.IO.File]::ReadAllText($HostPath,$encoding)
    $lines=$data -split "`r?`n"
    $clean=@($lines | Where-Object { $_ -notmatch [regex]::Escape($HostMarker) })
    if ($clean.Count -eq $lines.Count) { return }
    # Avoid touching other lines except our own. If an unexpected encoding is encountered, stop with error.
    [System.IO.File]::WriteAllText($HostPath,($clean -join "`r`n"),$encoding)
    & ipconfig.exe /flushdns | Out-Null
}
function Get-ExitIP([string]$proxy='') {
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { $curl='curl.exe' }
    $argsText='-q -sS --connect-timeout 8 --max-time 15 '
    if ($proxy) {
        if($proxy -notmatch '^socks5h://127\.0\.0\.1:\d{1,5}$'){throw 'Invalid local verification proxy.'}
        $argsText+='--noproxy "" --proxy '+$proxy+' '
    }else{$argsText+='--noproxy "*" '}
    $result=Invoke-LetheProgram $curl ($argsText+'https://api.ipify.org') 20000
    if ($result.ExitCode -ne 0) { return '' }
    return ([string]$result.Output).Trim()
}
function Invoke-LetheProgram([string]$file,[string]$arguments,[int]$timeout=20000){
    if(-not ('Lethe.NativeProcess' -as [type])){Add-Type -Path (Join-Path $Root 'lib\Lethe.Ui.dll')}
    return [Lethe.NativeProcess]::Run($file,$arguments,$timeout)
}
function Test-ManagedNaive($c, $p, $s) {
    if (-not $s.naivePid -or -not (Test-ManagedProcess ([int]$s.naivePid) $Naive)) { throw 'Managed NaiveProxy process is not running' }
    Assert-RoutePhysical $c $p
    $ip=Get-ExitIP ('socks5h://127.0.0.1:'+([int]$c.socksPort))
    if (-not $ip) { throw 'Не получен HTTPS-ответ через NaiveProxy. Проверьте действующий профиль VPN, домен Caddy и доступность сервера. TUN не включён.' }
    if ($ip -ne [string]$c.exitIp) { throw "VPN ответил, но IP выхода отличается: получен $ip, ожидается $($c.exitIp). Проверьте IP выхода в настройках Caddy." }
    Write-Host "NaiveProxy verified, exit: $ip" -ForegroundColor Green
}
function Test-ManagedProcess([int]$pidValue, [string]$executable) {
    if ($pidValue -lt 1) { return $false }
    $proc=Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    $path=''
    try { $path=[string]$proc.Path } catch {}
    return ($path -and ([IO.Path]::GetFullPath($path) -ieq [IO.Path]::GetFullPath($executable)))
}
function Stop-OwnNaive($s) {
    if (-not $s -or -not $s.naivePid) { return }
    $proc=Get-Process -Id ([int]$s.naivePid) -ErrorAction SilentlyContinue
    if (-not $proc) { return }
    if (-not (Test-ManagedProcess ([int]$s.naivePid) $Naive)) { throw 'naive.exe PID mismatch; not terminating foreign process' }
    Stop-Process -Id ([int]$s.naivePid) -Force -ErrorAction Stop
    try { Wait-Process -Id ([int]$s.naivePid) -Timeout 12 -ErrorAction Stop } catch {
        if (Get-Process -Id ([int]$s.naivePid) -ErrorAction SilentlyContinue) { throw 'naive.exe did not exit in 12 seconds' }
    }
}
function Stop-OwnEngine($s) {
    if (-not $s -or -not $s.enginePid) { return }
    $p=Get-Process -Id ([int]$s.enginePid) -ErrorAction SilentlyContinue
    if (-not $p) { return }
    $image=''
    try { $image=[string]$p.Path } catch {}
    if (-not $image -or [IO.Path]::GetFullPath($image) -ine [IO.Path]::GetFullPath($SingBox)) { throw "Cannot verify PID $($p.Id) is our sing-box; refusing to kill" }
    Stop-Process -Id $p.Id -Force -ErrorAction Stop
    try { Wait-Process -Id $p.Id -Timeout 12 -ErrorAction Stop } catch {
        if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { throw 'sing-box.exe did not exit in 12 seconds' }
    }
}
function Test-GuardianIdentity($cim,[bool]$native) {
    if(-not $cim){return $false}
    if($native){
        $expected=[IO.Path]::GetFullPath((Join-Path $Root 'LETHE.exe'))
        return ([string]$cim.ExecutablePath -ieq $expected -and [string]$cim.CommandLine -match '^\s*(?:"[^"\r\n]+"|[^\s"]+)\s+--guardian\s*$')
    }
    $expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Guardian-One.ps1'))
    return ([string]$cim.CommandLine -match ('(?i)-File\s+"?'+[regex]::Escape($expected)+'"?\s*$'))
}
function Stop-OwnGuardian($s) {
    if (-not $s -or -not $s.PSObject.Properties['guardianPid'] -or [int]$s.guardianPid -lt 1) { return }
    $guardId=[int]$s.guardianPid
    if ($guardId -eq $PID) { return } # Guardian can call Cleanup-LETHE itself.
    $proc=Get-Process -Id $guardId -ErrorAction SilentlyContinue
    if (-not $proc) { return }
    $cim=Get-CimInstance Win32_Process -Filter ("ProcessId = $guardId") -ErrorAction Stop
    $native=$s.PSObject.Properties['guardianMode'] -and $s.guardianMode -eq 'native'
    if (-not (Test-GuardianIdentity $cim ([bool]$native))) {
        throw 'Guardian PID does not match managed script. Refusing to stop another process.'
    }
    Stop-Process -Id $guardId -Force -ErrorAction Stop
    try { Wait-Process -Id $guardId -Timeout 10 -ErrorAction Stop } catch {
        if (Get-Process -Id $guardId -ErrorAction SilentlyContinue) { throw 'Guardian did not exit in 10 seconds' }
    }
}
function Cleanup-LETHE($s) {
    if (-not $s) { Write-Host 'No active LETHE state.'; return }
    $issues=New-Object System.Collections.Generic.List[string]
    try { Stop-OwnGuardian $s } catch { $issues.Add("Stop guardian: $_") }
    try { Stop-OwnEngine $s } catch { $issues.Add("Stop sing-box: $_") }
    try { Stop-OwnNaive $s } catch { $issues.Add("Stop naive: $_") }
    try { Remove-OwnRoute $s } catch { $issues.Add("Remove route: $_") }
    if (Test-Path -LiteralPath $NaiveConfig) {
        try { Remove-Item -LiteralPath $NaiveConfig -Force -ErrorAction Stop } catch { $issues.Add('Delete ephemeral Naive configuration') }
    }
    # Sing-box normally removes its own Wintun routes on process termination.
    # Do not delete arbitrary routes or adapters belonging to other applications.
    if ([bool]$s.connected) {
        $routeGone=$false
        for ($i=0; $i -lt 12; $i++) {
            try {
                $chosen=@(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' })
                if ($chosen.Count -gt 0 -and [string]$chosen[0].InterfaceAlias -ne 'LETHE-TUN') { $routeGone=$true; break }
            } catch {
                # Windows may have no route if physical Internet is unavailable.
                # Only verify that our own TUN routes are gone; never modify foreign routes.
                $ownTunRoutes=@(Get-NetRoute -InterfaceAlias 'LETHE-TUN' -ErrorAction SilentlyContinue)
                if ($ownTunRoutes.Count -eq 0) { $routeGone=$true; break }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $routeGone) { $issues.Add('LETHE-TUN remains the selected public route after engine stop') }
    }
    if ($issues.Count -gt 0) {
        Write-Host 'PARTIAL ROLLBACK! state.json kept for recovery:' -ForegroundColor Red
        foreach($issue in $issues){ Write-Host $issue -ForegroundColor Red }
        throw 'Rollback incomplete. Do not delete state.json; run STOP after resolving the error.'
    }
    if (Test-Path -LiteralPath $StateFile) { Remove-Item -LiteralPath $StateFile -Force -ErrorAction Stop }
    Write-Host 'Managed LETHE engines and own route stopped.' -ForegroundColor Green
}
