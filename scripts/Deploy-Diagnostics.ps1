function Get-LetheDeployFailure($record,[string]$phase) {
    $errorObject=$record.Exception
    $types=New-Object 'System.Collections.Generic.List[string]'
    $socketCode=''
    for($i=0;$errorObject -and $i -lt 12;$i++){
        $types.Add($errorObject.GetType().FullName)
        if($errorObject -is [Net.Sockets.SocketException]){$socketCode=[string]$errorObject.SocketErrorCode}
        if(-not $errorObject.InnerException){break};$errorObject=$errorObject.InnerException
    }
    $chain=$types -join ' > '
    if($chain -match 'FileNotFoundException|FileLoadException|TypeLoadException|MissingMethodException|BadImageFormatException'){
        $message='Не удалось загрузить компонент SSH. Распакуйте архив 0.7.2 целиком в новую папку, включая lib и LETHE.exe.config.'
    }elseif($chain -match 'SshAuthenticationException'){
        $message='VPS отклонил вход SSH. Проверьте пользователя и выбранный способ входа: пароль Linux или приватный ключ, разрешённый на VPS. Это не пароль VPN.'
    }elseif($socketCode -eq 'ConnectionRefused'){
        $message='VPS отклонил TCP-соединение. Проверьте адрес VPS, порт SSH и работу SSH-службы.'
    }elseif($socketCode -in @('HostNotFound','NoData','TryAgain')){
        $message='Не удалось определить адрес VPS. Проверьте имя/IP в блоке «VPS и SSH» и DNS.'
    }elseif($socketCode -in @('TimedOut','NetworkUnreachable','HostUnreachable') -or $chain -match 'TimeoutException'){
        $message='VPS не ответил вовремя. Проверьте доступность IP и порта SSH, сеть и правила доступа на VPS.'
    }elseif($phase -eq 'чтение приватного SSH-ключа'){
        $message='Не удалось прочитать приватный SSH-ключ. Проверьте выбранный файл (не .pub), его формат и пароль ключа, если он задан.'
    }elseif($record.Exception -is [Management.Automation.RuntimeException] -and -not $record.Exception.InnerException){
        $message=$record.Exception.Message
    }else{
        $message='Не удалось завершить операцию. Проверьте доступ SSH; если началась установка или удаление, сначала выполните «Проверить VPS».'
    }
    # Library exception text can contain sensitive values: expose only exception types.
    return ($message+"`nЭтап: "+$phase+". Код: "+$types[$types.Count-1]+$(if($socketCode){' / '+$socketCode}else{''}))
}
