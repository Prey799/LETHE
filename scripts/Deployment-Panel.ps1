$script:deployProc=$null
function Deploy-Form {
    if($script:actionProc){Msg 'Дождитесь завершения подключения или отключения.';return}
    $d=New-Object Windows.Forms.Form;$d.Text='LETHE — Деплой';$d.ClientSize=[Drawing.Size]::new(760,636)
    $d.BackColor=$bg;$d.StartPosition='CenterParent';$d.FormBorderStyle='FixedDialog';$d.MaximizeBox=$false;$d.MinimizeBox=$false
    $stateLabel=MkLabel 'Проверка сервера' 20 18 720 40 22 $teal $true;$d.Controls.Add($stateLabel)
    $summary=MkLabel 'Подключение к VPS по SSH…' 20 68 720 82 10 $muted;$d.Controls.Add($summary)
    $card=[Lethe.RoundCard]::new();$card.Location=[Drawing.Point]::new(20,162);$card.Size=[Drawing.Size]::new(720,320);$d.Controls.Add($card)
    $log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical';$log.BorderStyle='None'
    $log.BackColor=$card.BackColor;$log.ForeColor=$white;$log.Location=[Drawing.Point]::new(14,14);$log.Size=[Drawing.Size]::new(692,292);$log.Font=[Drawing.Font]::new('Segoe UI',10);$card.Controls.Add($log)
    $check=MkBtn 'ПРОВЕРИТЬ VPS' 20 500 216 44;$install=MkBtn 'УСТАНОВИТЬ СЕРВЕР' 252 500 238 44;$remove=MkBtn 'УДАЛИТЬ СЕРВЕР' 506 500 234 44 ([Drawing.Color]::FromArgb(129,57,70))
    $close=MkBtn 'ЗАКРЫТЬ' 20 565 160 43;$d.CancelButton=$close;$install.Enabled=$false;$remove.Enabled=$false;$d.Controls.AddRange(@($check,$install,$remove,$close))
    $d.Controls.Add((MkLabel 'Параметры задаются в «Настройках» главного окна. Для установки или удаления отключите LETHE. Удаление требует проверки состава и отдельного подтверждения.' 198 560 542 62 9 $muted))
    $tips=New-Object Windows.Forms.ToolTip;$tips.InitialDelay=300;$tips.AutoPopDelay=30000
    $tips.SetToolTip($remove,'Сначала будет прочитан и показан состав установки. После ввода домена и подтверждения удалятся все компоненты распознанного проекта, включая его данные. SSH и другие программы VPS сохранятся.')
    $ctx=@{jobId='';action='';status='unknown';lastCheck=$null;configKey='';lineCount=0;logPath='';plan=$null;planTime=$null;planKey='';removable=$false}
    function Confirm-Removal($plan) {
        $rd=New-Object Windows.Forms.Form;$rd.Text='Удаление сервера — подтверждение';$rd.ClientSize=[Drawing.Size]::new(728,622);$rd.BackColor=$bg;$rd.StartPosition='CenterParent';$rd.FormBorderStyle='FixedDialog';$rd.MaximizeBox=$false;$rd.MinimizeBox=$false
        $dep=Read-DeploySettings
        $rd.Controls.Add((MkLabel 'Полное удаление компонентов проекта' 20 16 688 36 19 $red $true))
        $rd.Controls.Add((MkLabel ('VPS: '+$dep.sshHost+':'+$dep.sshPort+'   •   Домен: '+$plan.domain) 20 62 688 30 10 $white $true))
        $details=New-Object Windows.Forms.TextBox;$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.BorderStyle='None';$details.BackColor=[Drawing.Color]::FromArgb(11,21,37);$details.ForeColor=$white;$details.Font=[Drawing.Font]::new('Segoe UI',10)
        $details.Location=[Drawing.Point]::new(20,108);$details.Size=[Drawing.Size]::new(688,257)
        $details.Text=$plan.message+"`r`n`r`nСлужбы:`r`n"+(@($plan.services) -join "`r`n")+"`r`n`r`nКаталоги и файлы:`r`n"+(@($plan.paths) -join "`r`n")+"`r`n`r`nУчётные записи служб:`r`n"+(@($plan.accounts) -join "`r`n")+"`r`n`r`n"+$plan.preserved
        $rd.Controls.Add($details)
        $warning=if($plan.includesMonitoring){'Отключатся все клиенты, включая Raspberry Pi. История серверного агента и резервные копии проекта будут удалены.'}else{'Отключатся все клиенты этого сервера. Сертификаты, доступы и настройки будут удалены.'}
        $rd.Controls.Add((MkLabel $warning 20 385 688 50 10 $red $true))
        $rd.Controls.Add((MkLabel ('Для подтверждения введите домен: '+$plan.domain) 20 447 688 27 10 $muted))
        $confirm=[Lethe.RoundedField]::new();$confirm.Location=[Drawing.Point]::new(20,480);$confirm.Size=[Drawing.Size]::new(688,42);$rd.Controls.Add($confirm)
        $no=MkBtn 'ОТМЕНА' 20 556 330 44;$yes=MkBtn 'УДАЛИТЬ БЕЗ ВОССТАНОВЛЕНИЯ' 378 556 330 44 ([Drawing.Color]::FromArgb(129,57,70))
        $yes.Enabled=$false;$yes.DialogResult='Yes';$no.DialogResult='Cancel';$rd.Controls.AddRange(@($no,$yes));$rd.CancelButton=$no;$rd.AcceptButton=$no
        $confirm.Add_TextChanged({$yes.Enabled=$confirm.Text -ceq [string]$plan.domain})
        try{return $rd.ShowDialog($d) -eq 'Yes'}finally{$rd.Dispose()}
    }
    function Launch-Deploy([string]$action) {
        if($script:deployProc){return}
        try {
            if($action -in @('install','remove','remove-plan') -and (Is-Active)){throw 'Отключите LETHE перед установкой или удалением сервера.'}
            Assert-DeploySettings (Read-DeploySettings)
            if($action -eq 'install' -and ($ctx.status -ne 'absent' -or $ctx.configKey -ne (Get-DeployConfigKey) -or ((Get-Date)-$ctx.lastCheck).TotalMinutes -gt 5)){throw 'Сначала выполните свежую проверку VPS.'}
            if($action -eq 'remove' -and (-not $ctx.plan -or $ctx.planKey -ne (Get-DeployConfigKey) -or ((Get-Date)-$ctx.planTime).TotalMinutes -gt 5)){throw 'План удаления устарел. Заново нажмите «Удалить сервер».'}
            $ctx.jobId=[Guid]::NewGuid().ToString('N');$ctx.action=$action;$ctx.lineCount=0
            $ctx.logPath=Join-Path $LetheData ('logs\deploy-'+$ctx.jobId+'.jsonl')
            $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Join-Path $LetheRoot 'LETHE.exe';$psi.Arguments='--deploy '+$action+' '+$ctx.jobId
            if($action -eq 'remove'){
                if($ctx.plan.planToken -notmatch '^[a-f0-9]{64}$' -or $ctx.plan.domain -notmatch '^[A-Za-z0-9.-]{1,253}$'){throw 'Некорректный план удаления.'}
                $psi.Arguments+=' '+$ctx.plan.planToken+' '+$ctx.plan.domain
            }
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=$LetheRoot
            $script:deployProc=[Diagnostics.Process]::Start($psi)
            $stateLabel.Text=switch($action){'install'{'Установка сервера…'}'remove-plan'{'Проверяю состав для удаления…'}'remove'{'Удаление сервера…'}default{'Проверяю VPS…'}}
            $stateLabel.ForeColor=$teal;$summary.Text='Этапы и результат появятся в журнале ниже.'
            $install.Enabled=$false;$remove.Enabled=$false;$check.Enabled=$false;$close.Enabled=$false
            $log.AppendText((Get-Date -Format 'HH:mm:ss')+' — '+$stateLabel.Text+[Environment]::NewLine)
        }catch{Msg $_.Exception.Message 'Деплой';$summary.Text=$_.Exception.Message}
    }
    $check.Add_Click({Launch-Deploy 'status'});$install.Add_Click({Launch-Deploy 'install'});$remove.Add_Click({Launch-Deploy 'remove-plan'});$close.Add_Click({$d.Close()})
    $poll=New-Object Windows.Forms.Timer;$poll.Interval=500
    $poll.Add_Tick({
        if(-not $script:deployProc){
            if($ctx.lastCheck -and ((Get-Date)-$ctx.lastCheck).TotalMinutes -gt 5){$install.Enabled=$false}
            return
        }
        try{
            if(Test-Path -LiteralPath $ctx.logPath){
                $lines=@(Get-Content -LiteralPath $ctx.logPath -Encoding UTF8)
                for($i=$ctx.lineCount;$i -lt $lines.Count;$i++){try{$ev=$lines[$i] | ConvertFrom-Json;if($ev.event -eq 'progress'){$log.AppendText($ev.message+[Environment]::NewLine)}}catch{}}
                $ctx.lineCount=$lines.Count
            }
            if(-not $script:deployProc.HasExited){return}
            $script:deployProc.Dispose();$script:deployProc=$null;$check.Enabled=$true;$close.Enabled=$true
            $r=Read-Json (Join-Path $LetheData ('runtime\deploy-'+$ctx.jobId+'.json'))
            if(-not $r -or $r.jobId -ne $ctx.jobId -or $r.configKey -ne (Get-DeployConfigKey)){throw 'Нет актуального результата. Проверьте VPS заново.'}
            if($r.status -eq 'host_key_required'){
                $dep=Read-DeploySettings
                $text="Первое SSH-соединение с $($dep.sshHost):$($dep.sshPort)`n`n$($r.keyType)`n$($r.fingerprint)`n`nСверьте SHA256 с консолью VPS у провайдера:`nssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`n(для другого типа ключа выберите соответствующий файл ssh_host_*_key.pub)`n`nСохранить совпавший ключ?"
                if([Windows.Forms.MessageBox]::Show($d,$text,'Проверка ключа VPS','YesNo','Question','Button2') -eq 'Yes'){$dep.hostFingerprint=[string]$r.fingerprint;Write-JsonAtomic $DeploySettingsPath $dep;Launch-Deploy 'status'}
                else{$stateLabel.Text='Ключ не подтверждён';$summary.Text='Соединение остановлено до проверки ключа VPS.'}
                return
            }
            if($r.status -eq 'removal_ready'){
                $ctx.plan=$r;$ctx.planTime=Get-Date;$ctx.planKey=[string]$r.configKey
                $stateLabel.Text='Состав удаления проверен';$summary.Text=[string]$r.message
                if(Confirm-Removal $r){Launch-Deploy 'remove'}else{$stateLabel.Text='Удаление отменено';$summary.Text='Команда удаления не отправлена. Для нового плана нажмите «Удалить сервер».';$remove.Enabled=$true}
                return
            }
            $ctx.status=[string]$r.status;$ctx.configKey=[string]$r.configKey;$ctx.lastCheck=Get-Date;$ctx.removable=[bool]$r.removable
            $summary.Text=[string]$r.message;$log.AppendText([string]$r.message+[Environment]::NewLine)
            $remove.Enabled=$ctx.removable -and -not (Is-Active)
            switch($r.status){
                'installed'{$stateLabel.Text='Сервер установлен';$install.Enabled=$false;if($r.managed -and -not $r.running){$summary.Text+=' Служба остановлена.'}}
                'absent'{$stateLabel.Text='Сервер не установлен';$install.Enabled=-not (Is-Active)}
                'removed'{$stateLabel.Text='Сервер удалён';$stateLabel.ForeColor=$teal;$ctx.plan=$null;$install.Enabled=$false;$remove.Enabled=$false;$summary.Text+=' Для новой установки нажмите «Проверить VPS».'}
                'partial_removal'{$stateLabel.Text='Удаление не завершено';$stateLabel.ForeColor=[Drawing.Color]::Orange}
                'conflict'{$stateLabel.Text='Требуется проверка';$stateLabel.ForeColor=[Drawing.Color]::Orange}
                default{$stateLabel.Text='Операция не завершена';$stateLabel.ForeColor=$red;$install.Enabled=$false;$remove.Enabled=$false}
            }
        }catch{
            $stateLabel.Text='Не удалось получить результат';$summary.Text=$_.Exception.Message;$install.Enabled=$false;$remove.Enabled=$false
            if($script:deployProc -and $script:deployProc.HasExited){$script:deployProc.Dispose();$script:deployProc=$null;$check.Enabled=$true;$close.Enabled=$true}
        }
    })
    $d.Add_FormClosing({param($sender,$e);if($script:deployProc){$e.Cancel=$true;$summary.Text='Дождитесь завершения операции.'}})
    $d.Add_Shown({Launch-Deploy 'status'});$poll.Start()
    try{[void]$d.ShowDialog($form)}finally{$poll.Stop();$poll.Dispose();$tips.Dispose();$d.Dispose()}
}
