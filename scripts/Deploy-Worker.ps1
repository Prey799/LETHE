param([ValidateSet('status','install','remove-plan','remove')][string]$Action='status',[Parameter(Mandatory=$true)][string]$JobId,[string]$PlanToken='',[string]$ConfirmDomain='')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Deploy-Core.ps1"
. "$PSScriptRoot\Deploy-Diagnostics.ps1"
if($JobId -notmatch '^[a-f0-9]{32}$'){exit 2}
$jobFile=Join-Path $LetheData ('runtime\deploy-'+$JobId+'.json')
$logFile=Join-Path $LetheData ('logs\deploy-'+$JobId+'.jsonl')
$result=[ordered]@{jobId=$JobId;action=$Action;status='error';installed=$false;message='Операция не завершена.';configKey=(Get-DeployConfigKey);utc=[datetime]::UtcNow.ToString('o')}
$transport=$null;$stage='';$locked=$false;$phase='чтение настроек SSH'
$mutex=[Threading.Mutex]::new($false,'Local\LETHE-One-Deploy')
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Другой процесс уже выполняет деплой.'}
    $d=Read-DeploySettings
    Assert-DeploySettings $d
    $c=Get-Content -LiteralPath (Join-Path $LetheData 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $secrets=Read-DeploySecrets
    $phase='загрузка библиотек SSH';Import-SshTransport
    $keyPath=if($d.authMode -eq 'key'){[string]$d.keyPath}else{''}
    $phase=if($keyPath -and $d.hostFingerprint){'чтение приватного SSH-ключа'}else{'создание SSH-клиента'}
    $transport=[Lethe.SshTransport]::new([string]$d.sshHost,[int]$d.sshPort,[string]$d.sshUser,[string]$secrets.sshPassword,$keyPath,[string]$secrets.keyPassphrase,[string]$d.hostFingerprint)
    if(-not $d.hostFingerprint){
        $phase='получение ключа VPS';$transport.Probe()
        if(-not $transport.Fingerprint){throw 'Не удалось получить ключ SSH.'}
        $result.status='host_key_required';$result.message='Подтвердите ключ VPS.'
        $result.fingerprint=$transport.Fingerprint;$result.keyType=$transport.KeyType
    } else {
        $phase='вход SSH на VPS';$transport.Connect()
        # Only a random, locally generated path is inserted in the shell command.
        $phase='подготовка временной папки на VPS';$candidateStage='/tmp/lethe-'+$JobId
        [void]$transport.Execute(('umask 077; mkdir -- '+$candidateStage),20)
        $stage=$candidateStage
        $phase='передача файлов по SFTP'
        $transport.Upload([IO.File]::ReadAllBytes((Join-Path $LetheRoot 'server\deploy.py')),$stage+'/deploy.py')
        $transport.Upload([IO.File]::ReadAllBytes((Join-Path $LetheRoot 'server\removal.py')),$stage+'/removal.py')
        $prefix=if($d.sshUser -eq 'root'){''}else{'sudo -n '}
        if($Action -eq 'install'){
            if(-not(Test-Path -LiteralPath $EncryptedProfilePath)){
                Save-ProxyUrl (New-ProxyUrl ([string]$c.vpsDomain)) ([string]$c.vpsDomain)
                $result.configKey=Get-DeployConfigKey
            }
            $proxy=[Uri](Read-ProxyUrl ([string]$c.vpsDomain))
            $parts=$proxy.UserInfo.Split(@(':'),2)
            $payload=[ordered]@{vpsDomain=[string]$c.vpsDomain;vpsIp=[string]$c.vpsIp;exitIp=[string]$c.exitIp;email=[string]$d.email;
                vpnUser=[Uri]::UnescapeDataString($parts[0]);vpnPassword=[Uri]::UnescapeDataString($parts[1])}
            # The plaintext exists only in memory and inside the restricted remote staging directory.
            $transport.Upload([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)),$stage+'/request.json')
        }
        if($Action -eq 'remove'){
            if($PlanToken -notmatch '^[a-f0-9]{64}$' -or $ConfirmDomain -notmatch '^[A-Za-z0-9.-]{1,253}$'){throw 'Нужно свежее подтверждение удаления сервера.'}
            $payload=[ordered]@{planToken=$PlanToken;confirmDomain=$ConfirmDomain}
            $transport.Upload([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)),$stage+'/request.json')
        }
        $transport.Upload([IO.File]::ReadAllBytes((Join-Path $LetheRoot 'server\bootstrap.sh')),$stage+'/run.sh')
        $phase='выполнение команды на VPS';$code=$transport.ExecuteLogged(($prefix+'/bin/sh '+$stage+'/run.sh '+$Action+' '+$stage),$logFile,1800)
        $last=$null
        if(Test-Path -LiteralPath $logFile){
            foreach($line in Get-Content -LiteralPath $logFile -Encoding UTF8){
                try{$event=$line | ConvertFrom-Json;if($event.event -eq 'result'){$last=$event}}catch{}
            }
        }
        if(-not $last){throw 'Нет отчёта VPS. Нужны python3 и root/sudo без пароля; проверьте SSH и повторите проверку.'}
        if($code -ne 0 -and $last.status -ne 'error'){throw 'Удалённая операция завершилась с ошибкой. Выполните проверку VPS.'}
        foreach($p in $last.PSObject.Properties){if($p.Name -ne 'event'){$result[$p.Name]=$p.Value}}
    }
} catch {
    $result.status='error';$result.installed=$false
    if($transport -and $transport.HostKeyMismatch){$result.message='Ключ SSH VPS изменился. Соединение отклонено. Сверьте отпечаток в консоли провайдера.'}
    else{$result.message=Get-LetheDeployFailure $_ $phase}
} finally {
    if($transport){
        if($stage){try{[void]$transport.Execute(('rm -f -- '+$stage+'/request.json '+$stage+'/deploy.py '+$stage+'/removal.py '+$stage+'/run.sh; rm -rf -- '+$stage+'/__pycache__; rmdir -- '+$stage),20)}catch{}}
        $transport.Dispose()
    }
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    $result.utc=[datetime]::UtcNow.ToString('o')
    $tmp=$jobFile+'.tmp'
    [IO.File]::WriteAllText($tmp,($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $jobFile -Force
}
