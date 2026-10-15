function Settings-Form {
    if((Is-Active) -or $script:actionProc -or $script:deployProc){Msg 'Отключите VPN и дождитесь завершения текущей операции.';return}
    try{$cur=Get-LETHE-Settings;$dep=Read-DeploySettings;$secret=Read-DeploySecrets}catch{Msg 'Не удалось прочитать настройки или расшифровать SSH-данные этого пользователя.';return}
    $ctx=@{url='';imported=$false;profileError=''}
    if(Test-Path -LiteralPath $EncryptedProfilePath){try{$ctx.url=Read-StoredProxyUrl}catch{$ctx.profileError='Профиль не удалось расшифровать. Импортируйте его заново.'}}
    $available=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $settingsHeight=[Math]::Max(520,[Math]::Min(748,$available.Height-70))
    $d=New-Object Windows.Forms.Form;$d.Text='LETHE — Настройки';$d.ClientSize=[Drawing.Size]::new(822,$settingsHeight)
    $d.BackColor=$bg;$d.StartPosition='CenterParent';$d.FormBorderStyle='FixedDialog';$d.MaximizeBox=$false;$d.MinimizeBox=$false
    $d.AutoScaleMode=[Windows.Forms.AutoScaleMode]::Dpi
    $d.Controls.Add((MkLabel 'Настройки' 20 14 760 35 23 $white $true))
    $d.Controls.Add((MkLabel 'Адреса и доступы сгруппированы по назначению. Наведите курсор на поле или подпись — появится пояснение.' 20 51 780 35 9 $muted))
    $tips=New-Object Windows.Forms.ToolTip;$tips.InitialDelay=300;$tips.ReshowDelay=100;$tips.AutoPopDelay=30000;$tips.ShowAlways=$true
    $scroll=New-Object Windows.Forms.Panel;$scroll.Location=[Drawing.Point]::new(18,132);$scroll.Size=[Drawing.Size]::new(786,($settingsHeight-206));$scroll.AutoScroll=$true;$scroll.BackColor=$bg;$d.Controls.Add($scroll)
    function Hint($control,[string]$text){$tips.SetToolTip($control,$text);if($control -is [Lethe.RoundedField]){$tips.SetToolTip($control.Input,$text)}}
    function Field($card,[string]$label,[string]$value,[int]$x,[int]$y,[int]$w,[string]$hint,[bool]$password=$false){
        $l=MkLabel ($label+'  ⓘ') $x $y $w 22 9 $muted;$card.Controls.Add($l);Hint $l $hint
        $t=[Lethe.RoundedField]::new();$t.Location=[Drawing.Point]::new($x,($y+25));$t.Size=[Drawing.Size]::new($w,42);$t.Text=$value;$t.UseSystemPasswordChar=$password
        $card.Controls.Add($t);Hint $t $hint;return $t
    }
    function Choice($card,[string[]]$values,[int]$x,[int]$y,[int]$w,[string]$hint){
        $c=New-Object Windows.Forms.ComboBox;$c.DropDownStyle='DropDownList';$c.FlatStyle='Flat';$c.BackColor=[Drawing.Color]::FromArgb(18,31,50);$c.ForeColor=$white;$c.Font=[Drawing.Font]::new('Segoe UI',10)
        $c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($w,30);[void]$c.Items.AddRange($values);$card.Controls.Add($c);Hint $c $hint;return $c
    }
    function Card([string]$title,[int]$y,[int]$height){
        $c=[Lethe.RoundCard]::new();$c.Location=[Drawing.Point]::new(0,$y);$c.Size=[Drawing.Size]::new(760,$height);$scroll.Controls.Add($c)
        $c.Controls.Add((MkLabel $title 18 13 724 30 16 $teal $true));return $c
    }
    $vps=Card '01  VPS и SSH — управление сервером' 0 390
    $caddy=Card '02  Caddy — сайт и подключение VPN' 406 618
    $app=Card '03  Приложение — сеть Windows и окно' 1040 330
    $nav1=MkBtn 'VPS И SSH' 20 90 186 34;$nav2=MkBtn 'CADDY / АДРЕСА' 218 90 186 34;$navAccess=MkBtn 'ДОСТУП VPN' 416 90 186 34;$nav3=MkBtn 'ПРИЛОЖЕНИЕ' 614 90 188 34
    $d.Controls.AddRange(@($nav1,$nav2,$navAccess,$nav3))
    $nav1.Add_Click({$scroll.AutoScrollPosition=[Drawing.Point]::new(0,0)})
    $nav2.Add_Click({$scroll.AutoScrollPosition=[Drawing.Point]::new(0,406)})
    $navAccess.Add_Click({$scroll.AutoScrollPosition=[Drawing.Point]::new(0,724);$profileLine.Input.Focus()})
    $nav3.Add_Click({$scroll.AutoScrollPosition=[Drawing.Point]::new(0,1040)})
    $master=[string]$dep.sshHost;if(-not $master){$master=[string]$cur.vpsIp}
    $sshHost=Field $vps 'Адрес VPS для SSH' $master 18 52 352 'IP или имя сервера из панели хостинга. Через него LETHE устанавливает, проверяет и удаляет сервер по SSH. Если Caddy использует тот же IP, ниже выберите «IP VPS» — второй раз вводить адрес не нужно.'
    $sshPort=Field $vps 'Порт SSH' ([string]$dep.sshPort) 386 52 130 'Порт входа для управления VPS. Обычно 22. Это не порт VPN.'
    $sshUser=Field $vps 'Пользователь SSH' ([string]$dep.sshUser) 532 52 208 'Учётная запись Linux для управления VPS. Обычно root. Для другого пользователя требуется sudo без пароля.'
    $vps.Controls.Add((MkLabel 'Способ входа в VPS  ⓘ' 18 139 215 22 9 $muted))
    $auth=Choice $vps @('Пароль SSH','Приватный SSH-ключ') 18 168 216 'Выберите способ, которым входите в свой VPS. Показываются только нужные для этого способа поля.'
    $passwordPanel=New-Object Windows.Forms.Panel;$passwordPanel.Location=[Drawing.Point]::new(250,139);$passwordPanel.Size=[Drawing.Size]::new(490,114);$passwordPanel.BackColor=$vps.BackColor;$vps.Controls.Add($passwordPanel)
    $sshPassword=Field $passwordPanel 'Пароль SSH' ([string]$secret.sshPassword) 0 0 486 'Пароль пользователя Linux из блока VPS. Он нужен только для SSH-управления и защищается средствами Windows.' $true
    $keyPanel=New-Object Windows.Forms.Panel;$keyPanel.Location=$passwordPanel.Location;$keyPanel.Size=[Drawing.Size]::new(490,76);$keyPanel.BackColor=$vps.BackColor;$vps.Controls.Add($keyPanel)
    $keyPath=Field $keyPanel 'Приватный ключ' ([string]$dep.keyPath) 0 0 365 'Файл вашего приватного SSH-ключа OpenSSH/PEM. Файл с окончанием .pub не подходит.'
    $browse=MkBtn 'ВЫБРАТЬ' 375 25 110 42;$keyPanel.Controls.Add($browse)
    $keyPass=Field $vps 'Пароль ключа — только если он задан' ([string]$secret.keyPassphrase) 250 221 490 'Пароль, которым защищён файл приватного ключа. Оставьте пустым, если ключ без пароля.' $true
    $keyPassLabel=$vps.Controls[$vps.Controls.Count-2]
    $auth.Add_SelectedIndexChanged({$useKey=$auth.SelectedIndex -eq 1;$keyPanel.Visible=$useKey;$passwordPanel.Visible=-not $useKey;$keyPass.Visible=$useKey;$keyPassLabel.Visible=$useKey})
    $auth.SelectedIndex=if($dep.authMode -eq 'key'){1}else{0}
    $browse.Add_Click({$fd=New-Object Windows.Forms.OpenFileDialog;$fd.Title='Выберите приватный SSH-ключ';try{if($fd.ShowDialog($d) -eq 'OK'){$keyPath.Text=$fd.FileName}}finally{$fd.Dispose()}})
    $fingerprint=Field $vps 'Проверенный ключ VPS' ([string]$dep.hostFingerprint) 18 304 574 'Отпечаток SSH подтверждает, что это ваш сервер. При первом соединении LETHE предложит сверить его с консолью хостинга. При смене адреса или порта доверие сбрасывается.'
    $fingerprint.ReadOnly=$true
    $resetKey=MkBtn 'СБРОСИТЬ' 610 329 130 42;$vps.Controls.Add($resetKey);Hint $resetKey 'Сбросьте доверие, если переустановили VPS. При следующей проверке нужно снова сверить ключ с консолью хостинга.'
    $resetKey.Add_Click({if([Windows.Forms.MessageBox]::Show($d,'При следующем соединении потребуется заново проверить ключ VPS. Сбросить сохранённый отпечаток?','Ключ VPS','YesNo','Question','Button2') -eq 'Yes'){$fingerprint.Text=''}})
    $domain=Field $caddy 'Домен Caddy' ([string]$cur.vpsDomain) 18 52 408 'Имя HTTPS-сайта и адрес подключения VPN, например 089070.duckdns.org. Его DNS A-запись должна указывать на IP входа ниже. Не вводите https:// или путь.'
    $email=Field $caddy 'Email для сертификата' ([string]$dep.email) 442 52 298 'Используется при установке нового Caddy для получения TLS-сертификата. Это контактный адрес, не логин VPN. Для подключения к уже работающему серверу заполнять его не требуется.'
    $caddy.Controls.Add((MkLabel 'IP входа — куда подключается VPN  ⓘ' 18 135 350 22 9 $muted))
    $caddy.Controls.Add((MkLabel 'IP выхода — что увидят сайты  ⓘ' 390 135 350 22 9 $muted))
    $entryMode=Choice $caddy @('IP VPS из блока SSH','Отдельный IPv4') 18 162 350 'Вход — адрес Caddy, к которому подключается клиент. На VPS с одним IP выберите IP VPS. На сервере с двумя IP можно указать отдельный адрес.'
    $exitMode=Choice $caddy @('Тот же IP, что на входе','IP VPS из блока SSH','Отдельный IPv4') 390 162 350 'Выход — публичный адрес исходящих соединений с VPS. Это ожидаемый результат проверки. Для нового сервера LETHE настроит выделенный выход, если IP уже назначен VPS. Изменение поля не перенастраивает существующий сервер.'
    $entryIp=Field $caddy 'Отдельный IP входа' ([string]$cur.vpsIp) 18 202 350 'Отдельный публичный IPv4, назначенный VPS. На него должна смотреть A-запись домена Caddy.'
    $entryLabel=$caddy.Controls[$caddy.Controls.Count-2]
    $exitIp=Field $caddy 'Отдельный IP выхода' ([string]$cur.exitIp) 390 202 350 'Отдельный публичный IPv4 для исходящего трафика. Этот адрес уже должен принадлежать VPS.'
    $exitLabel=$caddy.Controls[$caddy.Controls.Count-2]
    $entryHint=MkLabel 'Адрес берётся из блока «VPS и SSH». Повторно вводить его не нужно.' 18 207 350 60 10 $muted;$caddy.Controls.Add($entryHint)
    $exitHint=MkLabel '' 390 207 350 60 10 $muted;$caddy.Controls.Add($exitHint)
    $entryMode.Add_SelectedIndexChanged({$entryIp.Visible=$entryMode.SelectedIndex -eq 1;$entryLabel.Visible=$entryIp.Visible;$entryHint.Visible=-not $entryIp.Visible})
    $exitMode.Add_SelectedIndexChanged({$exitIp.Visible=$exitMode.SelectedIndex -eq 2;$exitLabel.Visible=$exitIp.Visible;$exitHint.Visible=-not $exitIp.Visible;$exitHint.Text=if($exitMode.SelectedIndex -eq 0){'Используется IP входа Caddy. Повторно вводить его не нужно.'}else{'Адрес берётся из блока «VPS и SSH». Повторно вводить его не нужно.'}})
    $entryMode.SelectedIndex=if([string]$cur.vpsIp -eq $master){0}else{1}
    $exitMode.SelectedIndex=if([string]$cur.exitIp -eq [string]$cur.vpsIp){0}elseif([string]$cur.exitIp -eq $master){1}else{2}
    $ports=MkLabel "Вход Caddy: HTTPS 443  •  HTTP 80     ⓘ`nВыход: порт сайта назначения — единого выходного порта нет." 18 283 724 42 10 $white $true;$caddy.Controls.Add($ports)
    Hint $ports 'В этой конфигурации клиент подключается к Caddy по TCP 443. TCP 80 нужен для HTTP и получения сертификата. Порты фиксированы. Единого «выходного порта» нет: порт задаёт удалённый сайт или программа. Разрешения исходящих соединений определяются серверной конфигурацией.'
    $profileLine=Field $caddy 'Строка доступа VPN — логин и пароль внутри' $ctx.url 18 332 574 'Вставьте всю ссылку https://логин:пароль@домен:443. Здесь показан сохранённый профиль, скрытый точками. «Показать» откроет его для просмотра. Это доступ к VPN на VPS, а не пароль или токен учётной записи DuckDNS.' $true
    $showProfile=MkBtn 'ПОКАЗАТЬ' 610 357 130 42;$caddy.Controls.Add($showProfile)
    $showProfile.Add_Click({$profileLine.UseSystemPasswordChar=-not $profileLine.UseSystemPasswordChar;$showProfile.Text=if($profileLine.UseSystemPasswordChar){'ПОКАЗАТЬ'}else{'СКРЫТЬ'}})
    $profileStatus=MkLabel '' 18 407 724 43 10 $muted;$caddy.Controls.Add($profileStatus)
    function Update-ProfileLabel {
        if($ctx.profileError){$profileStatus.Text=$ctx.profileError;$profileStatus.ForeColor=$red}
        elseif($profileLine.Text){
            try{$u=[Uri]$profileLine.Text.Trim();Validate-ProxyUrl $profileLine.Text.Trim() $u.Host;$profileStatus.Text='Профиль: '+$u.Host+'. Изменения применятся после «Сохранить».';$profileStatus.ForeColor=$teal}
            catch{$profileStatus.Text='Нужна целая HTTPS-ссылка с логином и паролем, либо используйте кнопку ввода ниже.';$profileStatus.ForeColor=$red}
        }else{$profileStatus.Text='Нет профиля. Импортируйте прежний windows-01.zip или введите действующие логин и пароль VPN.';$profileStatus.ForeColor=$muted}
    }
    $profileLine.Input.Add_TextChanged({$ctx.profileError='';Update-ProfileLabel})
    Update-ProfileLabel
    $import=MkBtn 'ИМПОРТ JSON / ZIP' 18 461 345 42;$manual=MkBtn 'ВВЕСТИ ЛОГИН / ПАРОЛЬ VPN' 377 461 363 42;$caddy.Controls.AddRange(@($import,$manual))
    Hint $import 'Откройте выданный сервером профиль, например windows-01.zip или profile.json. Ссылка и домен загрузятся автоматически. Поддерживается и прежний профиль LETHE.'
    Hint $manual 'Если у вас есть отдельные логин и пароль VPN, введите их здесь — LETHE соберёт ссылку доступа. Учётные данные SSH и DuckDNS сюда не подходят.'
    function Accept-Profile([string]$url){$u=[Uri]$url;Validate-ProxyUrl $url $u.Host;$ctx.url=$url;$ctx.imported=$true;$ctx.profileError='';$domain.Text=$u.Host;$profileLine.Text=$url;Update-ProfileLabel}
    $import.Add_Click({$fd=New-Object Windows.Forms.OpenFileDialog;$fd.Filter='Профиль NaiveProxy|*.json;*.zip';try{if($fd.ShowDialog($d) -eq 'OK'){$raw=Read-ImportJson $fd.FileName;$url=Find-ProxyUrlInObject ($raw | ConvertFrom-Json);if(-not $url){throw 'profile'};Accept-Profile $url}}catch{Msg 'В файле не найден корректный HTTPS-профиль NaiveProxy.'}finally{$fd.Dispose()}})
    $manual.Add_Click({
        $pd=New-Object Windows.Forms.Form;$pd.Text='Доступ VPN — действующие логин и пароль';$pd.ClientSize=[Drawing.Size]::new(650,310);$pd.BackColor=$bg;$pd.StartPosition='CenterParent';$pd.FormBorderStyle='FixedDialog';$pd.MaximizeBox=$false;$pd.MinimizeBox=$false
        $pd.Controls.Add((MkLabel 'Данные VPN на вашем VPS. Не используйте пароль SSH или токен DuckDNS.' 18 12 614 42 10 $muted))
        $vpnUser=Field $pd 'Логин VPN' '' 18 62 614 'Имя пользователя NaiveProxy из действующего профиля.'
        $vpnPassword=Field $pd 'Пароль VPN' '' 18 148 614 'Действующий пароль NaiveProxy. Изменение здесь не меняет пароль на сервере.' $true
        if($profileLine.Text){try{$u=[Uri]$profileLine.Text.Trim();Validate-ProxyUrl $profileLine.Text.Trim() $u.Host;$parts=$u.UserInfo.Split(@(':'),2);$vpnUser.Text=[Uri]::UnescapeDataString($parts[0]);$vpnPassword.Text=[Uri]::UnescapeDataString($parts[1])}catch{}}
        $ok=MkBtn 'ПРИНЯТЬ' 337 250 295 42;$no=MkBtn 'ОТМЕНА' 18 250 295 42;$no.DialogResult='Cancel';$pd.Controls.AddRange(@($ok,$no));$pd.AcceptButton=$ok;$pd.CancelButton=$no
        $ok.Add_Click({try{$url=ConvertTo-ProxyUrl $domain.Text.Trim() $vpnUser.Text.Trim() $vpnPassword.Text;Accept-Profile $url;$pd.DialogResult='OK';$pd.Close()}catch{Msg 'Укажите домен Caddy, логин и пароль VPN. Пароль не должен быть пустым.'}})
        try{[void]$pd.ShowDialog($d)}finally{$vpnUser.Text='';$vpnPassword.Text='';$pd.Dispose()}
    })
    $newAccess=MkBtn 'ДЛЯ НОВОГО СЕРВЕРА' 18 523 250 42;$caddy.Controls.Add($newAccess)
    $caddy.Controls.Add((MkLabel 'Уже используете наш сервер? Сохраните прежний профиль. Эта кнопка создаёт другие данные и не подходит для восстановления доступа.' 282 520 458 72 9 $muted))
    Hint $newAccess 'Генерация для первоначальной установки нового VPS. Пароль на работающем сервере не изменяется.'
    $newAccess.Add_Click({
        if([Windows.Forms.MessageBox]::Show($d,'Будут созданы другие данные VPN для установки нового сервера. К уже работающему серверу они не подойдут. Продолжить?','Только для нового сервера','YesNo','Question','Button2') -eq 'Yes'){
            try{Accept-Profile (New-ProxyUrl $domain.Text.Trim())}catch{Msg 'Сначала укажите корректный домен Caddy.'}
        }
    })
    $iface=Field $app 'Физический интерфейс Windows' ([string]$cur.physicalInterface) 18 52 352 'Оставьте пустым для автоматического выбора Ethernet/Wi-Fi. Используется для связи с VPS вне виртуального туннеля, чтобы не возникла петля маршрутизации.'
    $socks=Field $app 'Локальный SOCKS5-порт' ([string]$cur.socksPort) 386 52 354 'Порт внутри этого компьютера, обычно 1080. Его используют компоненты LETHE. Открывать этот порт на VPS или роутере не нужно.'
    $mtu=Field $app 'MTU туннеля' ([string]$cur.tunMtu) 18 139 352 'Максимальный размер пакета виртуального адаптера. Для текущей настройки оставьте 1400. Допустимо 1280–9000.'
    $fails=Field $app 'Ошибок до отключения' ([string]$cur.healthFailLimit) 386 139 354 'Количество подряд неудачных проверок связи до отключения и восстановления обычной сети Windows. Это не kill switch. Допустимо 2–20.'
    $trayCheck=New-Object Windows.Forms.CheckBox;$trayCheck.Text='Крестик X — свернуть в трей';$trayCheck.Location=[Drawing.Point]::new(18,239);$trayCheck.Size=[Drawing.Size]::new(720,28);$trayCheck.ForeColor=$white;$trayCheck.Checked=[bool]$script:ui.closeToTray;$app.Controls.Add($trayCheck)
    $startCheck=New-Object Windows.Forms.CheckBox;$startCheck.Text='При запуске скрывать окно в трей';$startCheck.Location=[Drawing.Point]::new(18,279);$startCheck.Size=[Drawing.Size]::new(720,28);$startCheck.ForeColor=$white;$startCheck.Checked=[bool]$script:ui.startInTray;$app.Controls.Add($startCheck)
    Hint $trayCheck 'Окно скроется возле часов, подключение продолжит работать. Для полного выхода используйте меню значка LETHE.'
    Hint $startCheck 'После запуска LETHE окно сразу скроется. Откройте его двойным щелчком по значку возле часов.'
    $save=MkBtn 'СОХРАНИТЬ' 424 ($settingsHeight-54) 378 42;$cancel=MkBtn 'ОТМЕНА' 20 ($settingsHeight-54) 378 42;$d.Controls.AddRange(@($save,$cancel));$d.CancelButton=$cancel
    $cancel.Add_Click({$d.Close()})
    $save.Add_Click({
        try{
            if((Is-Active) -or $script:actionProc -or $script:deployProc){throw 'Дождитесь завершения операции.'}
            $data=[ordered]@{};foreach($p in $cur.PSObject.Properties){$data[$p.Name]=$p.Value}
            $data.vpsDomain=$domain.Text.Trim().ToLowerInvariant();$data.physicalInterface=$iface.Text.Trim()
            if($data.vpsDomain.Length -gt 253 -or $data.vpsDomain -notmatch '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'){throw 'Укажите домен Caddy без https:// и пути.'}
            $data.vpsIp=if($entryMode.SelectedIndex -eq 0){$sshHost.Text.Trim()}else{$entryIp.Text.Trim()}
            $data.exitIp=switch($exitMode.SelectedIndex){0{$data.vpsIp}1{$sshHost.Text.Trim()}2{$exitIp.Text.Trim()}}
            foreach($k in @('vpsIp','exitIp')){$ip=$null;if(-not [Net.IPAddress]::TryParse($data[$k],[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork'){throw 'Для входа и выхода Caddy нужен IPv4. Если SSH задан именем, выберите отдельный IPv4 в блоке Caddy.'}}
            $numberBoxes=@{socksPort=$socks;tunMtu=$mtu;healthFailLimit=$fails}
            foreach($k in $numberBoxes.Keys){$n=0;if(-not [int]::TryParse($numberBoxes[$k].Text,[ref]$n)){throw 'В сетевых параметрах нужно целое число.'};$data[$k]=$n}
            if($data.socksPort -lt 1 -or $data.socksPort -gt 65535){throw 'Локальный порт: 1–65535.'}
            if($data.tunMtu -lt 1280 -or $data.tunMtu -gt 9000){throw 'MTU: 1280–9000.'}
            if($data.healthFailLimit -lt 2 -or $data.healthFailLimit -gt 20){throw 'Ошибок до отключения: 2–20.'}
            $port=0;if(-not [int]::TryParse($sshPort.Text,[ref]$port)){throw 'Нужен числовой порт SSH.'}
            $ds=[ordered]@{sshHost=$sshHost.Text.Trim();sshPort=$port;sshUser=$sshUser.Text.Trim();authMode=$(if($auth.SelectedIndex -eq 1){'key'}else{'password'});keyPath=$keyPath.Text.Trim();hostFingerprint=$fingerprint.Text;email=$email.Text.Trim()}
            if($ds.sshHost -ne $dep.sshHost -or $ds.sshPort -ne $dep.sshPort){$ds.hostFingerprint=''}
            if($ds.authMode -eq 'key' -and $ds.keyPath.EndsWith('.pub')){throw 'Нужен приватный ключ, а не файл .pub.'}
            Assert-DeploySettings ([pscustomobject]$ds)
            $editedUrl=$profileLine.Text.Trim()
            if(-not $editedUrl -and $ctx.url){throw 'Строка доступа очищена. Вставьте действующий профиль; сохранённый доступ не будет удалён.'}
            if($editedUrl){
                Validate-ProxyUrl $editedUrl $data.vpsDomain
                if($editedUrl -cne $ctx.url){$ctx.imported=$true}
                $ctx.url=$editedUrl
            }
            if($ctx.imported){Validate-ProxyUrl $ctx.url $data.vpsDomain}
            $paths=@((Join-Path $LetheData 'settings.json'),$DeploySettingsPath,$DeploySecretPath,$EncryptedProfilePath,$script:uiFile)
            $before=@{};foreach($p in $paths){$before[$p]=if(Test-Path -LiteralPath $p){[IO.File]::ReadAllBytes($p)}else{$null}}
            try{
                if($ctx.imported){Save-ProxyUrl $ctx.url $data.vpsDomain}
                Write-JsonAtomic (Join-Path $LetheData 'settings.json') $data
                Write-JsonAtomic $DeploySettingsPath $ds
                Save-DeploySecrets ([ordered]@{sshPassword=$sshPassword.Text;keyPassphrase=$keyPass.Text})
                Write-JsonAtomic $script:uiFile ([ordered]@{closeToTray=$trayCheck.Checked;startInTray=$startCheck.Checked})
            }catch{foreach($p in $paths){if($null -ne $before[$p]){[IO.File]::WriteAllBytes($p,$before[$p])}elseif(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}};throw}
            $script:ui.closeToTray=$trayCheck.Checked;$script:ui.startInTray=$startCheck.Checked;$script:feedback.Text='Настройки сохранены.';$d.Close()
        }catch{Msg $_.Exception.Message 'Настройки не сохранены'}
    })
    try{[void]$d.ShowDialog($form)}finally{$ctx.url='';$profileLine.Text='';$sshPassword.Text='';$keyPass.Text='';$tips.Dispose();$d.Dispose()}
}
