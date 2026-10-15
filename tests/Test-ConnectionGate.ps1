$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Common.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Test-TcpDirect','Test-ManagedNaive')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$server=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$c=[pscustomobject]@{vpsIp='127.0.0.1';vpsDomain='vpn.example.net';exitIp='203.0.113.7';socksPort=1080}
$p=[pscustomobject]@{Ips=@('127.0.0.1')}
try {
    $server.Start();$port=$server.LocalEndpoint.Port
    # Plain TCP server: a TLS/SChannel prerequisite would fail here.
    if(-not(Test-TcpDirect $c $p $port)){throw 'Reachable physical TCP endpoint rejected'}
    $rejected=$false
    try{Test-TcpDirect $c ([pscustomobject]@{Ips=@('192.0.2.9')}) $port | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Wrong physical source accepted'}
}finally{$server.Stop()}
$rejected=$false
try{Test-TcpDirect $c $p $port | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Closed TCP endpoint accepted'}
# Probe control-flow with injected transport result; no user server is contacted.
function Test-ManagedProcess {return $true}
function Assert-RoutePhysical {}
$script:probeIp='';$script:usedProxy=''
function Get-ExitIP([string]$proxy){$script:usedProxy=$proxy;return $script:probeIp}
$s=[pscustomobject]@{naivePid=123};$Naive='fake-test-engine'
foreach($ip in @('','203.0.113.8')){
    $script:probeIp=$ip;$rejected=$false
    try{Test-ManagedNaive $c $p $s}catch{$rejected=$true}
    if(-not $rejected){throw 'Failed or wrong-egress proxy probe accepted'}
}
$script:probeIp=$c.exitIp
Test-ManagedNaive $c $p $s
if($script:usedProxy -ne 'socks5h://127.0.0.1:1080'){throw 'Proxy verification did not use the managed SOCKS endpoint'}
$start=Get-Content (Join-Path $root 'scripts/02-Start-One.ps1') -Raw
if($start.IndexOf('Test-ManagedNaive $c $p $s') -gt $start.IndexOf('[Lethe.NativeProcess]::Start($SingBox')){throw 'TUN launched before proxy verification'}
if($start -match 'ignore-certificate-errors|insecure|skip-cert-verify'){throw 'TLS verification bypass found'}
Write-Host 'PASS: plain TCP preflight, physical source and closed-port rejection, failed/wrong-IP proxy rejection, verification precedes TUN.'
