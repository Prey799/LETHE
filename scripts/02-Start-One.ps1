. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Profile.ps1"
Require-Admin
$c=Read-Settings
$p=Get-PhysicalGateway $c
$proxyUrl=Read-ProxyUrl ([string]$c.vpsDomain)
if (Test-Path -LiteralPath $StateFile) {
    $old=Read-State
    if ($old -and -not $old.connected -and [int]$old.enginePid -eq 0 -and [int]$old.naivePid -eq 0) {
        # Never recover automatically while the prior START process may still be running.
        $oldStarter=if ($old.PSObject.Properties['startProcessPid']) { [int]$old.startProcessPid } else { 0 }
        if ($oldStarter -le 0) { throw 'Old version has an unfinished START without owner PID. Click STOP in old LETHE before using this build.' }
        $stillStarting=($null -ne (Get-Process -Id $oldStarter -ErrorAction SilentlyContinue))
        if ($stillStarting) { throw 'Previous START is still running; wait or use STOP before retrying.' }
        Write-Host '[RECOVER] Previous incomplete START (no engine PID). Reverting LETHE-owned route and secret file.'
        Cleanup-LETHE $old
    } else {
        throw 'Existing state: click STOP in LETHE before another START.'
    }
}
foreach($file in @($SingBox,$Naive,(Join-Path $Root 'engine\wintun.dll'))) {
    if (-not (Test-Path -LiteralPath $file)) { throw 'Missing bundled engine. Extract the complete ZIP.' }
}
if (@(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort ([int]$c.socksPort) -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "SOCKS 127.0.0.1:$($c.socksPort) is already used. Stop the OTHER client first."
}

# Build TUN configuration and run check BEFORE changing routes.
$cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tun.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg.inbounds[0].mtu=[int]$c.tunMtu
$cfg.inbounds[0].route_exclude_address[0]="$($c.vpsIp)/32"
$cfg.outbounds[0].server_port=[int]$c.socksPort
# The Windows Wintun adapter does not supply reliable per-direction totals here.
# Sing-box's Clash API exposes separate downloadTotal and uploadTotal values.
# Bind to loopback only; choose a free local port per session to avoid collisions.
$apiProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
try {
    $apiProbe.Start()
    $trafficApiPort=[int]([Net.IPEndPoint]$apiProbe.LocalEndpoint).Port
} finally {
    $apiProbe.Stop()
}
$trafficApiSecret=[Guid]::NewGuid().ToString('N')
$cfg | Add-Member -MemberType NoteProperty -Name experimental -Value ([pscustomobject]@{
    clash_api=[pscustomobject]@{
        external_controller=('127.0.0.1:'+$trafficApiPort)
        secret=$trafficApiSecret
    }
}) -Force
New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($ConfigFile,($cfg | ConvertTo-Json -Depth 40),$utf8)
Protect-PrivateFile $ConfigFile
$validation=Invoke-LetheProgram $SingBox ('check -c "'+$ConfigFile+'"') 20000
if ($validation.ExitCode -ne 0) { throw 'sing-box rejected TUN config. Network unchanged.' }

$s=[ordered]@{
    version='0.7.2'; startedAt=(Get-Date).ToString('o'); vpsIp=[string]$c.vpsIp
    ifIndex=$p.Index; gateway=$p.Gateway; routeCreated=$false; enginePid=0; naivePid=0
    connected=$false; exitIp=''; guardianPid=0; guardianMode='native'; trafficApiPort=$trafficApiPort; stage='initialized'; stageSince=(Get-Date).ToUniversalTime().ToString('o'); startProcessPid=$PID
}
$committed=$false
try {
    function Set-StartStage([string]$value) {
        $s.stage=$value
        $s.stageSince=(Get-Date).ToUniversalTime().ToString('o')
        Write-State $s
        Write-Host ('[START/STAGE] '+$value)
    }
    # VPS /32 travels over real Ethernet: no circular path via TUN.
    $s.routeCreated=[bool](Add-TemporaryRoute $c $p)
    Set-StartStage 'direct-route-ready'
    Assert-RoutePhysical $c $p
    Set-StartStage 'tcp-probe-begin'
    [void](Test-TcpDirect $c $p)
    Set-StartStage 'tcp-probe-complete'

    # No command line password. Temp config is restricted to current user, SYSTEM and admin.
    $naiveCfg=[ordered]@{
        listen=('socks://127.0.0.1:'+([int]$c.socksPort))
        proxy=$proxyUrl
        'host-resolver-rules'=('MAP '+$c.vpsDomain+' '+$c.vpsIp)
    }
    if (Test-Path -LiteralPath $NaiveConfig) { throw 'Stale secret configuration found. Click STOP/recover first.' }
    Set-StartStage 'naive-config-write'
    [IO.File]::WriteAllText($NaiveConfig,($naiveCfg | ConvertTo-Json -Depth 8),$utf8)
    Set-StartStage 'naive-config-protect'
    try { Protect-PrivateFile $NaiveConfig }
    catch { throw ('Cannot secure temporary NaiveProxy config: ' + $_.Exception.GetType().Name) }
    Set-StartStage 'naive-process-launch'
    # Critical fix: Start-Process -PassThru was the last observed blocking stage.
    # Launch directly using CreateProcess (UseShellExecute=false) so Windows
    # Terminal/shell associations cannot be involved in starting this console EXE.
    # Never place the NaiveProxy password in the executable command line.
    $naiveStart=New-Object System.Diagnostics.ProcessStartInfo
    $naiveStart.FileName=[string]$Naive
    $naiveStart.Arguments='"'+[string]$NaiveConfig+'"'
    $naiveStart.WorkingDirectory=(Join-Path $Root 'engine')
    $naiveStart.UseShellExecute=$false
    $naiveStart.CreateNoWindow=$true
    $naiveStart.WindowStyle=[System.Diagnostics.ProcessWindowStyle]::Hidden
    $naiveProc=New-Object System.Diagnostics.Process
    $naiveProc.StartInfo=$naiveStart
    try {
        if (-not $naiveProc.Start()) { throw 'Process.Start returned false' }
        $s.naivePid=[int]$naiveProc.Id
        Set-StartStage 'naive-process-started'
    } catch {
        throw ('Unable to create managed naive.exe process ('+$_.Exception.GetType().Name+'): '+$_.Exception.Message)
    }


    $listening=$false
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $naiveProc.Refresh()
        if ($naiveProc.HasExited) { throw 'Managed NaiveProxy terminated at startup. Verify imported credentials.' }
        $listener=@(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort ([int]$c.socksPort) -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $s.naivePid })
        if ($listener.Count -gt 0) { $listening=$true; break }
    }
    if (-not $listening) { throw 'Managed NaiveProxy did not open its SOCKS port.' }
    Set-StartStage 'naive-socks-listening' 
    # NaiveProxy has already loaded its config. Remove plaintext as quickly as possible.
    Remove-Item -LiteralPath $NaiveConfig -Force -ErrorAction Stop
    $proxyUrl=$null
    $naiveCfg=$null
    Set-StartStage 'naive-proxy-verification'
    Test-ManagedNaive $c $p $s
    Set-StartStage 'naive-proxy-verified' 

    $stdout=Join-Path $Runtime 'singbox.out.log'
    $stderr=Join-Path $Runtime 'singbox.err.log'
    Set-StartStage 'singbox-process-launch'
    Add-Type -Path (Join-Path $Root 'lib\Lethe.Ui.dll')
    $engine=[Lethe.NativeProcess]::Start($SingBox,('run -c "'+$ConfigFile+'"'),(Join-Path $Root 'engine'),$stdout,$stderr)
    $s.enginePid=[int]$engine.Id
    Set-StartStage 'singbox-process-started' 
    Start-Sleep -Seconds 5
    $engine.Refresh()
    if ($engine.HasExited) { throw 'sing-box exited. Check runtime/singbox.err.log; no secret is stored there.' }
    $selected=@(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' })
    if ($selected.Count -eq 0 -or $selected[0].InterfaceAlias -notlike '*LETHE*') { throw 'TUN has not become Windows route for public Internet.' }
    Set-StartStage 'system-exit-ip-verification'
    $ip=Get-ExitIP
    if ($ip -ne [string]$c.exitIp) { throw "System HTTPS exit IP mismatch: got $ip." }
    $s.connected=$true
    $s.exitIp=$ip
    Set-StartStage 'starting-guardian'
    $guardian=Join-Path $Root 'LETHE.exe'
    $guardianStart=[Diagnostics.ProcessStartInfo]::new($guardian,'--guardian')
    $guardianStart.UseShellExecute=$false;$guardianStart.CreateNoWindow=$true;$guardianStart.WorkingDirectory=$Root
    $guard=[Diagnostics.Process]::Start($guardianStart)
    $s.guardianPid=[int]$guard.Id
    Set-StartStage 'connected'
    $committed=$true
    Write-Host "SUCCESS: LETHE integrated network running. Windows exit IP: $ip" -ForegroundColor Green
    Write-Host 'NaiveProxy + sing-box are managed by LETHE; old HTTPS Tunnel Client not used.' -ForegroundColor Green
} catch {
    $failedStage=[string]$s.stage
    $_.Exception.Data['LetheStage']=$failedStage
    $reason=$_.Exception.Message
    # NEVER print NaiveProxy credentials or a full HTTPS URL.
    $reason=[regex]::Replace($reason,'(?i)https://[^\s@]+@','https://[REDACTED]@')
    Write-Host ('[START/FAILED-STAGE] '+$failedStage) -ForegroundColor Red
    Write-Host ('[START/ERROR] '+$reason) -ForegroundColor Red
    throw
} finally {
    if (-not $committed) {
        Write-Warning 'START did not complete. Reverting LETHE-owned network changes.'
        if (-not (Test-Path -LiteralPath $StateFile)) { Write-State $s }
        Cleanup-LETHE $s
    }
}
