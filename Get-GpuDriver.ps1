#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'Downloads'),
    [string]$GpuName,
    [switch]$DryRun,
    [switch]$NoInstall,
    [switch]$Force,
    [switch]$ListGpus,
    [switch]$CheckUpdate
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GpuDriverCore.ps1')

try {
    Write-Host "GPU Driver Tool v$GpuDriverToolVersion" -ForegroundColor Cyan
    Write-Host ''
    Write-GpuDriverLog 'INFO' ("CLI started: version={0}; arguments={1}" -f $GpuDriverToolVersion, ($PSBoundParameters.Keys -join ','))

    if ($CheckUpdate) {
        Write-Host 'Проверка обновлений...'
        $release = Get-GpuDriverLatestRelease
        $latestText = $release.Tag -replace '^[vV]', ''
        $isNewer = $false
        try {
            $isNewer = ([version]$latestText) -gt ([version]$GpuDriverToolVersion)
        } catch {
        }
        if ($isNewer) {
            Write-Host "Доступна новая версия: $($release.Tag)" -ForegroundColor Yellow
            Write-Host "Страница релиза: $($release.Url)"
        } else {
            Write-Host "Установлена последняя версия: v$GpuDriverToolVersion" -ForegroundColor Green
        }
        Write-GpuDriverLog 'INFO' ("Update check: current={0}; latest={1}" -f $GpuDriverToolVersion, $release.Tag)
        exit 0
    }

    if ($ListGpus) {
        $adapters = @(Get-GpuAdapterList)
        if ($adapters.Count -eq 0) { throw 'Видеокарта AMD или NVIDIA не найдена.' }
        Write-Host 'Найденные видеокарты:'
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            $marker = if ($i -eq 0) { '*' } else { ' ' }
            Write-Host (" {0} {1}" -f $marker, $adapters[$i].DisplayName)
        }
        Write-Host ''
        Write-Host 'Для выбора другой карты используйте -GpuName "<название>".' -ForegroundColor DarkGray
        exit 0
    }

    $gpu = Get-GpuController -Name $GpuName
    $vendor = $gpu.Vendor
    $pciText = 'н/д'
    if ($gpu.PciVendorId) {
        $pciText = $gpu.PciVendorId
        if ($gpu.PciDeviceId) { $pciText = "$pciText`:$($gpu.PciDeviceId)" }
    }

    Write-Host "Видеокарта    : $($gpu.Name)"
    Write-Host "Производитель : $vendor"
    Write-Host "PCI ID        : $pciText"
    Write-Host 'Поиск драйвера...'
    Write-GpuDriverLog 'INFO' ("Search started: gpu={0}; vendor={1}; pci={2}" -f $gpu.Name, $vendor, $pciText)

    $lookupTimer = [Diagnostics.Stopwatch]::StartNew()
    $driver = Get-GpuDriverInfo -Name $gpu.Name -Vendor $vendor
    $lookupTimer.Stop()

    $versionText = if ($driver.Version) { $driver.Version } else { 'н/д' }
    $dateText = if ($driver.ReleaseDate) { $driver.ReleaseDate } else { 'н/д' }

    Write-Host "Драйвер       : $($driver.DriverName)" -ForegroundColor Cyan
    Write-Host "Версия        : $versionText"
    Write-Host "Дата выпуска  : $dateText"
    if ($driver.Size) { Write-Host "Размер        : $($driver.Size)" }
    Write-Host "Ссылка        : $($driver.Url)"
    Write-Host ("Поиск занял    : {0:N1} с" -f $lookupTimer.Elapsed.TotalSeconds)
    if ($driver.Note) { Write-Host $driver.Note -ForegroundColor Yellow }
    Write-GpuDriverLog 'INFO' ("Search completed: driver={0}; version={1}; elapsed={2:N1}s" -f $driver.DriverName, $versionText, $lookupTimer.Elapsed.TotalSeconds)

    if ($DryRun) {
        Write-Host 'Режим проверки: файл не скачивается.' -ForegroundColor Yellow
    } else {
        Write-Host 'Скачивание...'
        Write-GpuDriverLog 'INFO' ("Download started: {0}" -f $driver.Url)
        $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
        $allowedDomains = if ($driver.Source -eq 'AMD') { @('amd.com') } else { @('nvidia.com', 'geforce.com') }
        $download = Get-GpuDriverDownload -Url $driver.Url -OutDir $OutDir -AllowedDomains $allowedDomains -Force:$Force
        $downloadTimer.Stop()

        if ($download.Existing) {
            Write-Host 'Файл уже существует; используется он (для перезаписи добавьте -Force).' -ForegroundColor Yellow
        }
        $candidatePath = if ($download.Existing) { $download.FinalPath } else { $download.TempPath }
        Write-Host 'Проверка подписи установщика...'
        $signature = Assert-DriverInstallerSignature -Path $candidatePath -Vendor $driver.Source -NoQuarantine:([bool]$download.Existing)
        Write-Host "Издатель      : $($signature.SignerName)" -ForegroundColor Green
        Write-Host "Подпись       : $($signature.Status)"
        Write-Host "SHA-256       : $($signature.Sha256)"

        if (-not $download.Existing) {
            if ((Test-Path -LiteralPath $download.FinalPath) -and -not $Force) {
                [void](Move-ToQuarantine -Path $download.TempPath -Reason 'final path appeared during download')
                throw 'Файл уже существует; повторная загрузка не перезаписывала его.'
            }
            try {
                Move-Item -LiteralPath $download.TempPath -Destination $download.FinalPath -Force -ErrorAction Stop
            } catch {
                [void](Move-ToQuarantine -Path $download.TempPath -Reason 'failed to publish verified download')
                throw
            }
        }
        $saved = $download.FinalPath
        $length = (Get-Item -LiteralPath $saved).Length
        if ($length -lt 1MB) { Write-Warning "Файл подозрительно мал: $length байт." }
        Write-Host "Готово        : $saved" -ForegroundColor Green
        Write-Host ("Скачано за    : {0}" -f $downloadTimer.Elapsed.ToString('hh\:mm\:ss'))
        Write-GpuDriverLog 'INFO' ("Download completed: file={0}; sha256={1}; elapsed={2}" -f $saved, $signature.Sha256, $downloadTimer.Elapsed.ToString('hh\:mm\:ss'))

        if ($NoInstall) {
            Write-Host 'Установка не запрашивалась (-NoInstall): файл сохранён для ручного запуска.' -ForegroundColor Yellow
        } else {
            $answer = Read-Host 'Установить драйвер сейчас? [y/N]'
            if ($answer -and $answer.Trim() -match '^(?i)(y|yes|д|да)$') {
                Write-Host 'Подготовка проверенного установщика...' -ForegroundColor Yellow
                Write-GpuDriverLog 'INFO' 'Installer launch requested'
                $stage = $null
                $guard = $null
                try {
                    $stage = New-VerifiedInstallerCopy -Path $saved -Vendor $driver.Source -ExpectedHash $signature.Sha256 -Url $driver.Url
                    $guard = $stage.Guard
                    $proc = Start-Process -FilePath $stage.Path -WorkingDirectory $stage.Directory -Verb RunAs -PassThru -Wait
                    Write-Host "Установщик завершён, код выхода: $($proc.ExitCode)." -ForegroundColor Green
                    Write-GpuDriverLog 'INFO' ("Installer exited: code={0}" -f $proc.ExitCode)
                } catch {
                    Write-GpuDriverLog 'ERROR' ("Installer launch failed: " + $_.Exception.Message)
                    Write-Warning "Установка не запущена: $($_.Exception.Message)"
                } finally {
                    if ($guard) { $guard.Dispose() }
                    if ($stage) { Remove-InstallerStage -Directory $stage.Directory }
                }
            } else {
                Write-Host 'Установка отменена. Файл сохранён — можно запустить вручную.' -ForegroundColor Yellow
            }
        }
    }

    $summary = "$($gpu.Name) — $($driver.DriverName) $($driver.Version)".Trim()
    if ($driver.ReleaseDate) { $summary += " от $($driver.ReleaseDate)" }
    Write-Host ''
    Write-Host "Итог: $summary" -ForegroundColor Cyan
    if (-not $DryRun) { Write-Host "Файл: $saved" -ForegroundColor Green }
} catch {
    Write-GpuDriverLog 'ERROR' ("CLI error: " + $_.Exception.Message)
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Журнал: $GpuDriverLogPath" -ForegroundColor DarkGray
    exit 1
}
