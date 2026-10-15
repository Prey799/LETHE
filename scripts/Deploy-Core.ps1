. "$PSScriptRoot\Paths.ps1"
. "$PSScriptRoot\Profile.ps1"
$DeploySettingsPath=Join-Path $LetheData 'deploy-settings.json'
$DeploySecretPath=Join-Path $LetheData 'deploy-secrets.dpapi'
function Read-DeploySettings {
    $d=[ordered]@{sshHost=''; sshPort=22; sshUser='root'; authMode='password'; keyPath=''; hostFingerprint=''; email=''}
    if(Test-Path -LiteralPath $DeploySettingsPath) {
        $v=Get-Content -LiteralPath $DeploySettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach($k in @($d.Keys)){if($null -ne $v.$k){$d[$k]=$v.$k}}
    }
    return [pscustomobject]$d
}
function Read-DeploySecrets {
    if(-not (Test-Path -LiteralPath $DeploySecretPath)){return [pscustomobject]@{sshPassword=''; keyPassphrase=''}}
    Add-Type -AssemblyName System.Security
    try {
        $cipher=[Convert]::FromBase64String([IO.File]::ReadAllText($DeploySecretPath))
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect($cipher,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {throw 'Не удалось расшифровать SSH-данные этого пользователя Windows.'}
}
function Save-DeploySecrets($secrets) {
    Add-Type -AssemblyName System.Security
    $bytes=[Text.Encoding]::UTF8.GetBytes(($secrets | ConvertTo-Json -Compress))
    $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $tmp=$DeploySecretPath+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,[Convert]::ToBase64String($cipher))
        Protect-PrivateFile $tmp
        Complete-LetheFileWrite $tmp $DeploySecretPath
    } finally {if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function Assert-DeploySettings($d) {
    if([string]$d.sshHost -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'){throw 'Укажите IP или имя VPS для SSH в Настройках.'}
    if([int]$d.sshPort -lt 1 -or [int]$d.sshPort -gt 65535){throw 'Неверный порт SSH.'}
    if([string]$d.sshUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$'){throw 'Неверный SSH-пользователь.'}
    if($d.authMode -notin @('password','key')){throw 'Неверный способ SSH-входа.'}
    if($d.authMode -eq 'key' -and (-not (Test-Path -LiteralPath $d.keyPath -PathType Leaf))){throw 'Не найден приватный SSH-ключ.'}
    if($d.hostFingerprint -and [string]$d.hostFingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw 'Отпечаток SSH должен иметь вид SHA256:…'}
}
function Get-DeployConfigKey {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $value=''
        foreach($p in @((Join-Path $LetheData 'settings.json'),$DeploySettingsPath,$DeploySecretPath,$EncryptedProfilePath)) {
            if(Test-Path -LiteralPath $p){$value += [IO.File]::ReadAllText($p)}
            $value += "`n"
        }
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-','')
    } finally {$sha.Dispose()}
}
function Import-SshTransport {
    $lib=Join-Path $LetheRoot 'lib'
    # Load dependency assemblies before SSH.NET, outside GUI process.
    foreach($name in @('System.Runtime.CompilerServices.Unsafe.dll','System.Buffers.dll','System.Memory.dll',
        'System.Threading.Tasks.Extensions.dll','System.Numerics.Vectors.dll','System.ValueTuple.dll','Microsoft.Bcl.AsyncInterfaces.dll',
        'Microsoft.Extensions.DependencyInjection.Abstractions.dll','Microsoft.Extensions.Logging.Abstractions.dll',
        'System.Formats.Asn1.dll','Microsoft.Bcl.Cryptography.dll','BouncyCastle.Cryptography.dll','Renci.SshNet.dll')) {
        $path=Join-Path $lib $name
        if(Test-Path -LiteralPath $path){[void][Reflection.Assembly]::LoadFrom($path)}
    }
    $dll=Join-Path $lib 'Lethe.SshTransport.dll'
    if(-not(Test-Path -LiteralPath $dll)){throw 'Не найдена библиотека деплоя. Выполните BUILD.cmd.'}
    [void][Reflection.Assembly]::LoadFrom($dll)
}
