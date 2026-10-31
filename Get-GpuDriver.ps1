#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'Downloads'),
    [string]$GpuName,
    [switch]$DryRun,
    [switch]$NoInstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GpuDriverCore.ps1')

function Save-Download([string]$Url, [string]$OutDir, [switch]$Force) {
    $fileName = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    $filePath = Join-Path $OutDir $fileName
    if ((Test-Path -LiteralPath $filePath) -and -not $Force) {
        Write-Host 'Файл уже существует; используется он (для перезаписи добавьте -Force).' -ForegroundColor Yellow
        return $filePath
    }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $tempPath = "$filePath.part"
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }

    $downloaded = $false
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Start-BitsTransfer -Source $Url -Destination $tempPath -Description 'GPU driver download' -ErrorAction Stop
            $downloaded = $true
        } catch {
            Write-Warning "BITS не справился: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $downloaded) {
        $client = New-Object System.Net.WebClient
        $client.Headers.Add('User-Agent', $userAgent)
        try { $client.DownloadFile($Url, $tempPath) } finally { $client.Dispose() }
    }

    Move-Item -LiteralPath $tempPath -Destination $filePath -Force
    $filePath
}

try {
    $gpu = Get-GpuController -Name $GpuName
    $vendor = $gpu.Vendor

    Write-Host "Видеокарта    : $($gpu.Name)"
    Write-Host "Производитель : $vendor"
    Write-Host 'Поиск драйвера...'

    $lookupTimer = [Diagnostics.Stopwatch]::StartNew()
    $driver = Get-GpuDriverInfo -Name $gpu.Name
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

    $fileName = [IO.Path]::GetFileName(([Uri]$driver.Url).AbsolutePath)
    $filePath = Join-Path $OutDir $fileName
    if ($DryRun) {
        Write-Host 'Режим проверки: файл не скачивается.' -ForegroundColor Yellow
    } else {
        Write-Host 'Скачивание...'
        $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
        $saved = Save-Download -Url $driver.Url -OutDir $OutDir -Force:$Force
        $downloadTimer.Stop()
        $length = (Get-Item -LiteralPath $saved).Length
        if ($length -lt 1MB) { Write-Warning "Файл подозрительно мал: $length байт." }
        Write-Host "Готово        : $saved" -ForegroundColor Green
        Write-Host ("Скачано за    : {0}" -f $downloadTimer.Elapsed.ToString('hh\:mm\:ss'))

        if ($NoInstall) {
            Write-Host 'Установка не запрашивалась (-NoInstall): файл сохранён для ручного запуска.' -ForegroundColor Yellow
        } else {
            $answer = Read-Host 'Установить драйвер сейчас? [y/N]'
            if ($answer -and $answer.Trim() -match '^(?i)(y|yes|д|да)$') {
                Write-Host 'Запуск установщика (потребуется подтверждение UAC)...' -ForegroundColor Yellow
                try {
                    $proc = Start-Process -FilePath $saved -WorkingDirectory (Split-Path -Parent $saved) -Verb RunAs -PassThru -Wait
                    Write-Host "Установщик завершён, код выхода: $($proc.ExitCode)." -ForegroundColor Green
                } catch {
                    Write-Warning "Установка не запущена: $($_.Exception.Message)"
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
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
