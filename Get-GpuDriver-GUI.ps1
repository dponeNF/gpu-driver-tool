#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GpuName
)

$ErrorActionPreference = 'Stop'
$script:corePath = Join-Path $PSScriptRoot 'GpuDriverCore.ps1'
. $script:corePath

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:gpuOverride = $GpuName
$script:driver = $null
$script:downloadedFile = $null
$script:downloadPowerShell = $null
$script:downloadHandle = $null
$script:downloadState = $null
$script:downloadTemp = $null
$script:downloadPath = $null
$script:isDownloading = $false
$script:installProcess = $null
$script:searchPowerShell = $null
$script:searchHandle = $null
$script:searchWatch = $null
$script:downloadWatch = $null

$colorText = [Drawing.Color]::FromArgb(32, 32, 32)
$colorMuted = [Drawing.Color]::FromArgb(100, 100, 100)
$colorLine = [Drawing.Color]::FromArgb(226, 226, 226)
$colorAccent = [Drawing.Color]::FromArgb(0, 90, 158)
$colorError = [Drawing.Color]::FromArgb(196, 43, 28)
$colorSuccess = [Drawing.Color]::FromArgb(16, 124, 16)
$colorWarning = [Drawing.Color]::FromArgb(157, 93, 0)

$font = [Drawing.Font]::new('Segoe UI', 9)
$fontBold = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$fontTitle = [Drawing.Font]::new('Segoe UI', 15.75, [Drawing.FontStyle]::Bold)

$script:form = [Windows.Forms.Form]::new()
$script:form.Text = 'Драйвер видеокарты'
$script:form.ClientSize = [Drawing.Size]::new(680, 452)
$script:form.StartPosition = 'CenterScreen'
$script:form.FormBorderStyle = 'FixedSingle'
$script:form.MaximizeBox = $false
$script:form.BackColor = [Drawing.Color]::White
$script:form.Font = $font
$script:form.Icon = [Drawing.SystemIcons]::Application

$title = [Windows.Forms.Label]::new()
$title.Text = 'Драйвер видеокарты'
$title.Font = $fontTitle
$title.ForeColor = $colorText
$title.UseMnemonic = $false
$title.AutoSize = $true
$title.Location = [Drawing.Point]::new(24, 16)
$script:form.Controls.Add($title)

$subtitle = [Windows.Forms.Label]::new()
$subtitle.Text = 'Автоматический поиск драйвера AMD / NVIDIA для текущей видеокарты'
$subtitle.Font = $font
$subtitle.ForeColor = $colorMuted
$subtitle.UseMnemonic = $false
$subtitle.AutoSize = $true
$subtitle.Location = [Drawing.Point]::new(24, 52)
$script:form.Controls.Add($subtitle)

function Add-Separator {
    param([int]$Y)
    $panel = [Windows.Forms.Panel]::new()
    $panel.BackColor = $colorLine
    $panel.Location = [Drawing.Point]::new(24, $Y)
    $panel.Size = [Drawing.Size]::new(632, 1)
    $script:form.Controls.Add($panel)
}
Add-Separator 82

$script:labels = @{}
$rows = @(
    @{ Key = 'gpu';     Caption = 'Видеокарта';    Bold = $true  },
    @{ Key = 'vendor';  Caption = 'Производитель'; Bold = $false },
    @{ Key = 'driver';  Caption = 'Драйвер';       Bold = $false },
    @{ Key = 'version'; Caption = 'Версия';        Bold = $false },
    @{ Key = 'date';    Caption = 'Дата выпуска';  Bold = $false },
    @{ Key = 'size';    Caption = 'Размер';        Bold = $false }
)
$rowY = 100
foreach ($row in $rows) {
    $caption = [Windows.Forms.Label]::new()
    $caption.Text = $row.Caption
    $caption.ForeColor = $colorMuted
    $caption.UseMnemonic = $false
    $caption.AutoSize = $false
    $caption.TextAlign = 'MiddleLeft'
    $caption.Location = [Drawing.Point]::new(24, $rowY)
    $caption.Size = [Drawing.Size]::new(120, 22)
    $script:form.Controls.Add($caption)

    $value = [Windows.Forms.Label]::new()
    $value.Text = '—'
    $value.ForeColor = $colorText
    $value.Font = if ($row.Bold) { $fontBold } else { $font }
    $value.UseMnemonic = $false
    $value.AutoSize = $false
    $value.AutoEllipsis = $true
    $value.TextAlign = 'MiddleLeft'
    $value.Location = [Drawing.Point]::new(150, $rowY)
    $value.Size = [Drawing.Size]::new(506, 22)
    $script:form.Controls.Add($value)
    $script:labels[$row.Key] = $value
    $rowY += 27
}

$captionLink = [Windows.Forms.Label]::new()
$captionLink.Text = 'Ссылка'
$captionLink.ForeColor = $colorMuted
$captionLink.UseMnemonic = $false
$captionLink.AutoSize = $false
$captionLink.TextAlign = 'MiddleLeft'
$captionLink.Location = [Drawing.Point]::new(24, 262)
$captionLink.Size = [Drawing.Size]::new(120, 22)
$script:form.Controls.Add($captionLink)

$script:link = [Windows.Forms.LinkLabel]::new()
$script:link.Text = '—'
$script:link.Font = $font
$script:link.LinkColor = $colorAccent
$script:link.ActiveLinkColor = [Drawing.Color]::FromArgb(0, 60, 110)
$script:link.VisitedLinkColor = $colorAccent
$script:link.UseMnemonic = $false
$script:link.AutoSize = $false
$script:link.AutoEllipsis = $true
$script:link.TextAlign = 'MiddleLeft'
$script:link.Location = [Drawing.Point]::new(150, 262)
$script:link.Size = [Drawing.Size]::new(506, 22)
$script:form.Controls.Add($script:link)

$script:tip = [Windows.Forms.ToolTip]::new()
$script:tip.SetToolTip($script:link, 'Открыть страницу загрузки драйвера')

Add-Separator 296

$script:progress = [Windows.Forms.ProgressBar]::new()
$script:progress.Location = [Drawing.Point]::new(24, 310)
$script:progress.Size = [Drawing.Size]::new(632, 18)
$script:progress.Minimum = 0
$script:progress.Maximum = 100
$script:progress.Value = 0
$script:progress.Style = 'Continuous'
$script:form.Controls.Add($script:progress)

$script:statusLabel = [Windows.Forms.Label]::new()
$script:statusLabel.Text = 'Определение видеокарты...'
$script:statusLabel.ForeColor = $colorMuted
$script:statusLabel.UseMnemonic = $false
$script:statusLabel.AutoSize = $false
$script:statusLabel.TextAlign = 'TopLeft'
$script:statusLabel.Location = [Drawing.Point]::new(24, 334)
$script:statusLabel.Size = [Drawing.Size]::new(632, 38)
$script:form.Controls.Add($script:statusLabel)

Add-Separator 384

function New-Button {
    param([string]$Text, [int]$X, [int]$Width)
    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Font = $font
    $button.FlatStyle = 'System'
    $button.UseVisualStyleBackColor = $true
    $button.Location = [Drawing.Point]::new($X, 398)
    $button.Size = [Drawing.Size]::new($Width, 32)
    $script:form.Controls.Add($button)
    return $button
}

$script:btnCheck = New-Button 'Проверить' 24 110
$script:btnDownload = New-Button 'Скачать' 144 120
$script:btnInstall = New-Button 'Установить' 274 130
$script:btnOpen = New-Button 'Открыть папку' 414 130
$script:btnClose = New-Button 'Закрыть' 554 102
$script:btnCheck.TabIndex = 1
$script:btnDownload.TabIndex = 2
$script:btnInstall.TabIndex = 3
$script:btnOpen.TabIndex = 4
$script:btnClose.TabIndex = 5

$script:btnDownload.Enabled = $false
$script:btnInstall.Enabled = $false
$script:btnOpen.Enabled = $false
$script:form.AcceptButton = $script:btnCheck
$script:form.CancelButton = $script:btnClose

$script:searchTimer = [Windows.Forms.Timer]::new()
$script:searchTimer.Interval = 250
$script:installTimer = [Windows.Forms.Timer]::new()
$script:installTimer.Interval = 500
$script:downloadTimer = [Windows.Forms.Timer]::new()
$script:downloadTimer.Interval = 200

function Set-Status {
    param([string]$Text, $Color)
    $script:statusLabel.Text = $Text
    if ($null -ne $Color) { $script:statusLabel.ForeColor = $Color }
    else { $script:statusLabel.ForeColor = $colorText }
}

function Show-Driver {
    param($Data)
    $driver = $Data.Driver
    $script:driver = $driver
    $seconds = if ($script:searchWatch) { $script:searchWatch.Elapsed.TotalSeconds } else { 0 }

    $versionText = if ($driver.Version) { $driver.Version } else { 'н/д' }
    $dateText = if ($driver.ReleaseDate) { $driver.ReleaseDate } else { 'н/д' }
    $sizeText = if ($driver.Size) { $driver.Size } else { 'н/д' }

    $script:labels['gpu'].Text = $Data.GpuName
    $script:labels['vendor'].Text = $Data.Vendor
    $script:labels['driver'].Text = $driver.DriverName
    $script:labels['version'].Text = $versionText
    $script:labels['date'].Text = $dateText
    $script:labels['size'].Text = $sizeText
    $script:link.Text = $driver.Url
    $script:tip.SetToolTip($script:link, $driver.Url)

    $script:progress.Style = 'Continuous'
    $script:progress.Value = 0
    $script:btnCheck.Enabled = $true
    $script:btnDownload.Enabled = $true
    $script:btnInstall.Enabled = $false
    $script:btnOpen.Enabled = $false
    $script:form.AcceptButton = $script:btnDownload

    if ($driver.Note) {
        Set-Status $driver.Note $colorWarning
    } else {
        Set-Status ("Драйвер найден за {0:N1} с. Нажмите «Скачать»." -f $seconds) $colorMuted
    }
    [void]$script:btnDownload.Focus()
}

function Start-Search {
    if ($script:searchPowerShell) { return }

    $script:driver = $null
    $script:downloadedFile = $null
    $script:isDownloading = $false

    $script:labels['gpu'].Text = 'Определение...'
    $script:labels['vendor'].Text = '—'
    $script:labels['driver'].Text = '—'
    $script:labels['version'].Text = '—'
    $script:labels['date'].Text = '—'
    $script:labels['size'].Text = '—'
    $script:link.Text = '—'

    $script:progress.Style = 'Marquee'
    $script:progress.MarqueeAnimationSpeed = 25
    $script:btnCheck.Enabled = $false
    $script:btnDownload.Text = 'Скачать'
    $script:btnDownload.Enabled = $false
    $script:btnInstall.Enabled = $false
    $script:btnOpen.Enabled = $false
    $script:form.AcceptButton = $script:btnCheck
    $script:form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    Set-Status 'Поиск драйвера...' $colorMuted
    $script:searchWatch = [Diagnostics.Stopwatch]::StartNew()

    $script:searchPowerShell = [PowerShell]::Create()
    $ps = $script:searchPowerShell
    $ps.AddScript({
        param($CorePath, $Name)
        . $CorePath
        $gpu = Get-GpuController -Name $Name
        $driver = Get-GpuDriverInfo -Name $gpu.Name
        [pscustomobject]@{ GpuName = $gpu.Name; Vendor = $gpu.Vendor; Driver = $driver }
    }) | Out-Null
    $ps.AddArgument($script:corePath) | Out-Null
    $ps.AddArgument($script:gpuOverride) | Out-Null

    try {
        $script:searchHandle = $ps.BeginInvoke()
    } catch {
        $ps.Dispose()
        $script:searchPowerShell = $null
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        Set-Status "Ошибка: $($_.Exception.Message)" $colorError
        return
    }
    $script:searchTimer.Start()
}

function Search-Tick {
    if (-not $script:searchHandle -or -not $script:searchHandle.IsCompleted) { return }
    $script:searchTimer.Stop()
    if ($script:searchWatch) { $script:searchWatch.Stop() }
    $script:form.Cursor = [Windows.Forms.Cursors]::Default

    $ps = $script:searchPowerShell
    $handle = $script:searchHandle
    $script:searchPowerShell = $null
    $script:searchHandle = $null

    try {
        $results = @($ps.EndInvoke($handle))
        $streamError = $ps.Streams.Error | Select-Object -First 1
        if ($streamError) { throw $streamError }
        $data = $results | Where-Object { $_ -and $_.PSObject.Properties['Driver'] } | Select-Object -Last 1
        if (-not $data) { throw 'Не удалось получить данные о драйвере.' }
        Show-Driver $data
    } catch {
        $message = $_.Exception.Message
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
            $message = $_.Exception.InnerException.Message
        }
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:labels['gpu'].Text = 'Не определена'
        $script:btnCheck.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status "Ошибка: $message" $colorError
        [Windows.Forms.MessageBox]::Show($script:form, $message, 'Ошибка поиска драйвера', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        if ($ps) { $ps.Dispose() }
    }
}

function Confirm-Install {
    if (-not $script:downloadedFile) { return }
    if (-not (Test-Path -LiteralPath $script:downloadedFile)) {
        [Windows.Forms.MessageBox]::Show($script:form, 'Файл драйвера не найден. Скачайте его заново.', 'Ошибка', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        $script:downloadedFile = $null
        $script:btnInstall.Enabled = $false
        $script:btnOpen.Enabled = $false
        return
    }
    $message = "Драйвер скачан:`r`n$($script:downloadedFile)`r`n`r`nЗапустить установку сейчас?"
    $answer = [Windows.Forms.MessageBox]::Show($script:form, $message, 'Установка драйвера', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) { Start-Install }
}

function Start-Install {
    if (-not $script:downloadedFile) { return }

    $script:progress.Style = 'Marquee'
    $script:progress.MarqueeAnimationSpeed = 25
    $script:btnCheck.Enabled = $false
    $script:btnDownload.Enabled = $false
    $script:btnInstall.Enabled = $false
    $script:btnOpen.Enabled = $false
    Set-Status 'Запуск установщика (подтвердите запрос UAC)...' $colorMuted
    $script:form.Cursor = [Windows.Forms.Cursors]::AppStarting

    try {
        $script:installProcess = Start-Process -FilePath $script:downloadedFile -WorkingDirectory (Split-Path -Parent $script:downloadedFile) -Verb RunAs -PassThru
    } catch {
        $script:installProcess = $null
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:btnDownload.Enabled = $true
        $script:btnInstall.Enabled = $true
        $script:btnOpen.Enabled = $true
        $script:form.AcceptButton = $script:btnInstall
        [void]$script:btnInstall.Focus()
        Set-Status "Установка не запущена: $($_.Exception.Message)" $colorError
        [Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, 'Установка не запущена', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $script:form.Cursor = [Windows.Forms.Cursors]::Default
    Set-Status 'Установщик запущен. Идёт установка — прогресс показан в окне установщика.' $colorMuted
    $script:installTimer.Start()
}

function Install-Tick {
    if (-not $script:installProcess) {
        $script:installTimer.Stop()
        return
    }
    $exited = $false
    try {
        $exited = $script:installProcess.HasExited
    } catch {
        $script:installTimer.Stop()
        $script:installProcess = $null
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        $script:progress.Style = 'Continuous'
        $script:btnCheck.Enabled = $true
        $script:btnDownload.Enabled = $true
        $script:btnInstall.Enabled = $true
        $script:btnOpen.Enabled = $true
        Set-Status 'Установщик запущен. Автоматическое отслеживание недоступно — дождитесь завершения и перезагрузите ПК.' $colorWarning
        return
    }
    if (-not $exited) { return }

    $script:installTimer.Stop()
    $exitCode = $null
    try { $exitCode = $script:installProcess.ExitCode } catch { }
    $script:installProcess.Dispose()
    $script:installProcess = $null

    $script:progress.Style = 'Continuous'
    $script:progress.Value = 100
    $script:btnCheck.Enabled = $true
    $script:btnDownload.Enabled = $true
    $script:btnInstall.Enabled = $true
    $script:btnOpen.Enabled = $true
    $script:form.AcceptButton = $script:btnClose
    $script:form.Cursor = [Windows.Forms.Cursors]::Default

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        Set-Status "Установщик завершён с кодом $exitCode. Проверьте журнал установки AMD/NVIDIA." $colorWarning
    } else {
        Set-Status 'Установщик завершён. Если мастер установки ещё открыт, завершите его и перезагрузите компьютер.' $colorSuccess
    }
}

function Start-Download {
    if (-not $script:driver -or $script:installProcess) { return }

    $outDir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $fileName = [IO.Path]::GetFileName(([Uri]$script:driver.Url).AbsolutePath)
    $filePath = Join-Path $outDir $fileName

    if (Test-Path -LiteralPath $filePath) {
        $answer = [Windows.Forms.MessageBox]::Show($script:form, "Файл уже существует:`r`n$filePath`r`n`r`nСкачать его заново?", 'Файл уже скачан', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $script:downloadedFile = $filePath
            $script:progress.Style = 'Continuous'
            $script:progress.Value = 100
            $script:btnInstall.Enabled = $true
            $script:btnOpen.Enabled = $true
            $script:form.AcceptButton = $script:btnInstall
            [void]$script:btnInstall.Focus()
            Set-Status "Файл уже скачан: $filePath" $colorSuccess
            return
        }
        Remove-Item -LiteralPath $filePath -Force
    }

    $script:downloadPath = $filePath
    $script:downloadTemp = "$filePath.part"
    if (Test-Path -LiteralPath $script:downloadTemp) { Remove-Item -LiteralPath $script:downloadTemp -Force }

    $script:progress.Style = 'Continuous'
    $script:progress.Value = 0
    $script:btnCheck.Enabled = $false
    $script:btnDownload.Enabled = $true
    $script:btnDownload.Text = 'Отмена'
    $script:btnInstall.Enabled = $false
    $script:btnOpen.Enabled = $false
    $script:form.AcceptButton = $script:btnDownload
    Set-Status 'Подготовка к скачиванию...' $colorMuted
    $script:isDownloading = $true
    $script:downloadWatch = [Diagnostics.Stopwatch]::StartNew()

    $state = [hashtable]::Synchronized(@{
        Received  = [long]0
        Total     = [long]0
        Done      = $false
        Cancelled = $false
        Error     = ''
        Path      = ''
    })
    $script:downloadState = $state
    Set-Status 'Подключение к серверу...' $colorMuted

    $ps = [PowerShell]::Create()
    $ps.AddScript({
        param($Url, $TempPath, $FinalPath, $State, $Agent)
        $ErrorActionPreference = 'Stop'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = $null
        $input = $null
        $output = $null
        try {
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.UserAgent = $Agent
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 120000
            $request.AllowAutoRedirect = $true
            $response = $request.GetResponse()
            $total = [long]$response.ContentLength
            $State.Total = 0
            if ($total -gt 0) { $State.Total = $total }
            $input = $response.GetResponseStream()
            $output = [IO.File]::Create($TempPath)
            $buffer = New-Object byte[] 81920
            $received = [long]0
            while ($true) {
                if ($State.Cancelled) { break }
                $read = $input.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $output.Write($buffer, 0, $read)
                $received += $read
                $State.Received = $received
            }
            $output.Close()
            $output = $null
            $input.Close()
            $input = $null
            $response.Close()
            $response = $null

            if ($State.Cancelled) {
                if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue }
                $State.Error = 'Отменено пользователем.'
                return
            }
            if ($State.Total -gt 0 -and $received -ne $State.Total) {
                throw "Скачано $received из $($State.Total) байт — соединение прервано."
            }
            $length = (Get-Item -LiteralPath $TempPath).Length
            if ($length -lt 1MB) {
                Remove-Item -LiteralPath $TempPath -Force
                throw "Файл слишком мал ($length байт) — возможно, сервер вернул ошибку."
            }
            Move-Item -LiteralPath $TempPath -Destination $FinalPath -Force
            $State.Path = $FinalPath
        } catch {
            $State.Error = $_.Exception.Message
            if (Test-Path -LiteralPath $TempPath) {
                try { Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue } catch { }
            }
        } finally {
            if ($output) { try { $output.Close() } catch { } }
            if ($input) { try { $input.Close() } catch { } }
            if ($response) { try { $response.Close() } catch { } }
            $State.Done = $true
        }
    }) | Out-Null
    $ps.AddArgument($script:driver.Url) | Out-Null
    $ps.AddArgument($script:downloadTemp) | Out-Null
    $ps.AddArgument($script:downloadPath) | Out-Null
    $ps.AddArgument($state) | Out-Null
    $ps.AddArgument($userAgent) | Out-Null

    $script:downloadPowerShell = $ps
    try {
        $script:downloadHandle = $ps.BeginInvoke()
        $script:downloadTimer.Start()
    } catch {
        $script:downloadPowerShell = $null
        $script:downloadState = $null
        $ps.Dispose()
        $script:isDownloading = $false
        $script:btnDownload.Text = 'Скачать'
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:btnDownload.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status "Ошибка: $($_.Exception.Message)" $colorError
    }
}

function Download-Tick {
    $state = $script:downloadState
    if (-not $state) {
        $script:downloadTimer.Stop()
        return
    }

    if (-not $state.Done) {
        if ($state.Total -gt 0) {
            $pct = [int][Math]::Floor(($state.Received * 100.0) / $state.Total)
            if ($pct -gt 100) { $pct = 100 }
            $script:progress.Value = $pct
            $receivedMb = [Math]::Round($state.Received / 1MB, 1)
            $totalMb = [Math]::Round($state.Total / 1MB, 1)
            Set-Status ("Скачивание: {0}% ({1} из {2} МБ)" -f $pct, $receivedMb, $totalMb) $colorMuted
        } else {
            $receivedMb = [Math]::Round($state.Received / 1MB, 1)
            Set-Status ("Скачивание: {0} МБ" -f $receivedMb) $colorMuted
        }
        return
    }

    $script:downloadTimer.Stop()
    if ($script:downloadWatch) { $script:downloadWatch.Stop() }
    $ps = $script:downloadPowerShell
    $handle = $script:downloadHandle
    $script:downloadPowerShell = $null
    $script:downloadHandle = $null
    $script:downloadState = $null
    $script:isDownloading = $false
    $script:btnDownload.Text = 'Скачать'
    $script:btnDownload.Enabled = $true

    try {
        if ($ps -and $handle) { [void]$ps.EndInvoke($handle) }
    } catch {
        if (-not $state.Error) { $state.Error = $_.Exception.Message }
    } finally {
        if ($ps) { $ps.Dispose() }
    }

    if ($state.Error) {
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        if ($state.Error -eq 'Отменено пользователем.') {
            Set-Status 'Скачивание отменено. Файл не сохранён.' $colorWarning
        } else {
            Set-Status "Ошибка скачивания: $($state.Error)" $colorError
            [Windows.Forms.MessageBox]::Show($script:form, $state.Error, 'Ошибка скачивания', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        return
    }

    if (-not $state.Path -or -not (Test-Path -LiteralPath $state.Path)) {
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status 'Ошибка: файл не был сохранён.' $colorError
        return
    }

    $script:downloadedFile = $state.Path
    $script:progress.Style = 'Continuous'
    $script:progress.Value = 100
    $elapsed = $script:downloadWatch.Elapsed
    $sizeText = '{0:N0} МБ' -f ((Get-Item -LiteralPath $script:downloadedFile).Length / 1MB)
    Set-Status ("Скачано: {0} ({1}) за {2:hh\:mm\:ss}. Файл сохранён в «Загрузки»." -f $script:downloadedFile, $sizeText, $elapsed) $colorSuccess
    $script:btnCheck.Enabled = $true
    $script:btnInstall.Enabled = $true
    $script:btnOpen.Enabled = $true
    $script:form.AcceptButton = $script:btnInstall
    [void]$script:btnInstall.Focus()
    Confirm-Install
}

$script:searchTimer.Add_Tick({ Search-Tick })
$script:installTimer.Add_Tick({ Install-Tick })
$script:downloadTimer.Add_Tick({ Download-Tick })

$script:btnCheck.Add_Click({ Start-Search })
$script:btnDownload.Add_Click({
    if ($script:isDownloading) {
        if ($script:downloadState) {
            $script:downloadState.Cancelled = $true
            $script:btnDownload.Enabled = $false
            Set-Status 'Отмена скачивания...' $colorWarning
        }
        return
    }
    Start-Download
})
$script:btnInstall.Add_Click({ Confirm-Install })
$script:btnOpen.Add_Click({
    if (-not $script:downloadedFile -and $script:driver) {
        $outDir = Join-Path $env:USERPROFILE 'Downloads'
        $fileName = [IO.Path]::GetFileName(([Uri]$script:driver.Url).AbsolutePath)
        $script:downloadedFile = Join-Path $outDir $fileName
    }
    if ($script:downloadedFile) {
        $folder = Split-Path -Parent $script:downloadedFile
        if (Test-Path -LiteralPath $folder) {
            Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:downloadedFile)
        }
    }
})
$script:btnClose.Add_Click({ $script:form.Close() })
$script:link.Add_LinkClicked({
    param($sender, $e)
    if ($script:driver -and $script:driver.Url) {
        try { Start-Process $script:driver.Url } catch { }
    }
})
$script:form.Add_Shown({ Start-Search })
$script:form.Add_FormClosing({
    if ($script:downloadState) {
        try { $script:downloadState.Cancelled = $true } catch { }
    }
    if ($script:downloadPowerShell) {
        try { $script:downloadPowerShell.Stop() } catch { }
    }
    if ($script:downloadTemp -and (Test-Path -LiteralPath $script:downloadTemp)) {
        try { Remove-Item -LiteralPath $script:downloadTemp -Force } catch { }
    }
})

[Windows.Forms.Application]::Run($script:form)
$script:form.Dispose()
