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
$script:appVersion = $GpuDriverToolVersion
$script:gpuAdapters = @()
$script:gpuVendor = ''
$script:gpuPopulating = $false
$script:updateChecking = $false
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
$subtitle.Text = 'Автоматический поиск драйвера AMD / NVIDIA для выбранной видеокарты'
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

    if ($row.Key -eq 'gpu') {
        $script:gpuCombo = [Windows.Forms.ComboBox]::new()
        $script:gpuCombo.Font = $fontBold
        $script:gpuCombo.DropDownStyle = 'DropDownList'
        $script:gpuCombo.FlatStyle = 'Standard'
        $script:gpuCombo.Location = [Drawing.Point]::new(150, ($rowY - 2))
        $script:gpuCombo.Size = [Drawing.Size]::new(506, 24)
        $script:gpuCombo.DropDownHeight = 104
        $script:gpuCombo.Enabled = $false
        $script:gpuCombo.Add_SelectedIndexChanged({
            if ($script:gpuPopulating -or $script:searchPowerShell -or $script:isDownloading -or $script:installProcess) { return }
            if (-not $script:gpuCombo.Enabled) { return }
            Start-Search
        })
        $script:form.Controls.Add($script:gpuCombo)
        $rowY += 27
        continue
    }

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
$script:tip.SetToolTip($script:gpuCombo, 'Выберите видеокарту, если в системе их несколько')

$script:logLink = [Windows.Forms.LinkLabel]::new()
$script:logLink.Text = 'Журнал'
$script:logLink.Font = $font
$script:logLink.LinkColor = $colorMuted
$script:logLink.ActiveLinkColor = $colorAccent
$script:logLink.VisitedLinkColor = $colorMuted
$script:logLink.UseMnemonic = $false
$script:logLink.AutoSize = $false
$script:logLink.TextAlign = 'MiddleRight'
$script:logLink.Location = [Drawing.Point]::new(586, 16)
$script:logLink.Size = [Drawing.Size]::new(70, 20)
$script:logLink.TabStop = $false
$script:form.Controls.Add($script:logLink)
$script:tip.SetToolTip($script:logLink, 'Открыть журнал работы')

$script:versionLink = [Windows.Forms.LinkLabel]::new()
$script:versionLink.Text = "v$script:appVersion"
$script:versionLink.Font = $font
$script:versionLink.LinkColor = $colorMuted
$script:versionLink.ActiveLinkColor = $colorAccent
$script:versionLink.VisitedLinkColor = $colorMuted
$script:versionLink.UseMnemonic = $false
$script:versionLink.AutoSize = $false
$script:versionLink.TextAlign = 'MiddleRight'
$script:versionLink.Location = [Drawing.Point]::new(570, 52)
$script:versionLink.Size = [Drawing.Size]::new(86, 20)
$script:versionLink.TabStop = $false
$script:form.Controls.Add($script:versionLink)
$script:tip.SetToolTip($script:versionLink, 'Проверить обновления')

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

function Open-GuiLog {
    try {
        if (-not (Test-Path -LiteralPath $GpuDriverLogPath)) {
            [Windows.Forms.MessageBox]::Show($script:form, 'Журнал пока пуст.', 'Журнал', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        Start-Process -FilePath (Join-Path $env:WINDIR 'notepad.exe') -ArgumentList ('"{0}"' -f $GpuDriverLogPath)
    } catch {
        [Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, 'Не удалось открыть журнал', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Show-ErrorDialog {
    param([string]$Title, [string]$Message)
    Write-GpuDriverLog 'ERROR' ("UI error: {0}: {1}" -f $Title, $Message)

    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = $Title
    $dialog.ClientSize = [Drawing.Size]::new(560, 292)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = [Drawing.Color]::White
    $dialog.Font = $font
    $dialog.Icon = [Drawing.SystemIcons]::Error

    $messageBox = [Windows.Forms.TextBox]::new()
    $messageBox.Multiline = $true
    $messageBox.ReadOnly = $true
    $messageBox.ScrollBars = 'Vertical'
    $messageBox.BackColor = [Drawing.Color]::White
    $messageBox.BorderStyle = 'FixedSingle'
    $messageBox.Location = [Drawing.Point]::new(20, 20)
    $messageBox.Size = [Drawing.Size]::new(520, 164)
    $messageBox.Text = $Message
    $dialog.Controls.Add($messageBox)

    $hint = [Windows.Forms.Label]::new()
    $hint.Text = "Журнал: $GpuDriverLogPath"
    $hint.ForeColor = $colorMuted
    $hint.AutoSize = $false
    $hint.AutoEllipsis = $true
    $hint.Location = [Drawing.Point]::new(20, 192)
    $hint.Size = [Drawing.Size]::new(520, 18)
    $dialog.Controls.Add($hint)

    $copyButton = [Windows.Forms.Button]::new()
    $copyButton.Text = 'Скопировать ошибку'
    $copyButton.Location = [Drawing.Point]::new(20, 228)
    $copyButton.Size = [Drawing.Size]::new(170, 34)
    $copyButton.FlatStyle = 'System'
    $copyButton.UseVisualStyleBackColor = $true
    $copyButton.Add_Click({
        try {
            [Windows.Forms.Clipboard]::SetText("$Title`r`n$Message`r`n`r`nЖурнал: $GpuDriverLogPath")
            $copyButton.Text = 'Скопировано'
        } catch {
        }
    })
    $dialog.Controls.Add($copyButton)

    $logButton = [Windows.Forms.Button]::new()
    $logButton.Text = 'Открыть журнал'
    $logButton.Location = [Drawing.Point]::new(200, 228)
    $logButton.Size = [Drawing.Size]::new(150, 34)
    $logButton.FlatStyle = 'System'
    $logButton.UseVisualStyleBackColor = $true
    $logButton.Add_Click({ Open-GuiLog })
    $dialog.Controls.Add($logButton)

    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = 'Закрыть'
    $closeButton.Location = [Drawing.Point]::new(410, 228)
    $closeButton.Size = [Drawing.Size]::new(130, 34)
    $closeButton.FlatStyle = 'System'
    $closeButton.UseVisualStyleBackColor = $true
    $closeButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($closeButton)

    $dialog.AcceptButton = $closeButton
    $dialog.CancelButton = $closeButton
    [void]$dialog.ShowDialog($script:form)
    $dialog.Dispose()
}

function Test-Update {
    if ($script:updateChecking) { return }
    $script:updateChecking = $true
    $previousStatus = $script:statusLabel.Text
    $previousColor = $script:statusLabel.ForeColor
    $script:versionLink.Enabled = $false
    $script:form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    Set-Status 'Проверка обновлений...' $colorMuted

    try {
        $release = Get-GpuDriverLatestRelease
        $latestText = $release.Tag -replace '^[vV]', ''
        $isNewer = $false
        try {
            $isNewer = ([version]$latestText) -gt ([version]$script:appVersion)
        } catch {
        }

        if ($isNewer) {
            $message = "Установлена версия v$($script:appVersion).`r`nДоступна новая версия: $($release.Tag).`r`n`r`nОткрыть страницу релиза?"
            $answer = [Windows.Forms.MessageBox]::Show($script:form, $message, 'Доступно обновление', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Information, [Windows.Forms.MessageBoxDefaultButton]::Button1)
            if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
                Start-Process $release.Url
            }
        } else {
            $message = "Установлена последняя версия: v$($script:appVersion)."
            [Windows.Forms.MessageBox]::Show($script:form, $message, 'Обновления', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Write-GpuDriverLog 'INFO' ("Update check: current={0}; latest={1}" -f $script:appVersion, $release.Tag)
    } catch {
        Show-ErrorDialog 'Не удалось проверить обновления' $_.Exception.Message
    } finally {
        $script:updateChecking = $false
        $script:versionLink.Enabled = $true
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        if ($script:statusLabel.Text -eq 'Проверка обновлений...') {
            Set-Status $previousStatus $previousColor
        }
    }
}

function Initialize-GpuSelection {
    if ($script:searchPowerShell) { return }
    $script:form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    Set-Status 'Определение видеокарты...' $colorMuted

    try {
        $adapters = @(Get-GpuAdapterList)
        if ($script:gpuOverride) {
            $match = $adapters | Where-Object { $_.Name -eq $script:gpuOverride -or $_.DisplayName -eq $script:gpuOverride } | Select-Object -First 1
            if (-not $match) {
                $match = Get-GpuController -Name $script:gpuOverride
                $adapters = @($match) + $adapters
            }
            $selected = $match
        } else {
            if ($adapters.Count -eq 0) { throw 'Видеокарта AMD или NVIDIA не найдена.' }
            $selected = $adapters[0]
        }

        $script:gpuAdapters = $adapters
        $script:gpuPopulating = $true
        $script:gpuCombo.Items.Clear()
        foreach ($adapter in $adapters) {
            [void]$script:gpuCombo.Items.Add($adapter.DisplayName)
        }
        $selectedIndex = 0
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            if ($adapters[$i].DisplayName -eq $selected.DisplayName) {
                $selectedIndex = $i
                break
            }
        }
        $script:gpuCombo.SelectedIndex = $selectedIndex
        $script:gpuCombo.Enabled = $true
        $script:gpuPopulating = $false
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        Write-GpuDriverLog 'INFO' ("GPU detection: count={0}; selected={1}" -f $adapters.Count, $selected.DisplayName)
        Start-Search
    } catch {
        $script:gpuPopulating = $false
        $script:gpuCombo.Enabled = $false
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        Set-Status "Ошибка: $($_.Exception.Message)" $colorError
        Write-GpuDriverLog 'ERROR' ("GPU detection failed: " + $_.Exception.Message)
        Show-ErrorDialog 'Ошибка определения видеокарты' $_.Exception.Message
    }
}

function Show-Driver {
    param($Data)
    $driver = $Data.Driver
    $script:driver = $driver
    $script:gpuVendor = $Data.Vendor
    $seconds = if ($script:searchWatch) { $script:searchWatch.Elapsed.TotalSeconds } else { 0 }

    $versionText = if ($driver.Version) { $driver.Version } else { 'н/д' }
    $dateText = if ($driver.ReleaseDate) { $driver.ReleaseDate } else { 'н/д' }
    $sizeText = if ($driver.Size) { $driver.Size } else { 'н/д' }

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
    $script:gpuCombo.Enabled = $true
    $script:form.AcceptButton = $script:btnDownload
    Write-GpuDriverLog 'INFO' ("Driver found: gpu={0}; vendor={1}; driver={2}; version={3}; elapsed={4:N1}s" -f $Data.GpuName, $Data.Vendor, $driver.DriverName, $versionText, $seconds)

    if ($driver.Note) {
        Set-Status $driver.Note $colorWarning
    } else {
        Set-Status ("Драйвер найден за {0:N1} с. Нажмите «Скачать»." -f $seconds) $colorMuted
    }
    [void]$script:btnDownload.Focus()
}

function Start-Search {
    if ($script:searchPowerShell) { return }

    $selectedGpu = $null
    if ($script:gpuCombo -and $script:gpuCombo.SelectedIndex -ge 0 -and $script:gpuAdapters.Count -gt $script:gpuCombo.SelectedIndex) {
        $selectedGpu = $script:gpuAdapters[$script:gpuCombo.SelectedIndex]
    }
    $gpuName = if ($selectedGpu) { $selectedGpu.Name } else { $script:gpuOverride }
    $gpuVendor = if ($selectedGpu) { $selectedGpu.Vendor } else { '' }
    if (-not $gpuName) {
        Initialize-GpuSelection
        return
    }

    $script:driver = $null
    $script:downloadedFile = $null
    $script:isDownloading = $false

    $script:labels['vendor'].Text = '—'
    $script:labels['driver'].Text = '—'
    $script:labels['version'].Text = '—'
    $script:labels['date'].Text = '—'
    $script:labels['size'].Text = '—'
    $script:link.Text = '—'
    $script:gpuCombo.Enabled = $false

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
    Write-GpuDriverLog 'INFO' ("Search started: gpu={0}; vendor={1}" -f $gpuName, $gpuVendor)
    $script:searchWatch = [Diagnostics.Stopwatch]::StartNew()

    $script:searchPowerShell = [PowerShell]::Create()
    $ps = $script:searchPowerShell
    $ps.AddScript({
        param($CorePath, $Name, $Vendor)
        . $CorePath
        if ($Name -and $Vendor) {
            $gpu = [pscustomobject]@{ Name = $Name; Vendor = $Vendor }
        } elseif ($Name) {
            $gpu = Get-GpuController -Name $Name
        } else {
            $gpu = Get-GpuController
        }
        $driver = Get-GpuDriverInfo -Name $gpu.Name -Vendor $gpu.Vendor
        [pscustomobject]@{ GpuName = $gpu.Name; Vendor = $gpu.Vendor; Driver = $driver }
    }) | Out-Null
    $ps.AddArgument($script:corePath) | Out-Null
    $ps.AddArgument($gpuName) | Out-Null
    $ps.AddArgument($gpuVendor) | Out-Null

    try {
        $script:searchHandle = $ps.BeginInvoke()
    } catch {
        $ps.Dispose()
        $script:searchPowerShell = $null
        $script:form.Cursor = [Windows.Forms.Cursors]::Default
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:gpuCombo.Enabled = $true
        Set-Status "Ошибка: $($_.Exception.Message)" $colorError
        Write-GpuDriverLog 'ERROR' ("Search start failed: " + $_.Exception.Message)
        Show-ErrorDialog 'Ошибка поиска драйвера' $_.Exception.Message
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
        $script:btnCheck.Enabled = $true
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status "Ошибка: $message" $colorError
        Write-GpuDriverLog 'ERROR' ("Search failed: " + $message)
        Show-ErrorDialog 'Ошибка поиска драйвера' $message
    } finally {
        if ($ps) { $ps.Dispose() }
    }
}

function Confirm-Install {
    if (-not $script:downloadedFile) { return }
    if (-not (Test-Path -LiteralPath $script:downloadedFile)) {
        Write-GpuDriverLog 'ERROR' ("Downloaded installer missing: " + $script:downloadedFile)
        Show-ErrorDialog 'Файл не найден' 'Файл драйвера не найден. Скачайте его заново.'
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
    $script:gpuCombo.Enabled = $false
    Set-Status 'Запуск установщика (подтвердите запрос UAC)...' $colorMuted
    $script:form.Cursor = [Windows.Forms.Cursors]::AppStarting
    Write-GpuDriverLog 'INFO' ("Installer launch requested: " + $script:downloadedFile)

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
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnInstall
        [void]$script:btnInstall.Focus()
        Set-Status "Установка не запущена: $($_.Exception.Message)" $colorError
        Write-GpuDriverLog 'ERROR' ("Installer launch failed: " + $_.Exception.Message)
        Show-ErrorDialog 'Установка не запущена' $_.Exception.Message
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
        $script:gpuCombo.Enabled = $true
        Set-Status 'Установщик запущен. Автоматическое отслеживание недоступно — дождитесь завершения и перезагрузите ПК.' $colorWarning
        Write-GpuDriverLog 'WARN' 'Installer tracking unavailable'
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
    $script:gpuCombo.Enabled = $true
    $script:form.AcceptButton = $script:btnClose
    $script:form.Cursor = [Windows.Forms.Cursors]::Default

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        Set-Status "Установщик завершён с кодом $exitCode. Проверьте журнал установки AMD/NVIDIA." $colorWarning
        Write-GpuDriverLog 'WARN' ("Installer exited: code={0}" -f $exitCode)
    } else {
        Set-Status 'Установщик завершён. Если мастер установки ещё открыт, завершите его и перезагрузите компьютер.' $colorSuccess
        Write-GpuDriverLog 'INFO' 'Installer completed successfully'
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
            try {
                $signature = Assert-DriverInstallerSignature -Path $filePath -Vendor $script:gpuVendor
            } catch {
                $script:downloadedFile = $null
                $script:btnInstall.Enabled = $false
                $script:btnOpen.Enabled = $false
                Set-Status 'Файл отклонён: подпись не прошла проверку. Скачайте заново.' $colorError
                Show-ErrorDialog 'Проверка подписи не пройдена' $_.Exception.Message
                return
            }
            $script:downloadedFile = $filePath
            $script:progress.Style = 'Continuous'
            $script:progress.Value = 100
            $script:btnCheck.Enabled = $true
            $script:btnDownload.Enabled = $true
            $script:btnInstall.Enabled = $true
            $script:btnOpen.Enabled = $true
            $script:form.AcceptButton = $script:btnInstall
            [void]$script:btnInstall.Focus()
            Set-Status ("Файл уже скачан: {0} · подпись: {1}" -f $filePath, $signature.SignerName) $colorSuccess
            Write-GpuDriverLog 'INFO' ("Existing installer accepted: " + $filePath)
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
    $script:gpuCombo.Enabled = $false
    $script:form.AcceptButton = $script:btnDownload
    Set-Status 'Подготовка к скачиванию...' $colorMuted
    Write-GpuDriverLog 'INFO' ("Download started: " + $script:driver.Url)
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
        $responseStream = $null
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
            $responseStream = $response.GetResponseStream()
            $output = [IO.File]::Create($TempPath)
            $buffer = New-Object byte[] 81920
            $received = [long]0
            while ($true) {
                if ($State.Cancelled) { break }
                $read = $responseStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $output.Write($buffer, 0, $read)
                $received += $read
                $State.Received = $received
            }
            $output.Close()
            $output = $null
            $responseStream.Close()
            $responseStream = $null
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
            if ($responseStream) { try { $responseStream.Close() } catch { } }
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
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status "Ошибка: $($_.Exception.Message)" $colorError
        Write-GpuDriverLog 'ERROR' ("Download start failed: " + $_.Exception.Message)
        Show-ErrorDialog 'Ошибка скачивания' $_.Exception.Message
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
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        if ($state.Error -eq 'Отменено пользователем.') {
            Set-Status 'Скачивание отменено. Файл не сохранён.' $colorWarning
            Write-GpuDriverLog 'WARN' 'Download cancelled by user'
        } else {
            Set-Status "Ошибка скачивания: $($state.Error)" $colorError
            Write-GpuDriverLog 'ERROR' ("Download failed: " + $state.Error)
            Show-ErrorDialog 'Ошибка скачивания' $state.Error
        }
        return
    }

    if (-not $state.Path -or -not (Test-Path -LiteralPath $state.Path)) {
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status 'Ошибка: файл не был сохранён.' $colorError
        Write-GpuDriverLog 'ERROR' 'Download finished without a file'
        Show-ErrorDialog 'Ошибка скачивания' 'Файл не был сохранён.'
        return
    }

    $downloadedPath = $state.Path
    try {
        $signature = Assert-DriverInstallerSignature -Path $downloadedPath -Vendor $script:gpuVendor
    } catch {
        $script:downloadedFile = $null
        $script:progress.Style = 'Continuous'
        $script:progress.Value = 0
        $script:btnCheck.Enabled = $true
        $script:btnInstall.Enabled = $false
        $script:btnOpen.Enabled = $false
        $script:gpuCombo.Enabled = $true
        $script:form.AcceptButton = $script:btnCheck
        [void]$script:btnCheck.Focus()
        Set-Status 'Файл отклонён: подпись не прошла проверку. Скачайте заново.' $colorError
        Show-ErrorDialog 'Проверка подписи не пройдена' $_.Exception.Message
        return
    }

    $script:downloadedFile = $downloadedPath
    $script:progress.Style = 'Continuous'
    $script:progress.Value = 100
    $elapsed = $script:downloadWatch.Elapsed
    $sizeText = '{0:N0} МБ' -f ((Get-Item -LiteralPath $script:downloadedFile).Length / 1MB)
    Set-Status ("Скачано: {0} за {1:hh\:mm\:ss} · подпись: {2}.`r`nФайл сохранён в «Загрузки»." -f $sizeText, $elapsed, $signature.SignerName) $colorSuccess
    $script:btnCheck.Enabled = $true
    $script:btnInstall.Enabled = $true
    $script:btnOpen.Enabled = $true
    $script:gpuCombo.Enabled = $true
    $script:form.AcceptButton = $script:btnInstall
    [void]$script:btnInstall.Focus()
    Write-GpuDriverLog 'INFO' ("Download completed: size={0} MB; signer={1}; file={2}" -f $sizeText, $signature.SignerName, $script:downloadedFile)
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
$script:logLink.Add_LinkClicked({ Open-GuiLog })
$script:versionLink.Add_LinkClicked({ Test-Update })
$script:form.Add_Shown({ Initialize-GpuSelection })
$script:form.Add_FormClosing({
    Write-GpuDriverLog 'INFO' 'GUI closing'
    $script:searchTimer.Stop()
    $script:downloadTimer.Stop()
    $script:installTimer.Stop()
    if ($script:downloadState) {
        try { $script:downloadState.Cancelled = $true } catch { }
    }
    if ($script:downloadPowerShell) {
        try { $script:downloadPowerShell.Stop() } catch { }
    }
    if ($script:searchPowerShell) {
        try { $script:searchPowerShell.Stop() } catch { }
    }
    if ($script:downloadTemp -and (Test-Path -LiteralPath $script:downloadTemp)) {
        try { Remove-Item -LiteralPath $script:downloadTemp -Force } catch { }
    }
})

Write-GpuDriverLog 'INFO' ("GUI started: version={0}; OS={1}" -f $script:appVersion, [Environment]::OSVersion.VersionString)
[Windows.Forms.Application]::Run($script:form)
Write-GpuDriverLog 'INFO' 'GUI stopped'
$script:form.Dispose()

