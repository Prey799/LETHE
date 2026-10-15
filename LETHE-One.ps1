# LETHE ONE v0.7.2. Windows PowerShell 5.1 / WinForms. Real bidirectional traffic via sing-box API; dark theme.
$ErrorActionPreference='Stop'
$script:root=$PSScriptRoot
. "$PSScriptRoot\scripts\Paths.ps1"
. "$PSScriptRoot\scripts\Deploy-Core.ps1"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'lib\Lethe.Ui.dll')
[Windows.Forms.Application]::EnableVisualStyles()
# Do not allow duplicate visible/hidden GUI instances in one Windows session.
$script:guiMutex=[System.Threading.Mutex]::new($false,'Local\LETHE-One-GUI')
$script:guiOwned=$false
try { $script:guiOwned=$script:guiMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:guiOwned=$true }
if (-not $script:guiOwned) {
    [void][Windows.Forms.MessageBox]::Show('LETHE уже запущен. Проверьте системный трей рядом с часами.','LETHE ONE')
    $script:guiMutex.Dispose()
    exit 0
}

$bg=[Drawing.Color]::FromArgb(2,5,13)
$panel=[Drawing.Color]::FromArgb(2,5,13)
$white=[Drawing.Color]::FromArgb(236,243,249)
$muted=[Drawing.Color]::FromArgb(171,193,220)
$teal=[Drawing.Color]::FromArgb(88,214,216)
$red=[Drawing.Color]::FromArgb(209,103,136)
$buttonColor=[Drawing.Color]::FromArgb(43,58,92)
$script:uiFile=Join-Path $LetheData 'ui-settings.json'
$script:trafficDiagFile=Join-Path $LetheData 'runtime\traffic-status.json'
$script:trafficLastError=''
$script:stateFile=Join-Path $LetheData 'runtime\state.json'
$script:actionFile=Join-Path $LetheData 'runtime\last-action.json'
$script:actionProc=$null
$script:actionName=''
$script:actionStarted=$null
$script:pendingExit=$false
$script:allowClose=$false
$script:trayExit=$false
$script:lastSession=''
$script:lastRx=$null
$script:lastTx=$null
$script:lastSample=$null
$script:ui=[ordered]@{ closeToTray=$false; startInTray=$false }

function MkLabel([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[int]$size=10,[Drawing.Color]$color=$white,[bool]$bold=$false) {
    $a=New-Object Windows.Forms.Label
    $a.Text=$text; $a.Location=New-Object Drawing.Point($x,$y); $a.Size=New-Object Drawing.Size($w,$h)
    $style=if($bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $a.Font=New-Object Drawing.Font('Segoe UI',$size,$style); $a.ForeColor=$color
    $a.BackColor=[Drawing.Color]::Transparent
    return $a
}
function MkBtn([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[Drawing.Color]$color=$buttonColor) {
    $b=New-Object Windows.Forms.Button
    $b.Text=$text; $b.Location=New-Object Drawing.Point($x,$y); $b.Size=New-Object Drawing.Size($w,$h)
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0
    $b.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
    $b.BackColor=$color; $b.ForeColor=$white
    Set-ButtonRound $b 16
    return $b
}

# Reliable WinForms visuals: prerendered bitmaps (not event-handler painting).
# GDI regions are applied only to buttons, never to the Form or its content panels.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LetheRound {
    [DllImport("gdi32.dll", SetLastError=true)]
    public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);
    [DllImport("gdi32.dll", SetLastError=true)]
    public static extern bool DeleteObject(IntPtr handle);
}
'@ -ErrorAction Stop

function Set-ButtonRound([Windows.Forms.Control]$control,[int]$diameter=18) {
    if ($null -eq $control -or $control.Width -lt 2) { return }
    $hrgn=[LetheRound]::CreateRoundRectRgn(0,0,$control.Width+1,$control.Height+1,$diameter,$diameter)
    if ($hrgn -eq [IntPtr]::Zero) { return }
    try {
        $region=[Drawing.Region]::FromHrgn($hrgn)
        $old=$control.Region
        $control.Region=$region
        if($null -ne $old) { $old.Dispose() }
    } finally {
        [void][LetheRound]::DeleteObject($hrgn)
    }
}
function New-RoundPath([int]$w,[int]$h,[int]$radius) {
    $p=New-Object Drawing.Drawing2D.GraphicsPath
    $d=[int][math]::Min([math]::Min($radius*2,$w-2),$h-2)
    $p.AddArc(0,0,$d,$d,180,90)
    $p.AddArc(($w-1-$d),0,$d,$d,270,90)
    $p.AddArc(($w-1-$d),($h-1-$d),$d,$d,0,90)
    $p.AddArc(0,($h-1-$d),$d,$d,90,90)
    $p.CloseFigure()
    return $p
}
function New-CardImage([int]$w,[int]$h,[int]$radius,[Drawing.Color]$top,[Drawing.Color]$bottom) {
    $bitmap=[Drawing.Bitmap]::new($w,$h)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    $path=$null; $brush=$null; $border=$null
    try {
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($bg)
        $path=New-RoundPath $w $h $radius
        $rect=[Drawing.Rectangle]::new(0,0,$w,$h)
        $brush=[Drawing.Drawing2D.LinearGradientBrush]::new($rect,$top,$bottom,[Drawing.Drawing2D.LinearGradientMode]::Vertical)
        $g.FillPath($brush,$path)
        $border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(54,96,142,167),1.0)
        $g.DrawPath($border,$path)
    } finally {
        if($null -ne $border){$border.Dispose()}
        if($null -ne $brush){$brush.Dispose()}
        if($null -ne $path){$path.Dispose()}
        $g.Dispose()
    }
    return $bitmap
}
function Load-ImageCopy([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $bytes=[IO.File]::ReadAllBytes($path)
    $ms=New-Object IO.MemoryStream(,$bytes)
    try { $image=[Drawing.Image]::FromStream($ms);try{return [Drawing.Bitmap]::new($image)}finally{$image.Dispose()} } finally { $ms.Dispose() }
}
function Apply-LetheTheme {
    # Single source of truth: no form gradient or background bitmap.
    # Card bitmap corners are cleared with the same $bg in New-CardImage.
    $form.BackgroundImage=$null
    $form.BackColor=$bg
    $statusPanel.BackColor=$bg
    $trafficPanel.BackColor=$bg
    $statusPanel.BackgroundImage=New-CardImage $statusPanel.Width $statusPanel.Height 18 ([Drawing.Color]::FromArgb(12,24,44)) ([Drawing.Color]::FromArgb(9,18,33))
    $trafficPanel.BackgroundImage=New-CardImage $trafficPanel.Width $trafficPanel.Height 18 ([Drawing.Color]::FromArgb(12,24,44)) ([Drawing.Color]::FromArgb(9,18,33))
    $headerImagePath=Join-Path $script:root 'assets\lethe-header.png'
    $img=Load-ImageCopy $headerImagePath
    if ($img) { $headerBox.Image=$img }
    foreach($btn in @($connect,$disconnect,$settings,$deployBtn)) {
        Set-ButtonRound $btn 16
        $btn.Cursor=[Windows.Forms.Cursors]::Hand
    }
}
function Msg([string]$message,[string]$title='LETHE') {
    [void][Windows.Forms.MessageBox]::Show($message,$title,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
}
function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop)
}
function Get-LETHE-Settings { return (Read-Json (Join-Path $LetheData 'settings.json')) }
function Write-JsonAtomic([string]$path, $value) {
    $tmp=$path+'.'+([guid]::NewGuid().ToString('N'))+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,($value | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp,$path,($path+'.bak')) }
        else { [IO.File]::Move($tmp,$path) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Read-UISettings {
    try {
        $v=Read-Json $script:uiFile
        if ($v) {
            if ($null -ne $v.closeToTray) { $script:ui.closeToTray=[bool]$v.closeToTray }
            if ($null -ne $v.startInTray) { $script:ui.startInTray=[bool]$v.startInTray }
        }
    } catch { } # malformed UI settings must not interrupt the VPN client
}
function Is-Active { return (Test-Path -LiteralPath $script:stateFile) }
function Show-LETHE {
    $form.Show(); $form.WindowState=[Windows.Forms.FormWindowState]::Normal
    $form.ShowInTaskbar=$true; $form.Activate()
}
function Hide-LETHE {
    $form.Hide(); $form.ShowInTaskbar=$false
    $script:tray.Visible=$true
}
function Format-Bytes([double]$bytes) {
    if ($bytes -lt 1024) { return ('{0:N0} Б' -f $bytes) }
    if ($bytes -lt 1048576) { return ('{0:N1} КиБ' -f ($bytes/1024)) }
    if ($bytes -lt 1073741824) { return ('{0:N2} МиБ' -f ($bytes/1048576)) }
    return ('{0:N2} ГиБ' -f ($bytes/1073741824))
}
function Start-LETHE-Action([string]$action) {
    if ($script:actionProc -or $script:deployProc) { return $false }
    $entry=Join-Path $script:root 'LETHE.exe'
    $args='--action '+$action
    try {
        $script:actionProc=Start-Process -FilePath $entry -Verb RunAs -WorkingDirectory $script:root -ArgumentList $args -PassThru -ErrorAction Stop
        $script:actionName=$action
        $script:actionStarted=Get-Date
        $script:feedback.Text=if($action -eq 'stop'){'Останавливаю движки и восстанавливаю сеть...'}else{'Подключаюсь к VPS...'}
        $connect.Enabled=$false; $disconnect.Enabled=$false
        return $true
    } catch {
        $script:actionProc=$null; $script:actionName=''
        $script:pendingExit=$false
        Msg ('Не удалось запустить '+$action+'. Проверьте подтверждение UAC. '+$_.Exception.Message) 'LETHE: ошибка'
        return $false
    }
}
function Finish-ApplicationExit {
    $script:allowClose=$true
    $script:tray.Visible=$false
    $form.Close()
}
function Request-ApplicationExit {
    if($script:deployProc){Msg 'Дождитесь завершения деплоя.';return}
    if ($script:pendingExit) { return }
    $script:pendingExit=$true
    $script:feedback.Text='Закрываю LETHE после отключения и восстановления маршрутов...'
    if ($script:actionProc) { Show-LETHE; return }
    if (Is-Active) {
        if (-not (Start-LETHE-Action 'stop')) { $script:pendingExit=$false; Show-LETHE }
    } else {
        Finish-ApplicationExit
    }
}
function Poll-Action {
    if (-not $script:actionProc) { return }
    $ended=$false
    try { $ended=$script:actionProc.HasExited } catch { $ended=$true }
    if (-not $ended) { return }
    $verb=$script:actionName
    $code=1
    try { $code=$script:actionProc.ExitCode } catch {}
    $script:actionProc.Dispose()
    $script:actionProc=$null; $script:actionName=''
    $connect.Enabled=$true; $disconnect.Enabled=$true
    $result=$null
    try { $result=Read-Json $script:actionFile } catch {}
    $success=($code -eq 0 -and $result -and $result.action -eq $verb -and $result.success)
    if (-not $success) {
        $script:feedback.Text='Ошибка операции '+$verb+'. Нажмите «Логи» справа.'
        if($verb -eq 'start' -and $result -and $result.info){Msg ([string]$result.info+"`n`nЭтап: "+[string]$result.stage+"`nПодробности — кнопка «Логи».") 'LETHE: подключение не выполнено'}
        if ($script:pendingExit) {
            $script:pendingExit=$false; $script:trayExit=$false
            Show-LETHE
            Msg 'Автоматическая остановка не завершена. LETHE оставлен открытым, чтобы не скрыть проблему с сетевыми маршрутами. Используйте ОТКЛЮЧИТЬ или EMERGENCY-STOP.cmd.' 'LETHE: откат не подтверждён'
        }
        return
    }
    if ($verb -eq 'start') {
        $script:feedback.Text='Подключение подтверждено. Проверка выхода через VPS пройдена.'
        if ($script:pendingExit) { [void](Start-LETHE-Action 'stop') }
    } else {
        if (Is-Active) {
            $script:feedback.Text='STOP завершился, но state.json остался. Требуется восстановление.'
            $script:pendingExit=$false; Show-LETHE
            Msg 'После STOP всё ещё существует runtime\state.json. Закрытие отменено; проверьте журнал.' 'LETHE: неполный откат'
        } else {
            $script:feedback.Text='LETHE отключён. Воды Леты рассеялись, обычная сеть восстановлена.'
            if ($script:pendingExit) { Finish-ApplicationExit }
        }
    }
}

$script:trafficClient=$null;$script:trafficTask=$null;$script:trafficSession=''
function Reset-TrafficClient {
    if($script:trafficClient){$script:trafficClient.Dispose()}
    $script:trafficClient=$null;$script:trafficTask=$null;$script:trafficSession=''
}
function Get-SingboxTrafficSample($state) {
    if($script:trafficSession -ne [string]$state.startedAt){Reset-TrafficClient}
    if(-not $script:trafficClient){
        $cfg=Read-Json (Join-Path $LetheData 'runtime\tun.json')
        $api=$cfg.experimental.clash_api
        if(-not $api -or [string]$api.external_controller -notmatch '^127\.0\.0\.1:(\d{1,5})$'){throw 'Traffic API must be localhost.'}
        $port=[int]$Matches[1]
        if($port -lt 1 -or $port -gt 65535 -or $port -ne [int]$state.trafficApiPort){throw 'Traffic API session mismatch.'}
        Add-Type -AssemblyName System.Net.Http
        $handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false
        $script:trafficClient=[Net.Http.HttpClient]::new($handler)
        $script:trafficClient.Timeout=[TimeSpan]::FromMilliseconds(1800)
        $script:trafficClient.MaxResponseContentBufferSize=8388608
        $script:trafficClient.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',[string]$api.secret)
        $script:trafficUrl='http://127.0.0.1:'+$port+'/connections'
        $script:trafficSession=[string]$state.startedAt
    }
    if(-not $script:trafficTask){$script:trafficTask=$script:trafficClient.GetStringAsync($script:trafficUrl);return $null}
    if(-not $script:trafficTask.IsCompleted){return $null}
    try {
        $payload=$script:trafficTask.GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
    } finally {$script:trafficTask=$script:trafficClient.GetStringAsync($script:trafficUrl)}
    if($null -eq $payload.downloadTotal -or $null -eq $payload.uploadTotal){throw 'No traffic counters.'}
    $down=[double]$payload.downloadTotal;$up=[double]$payload.uploadTotal
    if([double]::IsNaN($down) -or [double]::IsInfinity($down) -or [double]::IsNaN($up) -or [double]::IsInfinity($up) -or $down -lt 0 -or $up -lt 0){throw 'Invalid traffic counters.'}
    return @{down=$down;up=$up}
}
function Refresh-Traffic($state) {
    if (-not $state -or -not $state.connected) {
        Reset-TrafficClient
        $script:lastSession=''; $script:lastRx=$null; $script:lastTx=$null; $script:lastSample=$null
        $script:downloadSpeed.Text='—'; $script:uploadSpeed.Text='—'
        $script:downloadTotal.Text='—'; $script:uploadTotal.Text='—'
        return
    }
    $session=[string]$state.startedAt
    if ($session -ne $script:lastSession) {
        $script:lastSession=$session
        $script:lastRx=$null; $script:lastTx=$null; $script:lastSample=$null
    }
    try {
        $counts=Get-SingboxTrafficSample $state
        if($null -eq $counts){return}
        $rx=[double]$counts.down
        $tx=[double]$counts.up
        $now=[datetime]::UtcNow
        # Clash API totals start at zero when sing-box starts. They are session bytes.
        $script:downloadTotal.Text=Format-Bytes $rx
        $script:uploadTotal.Text=Format-Bytes $tx
        if ($null -ne $script:lastRx -and $null -ne $script:lastTx -and $null -ne $script:lastSample) {
            $dt=[math]::Max(0.001,($now - $script:lastSample).TotalSeconds)
            if ($rx -ge $script:lastRx -and $tx -ge $script:lastTx) {
                $script:downloadSpeed.Text=('{0:N2} Мбит/с' -f ((($rx-$script:lastRx)*8)/($dt*1e6)))
                $script:uploadSpeed.Text=('{0:N2} Мбит/с' -f ((($tx-$script:lastTx)*8)/($dt*1e6)))
            } else {
                # Counter reset (for example sing-box restart), do not fabricate a rate.
                $script:downloadSpeed.Text='—'; $script:uploadSpeed.Text='—'
            }
        } else {
            $script:downloadSpeed.Text='—'; $script:uploadSpeed.Text='—'
        }
        $script:lastRx=$rx; $script:lastTx=$tx; $script:lastSample=$now
        if ($script:trafficLastError) {
            $script:trafficLastError=''
            try { Remove-Item -LiteralPath $script:trafficDiagFile -Force -ErrorAction SilentlyContinue } catch {}
        }
    } catch {
        # Crucial: do not fall back to Wintun counters, which have been shown to mirror each other.
        $script:lastRx=$null; $script:lastTx=$null; $script:lastSample=$null
        $script:downloadSpeed.Text='н/д'; $script:uploadSpeed.Text='н/д'
        $script:downloadTotal.Text='н/д'; $script:uploadTotal.Text='н/д'
        $errorMessage=[string]$_.Exception.Message
        if ($errorMessage -ne $script:trafficLastError) {
            $script:trafficLastError=$errorMessage
            try {
                # Store only a sanitized local diagnostic, never the access URI or API token.
                $safeMessage=[regex]::Replace($errorMessage,'(?i)https?://[^\s]+','[URL]')
                Write-JsonAtomic $script:trafficDiagFile ([ordered]@{
                    utc=[datetime]::UtcNow.ToString('o')
                    status='unavailable'
                    reason=$safeMessage
                })
            } catch {}
        }
    }
}
. "$PSScriptRoot\scripts\Settings-Panel.ps1"
. "$PSScriptRoot\scripts\Deployment-Panel.ps1"

Read-UISettings
$form=New-Object Windows.Forms.Form
$form.Text='LETHE | 0.7.2'
$form.ClientSize=New-Object Drawing.Size(712,626)
$form.BackColor=$bg; $form.StartPosition='CenterScreen'
$form.MaximizeBox=$false; $form.FormBorderStyle='FixedSingle'
$headerBox=New-Object Windows.Forms.PictureBox
$headerBox.Location=New-Object Drawing.Point(24,14)
$headerBox.Size=New-Object Drawing.Size(664,150)
$headerBox.BackColor=$bg
$headerBox.SizeMode=[Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($headerBox)
$statusPanel=New-Object Windows.Forms.Panel
$statusPanel.Location=New-Object Drawing.Point(24,178); $statusPanel.Size=New-Object Drawing.Size(664,126)
$statusPanel.BackColor=$panel; $form.Controls.Add($statusPanel)
$script:statusTitle=MkLabel 'НЕ ПОДКЛЮЧЕНО' 24 16 610 38 21 $red $true
$statusPanel.Controls.Add($script:statusTitle)
$script:statusDetail=MkLabel 'Готов к запуску.' 24 64 608 44 10 $muted
$statusPanel.Controls.Add($script:statusDetail)

$trafficPanel=New-Object Windows.Forms.Panel
$trafficPanel.Location=New-Object Drawing.Point(24,313); $trafficPanel.Size=New-Object Drawing.Size(664,136)
$trafficPanel.BackColor=$panel; $form.Controls.Add($trafficPanel)
$trafficPanel.Controls.Add((MkLabel 'ПОТОКИ ЛЕТЫ  •  ТЕКУЩИЙ СЕАНС' 24 12 610 21 10 $white $true))
$trafficPanel.Controls.Add((MkLabel 'ВХОДЯЩИЙ ПОТОК' 24 42 280 20 9 $muted))
$trafficPanel.Controls.Add((MkLabel 'ИСХОДЯЩИЙ ПОТОК' 352 42 280 20 9 $muted))
$script:downloadSpeed=MkLabel '—' 24 66 282 32 18 $teal $true
$script:uploadSpeed=MkLabel '—' 352 66 282 32 18 $teal $true
$trafficPanel.Controls.Add($script:downloadSpeed);$trafficPanel.Controls.Add($script:uploadSpeed)
$script:downloadTotal=MkLabel '—' 24 101 282 23 11 $white
$script:uploadTotal=MkLabel '—' 352 101 282 23 11 $white
$trafficPanel.Controls.Add($script:downloadTotal);$trafficPanel.Controls.Add($script:uploadTotal)
$script:trafficNote=New-Object Windows.Forms.Label
$script:trafficNote.Visible=$false

$connect=MkBtn 'ПОДКЛЮЧИТЬ' 24 465 319 45 ([Drawing.Color]::FromArgb(20,123,111))
$disconnect=MkBtn 'ОТКЛЮЧИТЬ' 369 465 319 45 ([Drawing.Color]::FromArgb(129,57,70))
$form.Controls.Add($connect); $form.Controls.Add($disconnect)
$settings=MkBtn 'НАСТРОЙКИ' 24 522 319 43
$deployBtn=MkBtn 'ДЕПЛОЙ' 369 522 319 43
$form.Controls.AddRange(@($settings,$deployBtn))
$script:feedback=New-Object Windows.Forms.Label
$script:feedback.Visible=$true
$script:feedback.Location=[Drawing.Point]::new(24,574)
$script:feedback.Size=[Drawing.Size]::new(516,40)
$script:feedback.ForeColor=$muted
$script:feedback.Font=[Drawing.Font]::new('Segoe UI',9)
$form.Controls.Add($script:feedback)
$script:feedback.BackColor=[Drawing.Color]::Transparent
$logsBtn=MkBtn 'ЛОГИ' 560 574 128 36;$form.Controls.Add($logsBtn)
$logsBtn.Add_Click({
    $logFolder=Join-Path $LetheData 'logs'
    try{
        $last=Get-ChildItem -LiteralPath $logFolder -Filter 'LETHE-*.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $arguments=if($last){'/select,"'+$last.FullName+'"'}else{'"'+$logFolder+'"'}
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $arguments
    }catch{Msg ('Папка журналов: '+$logFolder) 'LETHE: логи'}
})

$script:tray=New-Object Windows.Forms.NotifyIcon
$script:tray.Icon=[Drawing.SystemIcons]::Application
$script:tray.Text='LETHE ONE VPN'
$script:tray.Visible=$true
$menu=New-Object Windows.Forms.ContextMenuStrip
$showMenu=$menu.Items.Add('Показать LETHE')
$stopMenu=$menu.Items.Add('Отключить VPN')
$exitMenu=$menu.Items.Add('Выход с отключением')
$script:tray.ContextMenuStrip=$menu
$script:tray.Add_DoubleClick({ Show-LETHE })
$showMenu.Add_Click({ Show-LETHE })
$stopMenu.Add_Click({ [void](Start-LETHE-Action 'stop') })
$exitMenu.Add_Click({ $script:trayExit=$true; Request-ApplicationExit })
$connect.Add_Click({
    if (Is-Active) { Msg 'Сеанс уже существует. Сначала нажмите ОТКЛЮЧИТЬ.' 'LETHE'; return }
    [void](Start-LETHE-Action 'start')
})
$disconnect.Add_Click({ if (Is-Active) { [void](Start-LETHE-Action 'stop') } else { $script:feedback.Text='LETHE уже отключён.' } })
$settings.Add_Click({ Settings-Form })
$deployBtn.Add_Click({ Deploy-Form })

$form.Add_FormClosing({
    param($sender,$e)
    if ($script:allowClose) { return }
    if ($e.CloseReason -eq [Windows.Forms.CloseReason]::WindowsShutDown) { return }
    $e.Cancel=$true
    if ($script:ui.closeToTray -and -not $script:trayExit) { Hide-LETHE; return }
    Request-ApplicationExit
})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=2200
$timer.Add_Tick({
    try {
        Poll-Action
        $state=Read-Json $script:stateFile
        if ($state -and $state.connected) {
            $naiveAlive=($null -ne (Get-Process -Id ([int]$state.naivePid) -ErrorAction SilentlyContinue))
            $tunAlive=($null -ne (Get-Process -Id ([int]$state.enginePid) -ErrorAction SilentlyContinue))
            if ($naiveAlive -and $tunAlive) {
                $script:statusTitle.Text='ПОДКЛЮЧЕНО'; $script:statusTitle.ForeColor=$teal
            } else {
                $script:statusTitle.Text='ПРОВЕРЬТЕ ДВИЖКИ'; $script:statusTitle.ForeColor=$red
            }
            $uptime=''
            try {
                $elapsed=(Get-Date)-([datetime]::Parse([string]$state.startedAt))
                if ($elapsed.TotalSeconds -ge 0) { $uptime='  |  Сеанс: '+('{0:hh\:mm\:ss}' -f $elapsed) }
            } catch {}
            $script:statusDetail.Text='VPS: '+$state.vpsIp+'  |  Выход: '+$state.exitIp+[Environment]::NewLine+
                'Naive PID: '+$state.naivePid+'  |  sing-box PID: '+$state.enginePid+$uptime
            Refresh-Traffic $state
        } elseif ($state) {
            $script:statusTitle.Text='ПОДКЛЮЧЕНИЕ / ВОССТАНОВЛЕНИЕ'; $script:statusTitle.ForeColor=[Drawing.Color]::Orange
            $script:statusDetail.Text='Этап: '+$state.stage+[Environment]::NewLine+'Naive PID: '+$state.naivePid+'  |  sing-box PID: '+$state.enginePid
            Refresh-Traffic $null
        } else {
            $script:statusTitle.Text='НЕ ПОДКЛЮЧЕНО'; $script:statusTitle.ForeColor=$red
            $script:statusDetail.Text='Система использует обычные маршруты Windows.'
            if($script:lastSession -and -not $script:actionProc){$script:feedback.Text='VPN отключён: сейчас используется прямое подключение к интернету.'}
            Refresh-Traffic $null
        }
    } catch { $script:feedback.Text='Ошибка отображения состояния. Проверьте журналы LETHE.' }
})
$timer.Start()
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    Reset-TrafficClient
    $script:tray.Visible=$false; $script:tray.Dispose(); $menu.Dispose()
    if ($script:guiOwned) { $script:guiMutex.ReleaseMutex() }; $script:guiMutex.Dispose()
})

$form.Add_Shown({ Apply-LetheTheme })
# Run independently of console and optionally hidden in tray.
if ($script:ui.startInTray) {
    $form.Add_Shown({ Hide-LETHE })
}
[Windows.Forms.Application]::Run($form)
