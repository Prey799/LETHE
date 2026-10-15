$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Deploy-Diagnostics.ps1')
$secret='DO-NOT-LOG-test-only-secret'
$cases=@(
    @{Error=[IO.FileLoadException]::new($secret);Phase='загрузка библиотек SSH';Expected='компонент SSH'},
    @{Error=[Net.Sockets.SocketException]::new(10061);Phase='вход SSH на VPS';Expected='отклонил TCP'},
    @{Error=[TimeoutException]::new($secret);Phase='получение ключа VPS';Expected='не ответил вовремя'},
    @{Error=[InvalidOperationException]::new($secret);Phase='чтение приватного SSH-ключа';Expected='приватный SSH-ключ'}
)
foreach($case in $cases){
    $wrapped=[Reflection.TargetInvocationException]::new($secret,$case.Error)
    $record=[Management.Automation.ErrorRecord]::new($wrapped,'Test',[Management.Automation.ErrorCategory]::NotSpecified,$null)
    $message=Get-LetheDeployFailure $record $case.Phase
    if($message -notmatch [regex]::Escape($case.Expected) -or $message.Contains($secret)){throw 'Error classification or secret redaction failed'}
}
Write-Host 'PASS: nested SSH/dependency/network/key error classification without raw secret-bearing exception text.'
