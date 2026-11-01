#requires -Version 5.1

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
$GpuDriverToolVersion = '1.0.1'
$GpuDriverLogPath = Join-Path $env:LOCALAPPDATA 'GpuDriverTool\gpu-driver.log'
$MaximumPageBytes = 10MB
$MaximumDownloadBytes = 4GB
$MaximumRedirects = 5
$DownloadTimeoutMinutes = 120

function ConvertTo-SafeText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 2000
    )
    if ($null -eq $Text) { return '' }
    $safe = [regex]::Replace([string]$Text, '[\x00-\x1F\x7F]+', ' ')
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength) + '...'
    }
    return $safe
}

function Write-GpuDriverLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$Message
    )
    try {
        $directory = Split-Path -Parent $GpuDriverLogPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $GpuDriverLogPath) {
            $logItem = Get-Item -LiteralPath $GpuDriverLogPath
            if ($logItem.Length -gt 1MB) {
                Move-Item -LiteralPath $GpuDriverLogPath -Destination "$GpuDriverLogPath.old" -Force
            }
        }
        $safeMessage = ConvertTo-SafeText -Text $Message -MaxLength 1500
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $safeMessage
        Add-Content -LiteralPath $GpuDriverLogPath -Value $line -Encoding UTF8
    } catch {
    }
}

function Test-AllowedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string[]]$AllowedDomains,
        [switch]$ExactHost
    )
    try { $uri = [Uri]$Url } catch { return $false }
    if (-not $uri.IsAbsoluteUri) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    if ($uri.UserInfo) { return $false }
    if ($uri.Port -ne 443) { return $false }
    $hostName = $uri.Host.ToLowerInvariant().TrimEnd('.')
    if (-not $hostName) { return $false }
    foreach ($domain in $AllowedDomains) {
        $allowed = ([string]$domain).ToLowerInvariant().TrimEnd('.')
        if (-not $allowed) { continue }
        if ($hostName -eq $allowed) { return $true }
        if (-not $ExactHost -and $hostName.EndsWith('.' + $allowed, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-AllowedUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string[]]$AllowedDomains,
        [switch]$ExactHost
    )
    if (-not (Test-AllowedUrl -Url $Url -AllowedDomains $AllowedDomains -ExactHost:$ExactHost)) {
        throw 'URL не соответствует разрешённым HTTPS-доменам.'
    }
    return [Uri]$Url
}

function Get-SafeDownloadFileName {
    param([Parameter(Mandatory = $true)][string]$Url)
    try { $uri = [Uri]$Url } catch { throw 'Некорректный URL установщика.' }
    $rawName = [IO.Path]::GetFileName($uri.AbsolutePath)
    if (-not $rawName) { throw 'В URL отсутствует имя файла установщика.' }
    try { $name = [Uri]::UnescapeDataString($rawName) } catch { throw 'Некорректное имя файла установщика.' }
    if ($name -match '[\\/:*?"<>|%\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]') { throw 'Имя файла установщика содержит недопустимые символы.' }
    if ($name.EndsWith('.') -or $name.EndsWith(' ')) { throw 'Имя файла установщика оканчивается недопустимым символом.' }
    if ($name.Length -gt 120) { throw 'Имя файла установщика слишком длинное.' }
    $baseName = [IO.Path]::GetFileNameWithoutExtension($name)
    if (-not $baseName) { throw 'Имя файла установщика некорректно.' }
    if ($baseName -match '(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Имя файла установщика зарезервировано Windows.' }
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if ($extension -notin @('.exe', '.msi')) { throw 'Разрешены только установщики .exe и .msi.' }
    return $name
}

function Resolve-DownloadPath {
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $outFull = [IO.Path]::GetFullPath($OutDir)
    $candidate = [IO.Path]::GetFullPath((Join-Path $outFull $FileName))
    $prefix = $outFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Путь загрузки выходит за пределы выбранной папки.'
    }
    return $candidate
}

function Add-MarkOfTheWeb {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Url = ''
    )
    try {
        $safeUrl = ConvertTo-SafeText -Text $Url -MaxLength 2000
        $zone = "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=$safeUrl`r`nHostUrl=$safeUrl`r`n"
        Set-Content -LiteralPath ($Path + ':Zone.Identifier') -Value $zone -Encoding ASCII -ErrorAction Stop
    } catch {
        Write-GpuDriverLog 'WARN' ("MOTW could not be applied: " + $_.Exception.Message)
    }
}

function Get-DriverFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Move-ToQuarantine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Reason = ''
    )
    $quarantineRoot = Join-Path $env:LOCALAPPDATA 'GpuDriverTool\quarantine'
    try {
        if (-not (Test-Path -LiteralPath $quarantineRoot)) {
            New-Item -ItemType Directory -Path $quarantineRoot -Force | Out-Null
        }
        $destination = Join-Path $quarantineRoot ('{0}-{1}.blocked' -f (Get-Date -Format 'yyyyMMddHHmmss'), [guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $Path -Destination $destination -Force -ErrorAction Stop
        Write-GpuDriverLog 'WARN' ("File quarantined: path={0}; reason={1}" -f $destination, $Reason)
        return $destination
    } catch {
        Write-GpuDriverLog 'ERROR' ("Quarantine failed: " + $_.Exception.Message)
        return ''
    }
}

function Get-GpuDriverLatestRelease {
    [CmdletBinding()]
    param()
    $headers = @{
        'User-Agent' = $userAgent
        'Accept'     = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/dponeNF/gpu-driver-tool/releases/latest' -Headers $headers -TimeoutSec 15 -MaximumRedirection 0
    $releaseUrl = [string]$release.html_url
    if (-not (Test-AllowedUrl -Url $releaseUrl -AllowedDomains @('github.com') -ExactHost)) {
        $releaseUrl = ''
    }
    return [pscustomobject]@{
        Tag         = [string]$release.tag_name
        Name        = [string]$release.name
        Url         = $releaseUrl
        PublishedAt = $release.published_at
        Body        = [string]$release.body
    }
}

function Get-WebContent {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string[]]$AllowedDomains,
        [int]$MaxBytes = $MaximumPageBytes
    )
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $response = $null
        $stream = $null
        $reader = $null
        try {
            $current = Assert-AllowedUrl -Url $Url -AllowedDomains $AllowedDomains
            for ($redirect = 0; $redirect -le $MaximumRedirects; $redirect++) {
                $request = [Net.HttpWebRequest]::Create($current)
                $request.UserAgent = $userAgent
                $request.Timeout = 90000
                $request.ReadWriteTimeout = 90000
                $request.AllowAutoRedirect = $false
                $request.AutomaticDecompression = ([Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate)
                $response = $request.GetResponse()
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    $location = [string]$response.Headers['Location']
                    $response.Close()
                    $response = $null
                    if (-not $location) { throw 'Сервер вернул редирект без Location.' }
                    $current = Assert-AllowedUrl -Url ([Uri]::new($current, $location).AbsoluteUri) -AllowedDomains $AllowedDomains
                    continue
                }

                $encoding = [Text.Encoding]::UTF8
                $contentType = [string]$response.ContentType
                if ($contentType -match '(?i)charset=([^;]+)') {
                    try { $encoding = [Text.Encoding]::GetEncoding($matches[1].Trim().Trim('"')) } catch { $encoding = [Text.Encoding]::UTF8 }
                }
                $stream = $response.GetResponseStream()
                $reader = New-Object IO.StreamReader($stream, $encoding, $true)
                $buffer = New-Object char[] 8192
                $builder = New-Object Text.StringBuilder
                $total = 0
                while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $read
                    if ($total -gt $MaxBytes) { throw 'Ответ сервера слишком большой.' }
                    [void]$builder.Append($buffer, 0, $read)
                }
                return $builder.ToString()
            }
            throw 'Превышено допустимое число редиректов.'
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        } finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
            if ($response) { $response.Close() }
        }
    }
    throw $lastError
}

function Get-GpuDriverDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string[]]$AllowedDomains,
        [switch]$Force
    )
    $fileName = Get-SafeDownloadFileName -Url $Url
    [void](Assert-AllowedUrl -Url $Url -AllowedDomains $AllowedDomains)
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $finalPath = Resolve-DownloadPath -OutDir $OutDir -FileName $fileName
    if ((Test-Path -LiteralPath $finalPath) -and -not $Force) {
        return [pscustomobject]@{
            Existing  = $true
            FileName  = $fileName
            FinalPath = $finalPath
            TempPath  = $null
        }
    }

    $tempPath = Join-Path $OutDir ('.gpu-driver-{0}.part' -f [guid]::NewGuid().ToString('N'))
    $response = $null
    $stream = $null
    $output = $null
    try {
        $current = Assert-AllowedUrl -Url $Url -AllowedDomains $AllowedDomains
        for ($redirect = 0; $redirect -le $MaximumRedirects; $redirect++) {
            $request = [Net.HttpWebRequest]::Create($current)
            $request.UserAgent = $userAgent
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 120000
            $request.AllowAutoRedirect = $false
            $response = $request.GetResponse()
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $location = [string]$response.Headers['Location']
                $response.Close()
                $response = $null
                if (-not $location) { throw 'Сервер вернул редирект без Location.' }
                $current = Assert-AllowedUrl -Url ([Uri]::new($current, $location).AbsoluteUri) -AllowedDomains $AllowedDomains
                continue
            }

            $contentLength = [long]$response.ContentLength
            if ($contentLength -gt $MaximumDownloadBytes) { throw 'Файл установщика слишком большой.' }
            $stream = $response.GetResponseStream()
            $output = [IO.File]::Create($tempPath)
            $buffer = New-Object byte[] 81920
            $received = [long]0
            $deadline = [DateTime]::UtcNow.AddMinutes($DownloadTimeoutMinutes)
            while ($true) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Превышено время загрузки установщика.' }
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $received += $read
                if ($received -gt $MaximumDownloadBytes) { throw 'Файл установщика слишком большой.' }
                $output.Write($buffer, 0, $read)
            }
            $output.Close()
            $output = $null
            $stream.Close()
            $stream = $null
            $response.Close()
            $response = $null

            if ($contentLength -gt 0 -and $received -ne $contentLength) {
                throw "Скачано $received из $contentLength байт — соединение прервано."
            }
            if ($received -lt 1MB) { throw "Файл слишком мал ($received байт) — возможно, сервер вернул ошибку." }

            Add-MarkOfTheWeb -Path $tempPath -Url $Url
            return [pscustomobject]@{
                Existing  = $false
                FileName  = $fileName
                FinalPath = $finalPath
                TempPath  = $tempPath
            }
        }
        throw 'Превышено допустимое число редиректов.'
    } catch {
        if ($output) { try { $output.Close() } catch { } }
        if ($stream) { try { $stream.Close() } catch { } }
        if ($response) { try { $response.Close() } catch { } }
        if (Test-Path -LiteralPath $tempPath) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop } catch { }
        }
        throw
    }
}

function Get-CertificateOrganization {
    param($Certificate)
    if (-not $Certificate) { return '' }
    $match = [regex]::Match([string]$Certificate.Subject, '(?i)(?:^|,)\s*O=(?:"([^"]+)"|([^,]+))')
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value.Trim() }
    return $match.Groups[2].Value.Trim()
}

function Test-CertificateMachineTrust {
    param($Certificate)
    if (-not $Certificate) { return $false }
    $chain = $null
    try {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        [void]$chain.Build($Certificate)
        if ($chain.ChainElements.Count -eq 0) { return $false }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        if (-not $root) { return $false }
        $machineRoot = Get-Item -LiteralPath ('Cert:\LocalMachine\Root\' + $root.Thumbprint) -ErrorAction SilentlyContinue
        return [bool]$machineRoot
    } catch {
        return $false
    } finally {
        if ($chain) { $chain.Dispose() }
    }
}

function New-VerifiedInstallerCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Vendor,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [string]$Url = ''
    )
    $stagingRoot = Join-Path $env:LOCALAPPDATA 'GpuDriverTool\staging'
    if (-not (Test-Path -LiteralPath $stagingRoot)) {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    }
    $stageDirectory = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
    $destination = Join-Path $stageDirectory ([IO.Path]::GetFileName($Path))
    $guard = $null
    try {
        New-Item -ItemType Directory -Path $stageDirectory -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $Path -Destination $destination -Force -ErrorAction Stop
        Add-MarkOfTheWeb -Path $destination -Url $Url
        $signature = Assert-DriverInstallerSignature -Path $destination -Vendor $Vendor
        $guard = Open-InstallerGuard -Path $destination
        $hash = Get-DriverFileHash -Path $destination
        if ($hash -ne $ExpectedHash) {
            $guard.Dispose()
            $guard = $null
            [void](Move-ToQuarantine -Path $destination -Reason 'hash mismatch after staging')
            throw 'Хэш проверенного установщика изменился перед установкой.'
        }
        return [pscustomobject]@{
            Path      = $destination
            Directory = $stageDirectory
            Hash      = $hash
            Signature = $signature
            Guard     = $guard
        }
    } catch {
        if ($guard) { $guard.Dispose() }
        if (Test-Path -LiteralPath $stageDirectory) {
            try { Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction Stop } catch { }
        }
        throw
    }
}

function Remove-InstallerStage {
    param([string]$Directory)
    if (-not $Directory) { return }
    try {
        $stagingRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'GpuDriverTool\staging'))
        $fullPath = [IO.Path]::GetFullPath($Directory)
        $prefix = $stagingRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return }
        if (Test-Path -LiteralPath $fullPath) {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

function Open-InstallerGuard {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    } catch {
        throw "Не удалось заблокировать установщик от подмены: $($_.Exception.Message)"
    }
}

function Get-Normalized([string]$Text) {
    if (-not $Text) { return '' }
    $Text = $Text -replace '(?i)\(TM\)|\(R\)|™|®|©', ''
    $Text = $Text -replace '(?i)AMD|NVIDIA|Radeon|Graphics|Series', ''
    ($Text -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Format-Date([string]$Value) {
    if (-not $Value) { return '' }
    $Value = $Value.Trim()
    try {
        return ([datetime]::Parse($Value, [Globalization.CultureInfo]::GetCultureInfo('en-US'))).ToString('dd.MM.yyyy')
    } catch {
        return $Value
    }
}

function Find-BestMatch([object[]]$Items, [string]$Query, [string]$TitleProperty) {
    $q = Get-Normalized $Query
    if (-not $q) { return $null }
    $scored = foreach ($item in $Items) {
        $t = Get-Normalized ([string]$item.$TitleProperty)
        if (-not $t) { continue }
        $score = -1
        if ($t -eq $q) { $score = 1000 }
        elseif ($q.StartsWith($t) -or $t.StartsWith($q)) { $score = 500 - [Math]::Abs($t.Length - $q.Length) }
        if ($score -lt 0) { continue }
        [pscustomobject]@{ Item = $item; Score = $score; Length = $t.Length }
    }
    $best = $scored | Sort-Object -Property Score, Length -Descending | Select-Object -First 1
    if ($best) { return $best.Item }
    return $null
}

function Get-NvidiaOsId {
    [xml]$xml = Get-WebContent -Url 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=4' -AllowedDomains @('nvidia.com')
    $osItems = @($xml.LookupValueSearch.LookupValues.LookupValue)
    $build = [Environment]::OSVersion.Version.Build
    $caption = (Get-CimInstance Win32_OperatingSystem).Caption
    $is64 = [Environment]::Is64BitOperatingSystem

    $want = $null
    if ($build -ge 22000) { $want = 'Windows 11' }
    elseif ($caption -match 'Windows 10') { if ($is64) { $want = 'Windows 10 64-bit' } else { $want = 'Windows 10 32-bit' } }
    elseif ($caption -match 'Windows 8\.1') { if ($is64) { $want = 'Windows 8.1 64-bit' } else { $want = 'Windows 8.1 32-bit' } }
    elseif ($caption -match 'Windows 7') { if ($is64) { $want = 'Windows 7 64-bit' } else { $want = 'Windows 7 32-bit' } }
    if (-not $want) { return $null }

    $match = $osItems | Where-Object { $_.Name -eq $want } | Select-Object -First 1
    if (-not $match -and $build -ge 22000) { $match = $osItems | Where-Object { $_.Name -like 'Windows 11*' } | Select-Object -First 1 }
    if ($match) { return [int]([string]$match.Value) }
    return $null
}

function Get-NvidiaDriver([string]$Name) {
    $osId = Get-NvidiaOsId
    if (-not $osId) { throw 'Не удалось определить версию Windows для поиска драйвера NVIDIA.' }

    [xml]$xml = Get-WebContent -Url 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3' -AllowedDomains @('nvidia.com')
    $products = @($xml.LookupValueSearch.LookupValues.LookupValue | ForEach-Object {
        [pscustomobject]@{
            Name     = [string]$_.Name
            Value    = [string]$_.Value
            ParentId = [string]$_.ParentID
        }
    })

    $product = Find-BestMatch $products $Name 'Name'
    if (-not $product) { throw "NVIDIA не нашла модель «$Name» в своём списке драйверов." }

    $endpoint = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php'
    foreach ($whql in 1, 0) {
        foreach ($dch in 1, 0) {
            $query = "func=DriverManualLookup&psid=$($product.ParentId)&pfid=$($product.Value)&osID=$osId&languageCode=1033&beta=0&isWHQL=$whql&dltype=-1&dch=$dch&upCRD=0&qnf=0&sort1=0&numberOfResults=1"
            try { $json = (Get-WebContent -Url "$endpoint`?$query" -AllowedDomains @('nvidia.com', 'geforce.com')) | ConvertFrom-Json } catch { continue }
            if ($json.Success -ne '1' -or @($json.IDS).Count -eq 0) { continue }
            $info = @($json.IDS)[0].downloadInfo
            if ($info.DownloadURL) {
                $driverName = 'NVIDIA Driver'
                if ($info.Name) {
                    try { $driverName = [System.Net.WebUtility]::UrlDecode([string]$info.Name) } catch { $driverName = [string]$info.Name }
                }
                return [pscustomobject]@{
                    Url         = $info.DownloadURL
                    DriverName  = $driverName
                    Version     = $info.Version
                    ReleaseDate = Format-Date $info.ReleaseDateTime
                    Size        = $info.DownloadURLFileSize
                    Source      = 'NVIDIA'
                    Note        = ''
                }
            }
        }
    }
    throw "NVIDIA не вернула ссылку на драйвер для «$Name»."
}

function Add-JsonTreeItems($Node, $List) {
    if ($null -ne $Node.title -and $null -ne $Node.url) {
        $List.Add([pscustomobject]@{ Title = [string]$Node.title; Url = [string]$Node.url })
    }
    if ($null -ne $Node.items) {
        foreach ($child in $Node.items) { Add-JsonTreeItems $child $List }
    }
}

function Get-AmdProductList([string]$Html) {
    $m = [regex]::Match($Html, 'data-json="([^"]+)"')
    if (-not $m.Success) { return @() }
    $json = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | ConvertFrom-Json
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($type in $json.productTypes) { Add-JsonTreeItems $type $list }
    return $list
}

function Get-AmdDriverInfoFromPage([string]$Html, [int]$Build) {
    $headings = @(
        'Windows 11 - 64-Bit Edition',
        'Windows 10 - 64-Bit Edition',
        'Windows 8.1 - 64-Bit Edition',
        'Windows 7 - 64-Bit Edition'
    )
    $positions = @()
    foreach ($h in $headings) {
        $i = $Html.IndexOf($h, [StringComparison]::OrdinalIgnoreCase)
        if ($i -ge 0) { $positions += [pscustomobject]@{ Name = $h; Index = $i } }
    }
    if ($positions.Count -eq 0) { return $null }

    if ($Build -ge 22000) { $preferred = @('Windows 11 - 64-Bit Edition', 'Windows 10 - 64-Bit Edition') }
    elseif ($Build -ge 10240) { $preferred = @('Windows 10 - 64-Bit Edition', 'Windows 11 - 64-Bit Edition') }
    elseif ($Build -ge 9600) { $preferred = @('Windows 8.1 - 64-Bit Edition', 'Windows 7 - 64-Bit Edition') }
    else { $preferred = @('Windows 7 - 64-Bit Edition') }

    foreach ($want in $preferred) {
        $target = $positions | Where-Object { $_.Name -eq $want } | Select-Object -First 1
        if (-not $target) { continue }
        $next = $positions | Where-Object { $_.Index -gt $target.Index } | Sort-Object -Property Index | Select-Object -First 1
        $end = if ($next) { $next.Index } else { $Html.Length }
        $segment = $Html.Substring($target.Index, $end - $target.Index)

        $articles = [regex]::Matches($segment, '(?is)<article[^>]*driver-download-details[^>]*>(.*?)</article>')
        $entries = @()
        foreach ($article in $articles) {
            $body = $article.Groups[1].Value
            $link = [regex]::Match($body, '(?i)href="(https://drivers\.amd\.com/drivers/[^"]+\.exe)"')
            if (-not $link.Success) { continue }
            $url = $link.Groups[1].Value
            $label = [regex]::Match($body, '(?i)aria-label="([^"]*)"').Groups[1].Value
            $isAuto = ($url -match '(?i)minimalsetup|/installer/') -or ($label -match '(?i)Auto-Detect')
            $entries += [pscustomobject]@{ Url = $url; Label = $label; IsAuto = $isAuto; Body = $body }
        }
        if ($entries.Count -eq 0) { continue }

        $adrenalin = @($entries | Where-Object { -not $_.IsAuto -and ($_.Label -match 'Adrenalin' -or $_.Url -match 'Adrenalin') })
        $pick = $adrenalin | Where-Object { $_.Body -match '(?i)Recommended' } | Select-Object -First 1
        if (-not $pick) { $pick = $adrenalin | Where-Object { $_.Body -notmatch '(?i)Optional' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $adrenalin | Select-Object -First 1 }
        if (-not $pick) { $pick = $entries | Where-Object { -not $_.IsAuto } | Select-Object -First 1 }
        if (-not $pick) { $pick = $entries | Select-Object -First 1 }

        $driverName = [regex]::Match($pick.Body, '(?is)<h4[^>]*>\s*(.*?)\s*</h4>').Groups[1].Value
        $revision = [regex]::Match($pick.Body, '(?is)<strong>\s*Revision Number\s*</strong>\s*<p[^>]*>\s*(.*?)\s*</p>').Groups[1].Value
        $date = [regex]::Match($pick.Body, '(?is)<strong>\s*Release Date\s*</strong>\s*<p[^>]*>\s*(.*?)\s*</p>').Groups[1].Value
        $size = [regex]::Match($pick.Body, '(?is)<strong>\s*File Size\s*</strong>\s*<p[^>]*>\s*(.*?)\s*</p>').Groups[1].Value

        $driverName = ($driverName -replace '\s+', ' ').Trim()
        $revision = ($revision -replace '\s+', ' ').Trim()
        $date = ($date -replace '\s+', ' ').Trim()
        $size = ($size -replace '\s+', ' ').Trim()
        if (-not $driverName) { $driverName = 'AMD Software: Adrenalin Edition' }
        $version = $revision -replace '(?i)^Adrenalin\s*', ''
        if (-not $version) {
            $fileName = [IO.Path]::GetFileName(([Uri]$pick.Url).AbsolutePath)
            $vm = [regex]::Match($fileName, '(\d{2}\.\d+(?:\.\d+)?)')
            if ($vm.Success) { $version = $vm.Groups[1].Value }
        }

        return [pscustomobject]@{
            Url         = $pick.Url
            DriverName  = $driverName
            Version     = $version
            ReleaseDate = Format-Date $date
            Size        = $size
            IsAuto      = [bool]$pick.IsAuto
        }
    }
    return $null
}

function Get-AmdAutoDetectUrl([string]$Html) {
    $m = [regex]::Match($Html, '(?i)href="(https://drivers\.amd\.com/drivers/[^"]*minimalsetup[^"]*\.exe)"')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($Html, '(?i)href="(https://drivers\.amd\.com/drivers/[^"]+\.exe)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-AmdDriver([string]$Name) {
    $supportHtml = Get-WebContent -Url 'https://www.amd.com/en/support/download/drivers.html' -AllowedDomains @('amd.com')
    $products = @(Get-AmdProductList $supportHtml)
    $product = Find-BestMatch $products $Name 'Title'
    $build = [Environment]::OSVersion.Version.Build
    $info = $null

    if ($product) {
        try {
            $page = Get-WebContent -Url $product.Url -AllowedDomains @('amd.com')
            $info = Get-AmdDriverInfoFromPage $page $build
        } catch {
            $info = $null
        }
    }

    $note = ''
    if (-not $info) {
        $url = Get-AmdAutoDetectUrl $supportHtml
        if (-not $url) { throw "AMD не вернула ссылку на драйвер для «$Name»." }
        $version = ''
        $fileName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
        $m = [regex]::Match($fileName, '(\d{2}\.\d+(?:\.\d+)?)')
        if ($m.Success) { $version = $m.Groups[1].Value }
        $info = [pscustomobject]@{
            Url         = $url
            DriverName  = 'AMD Auto-Detect and Install'
            Version     = $version
            ReleaseDate = ''
            Size        = ''
            IsAuto      = $true
        }
        $note = 'Точный пакет для модели не найден: скачивается официальная утилита AMD Auto-Detect. Проверяется только подпись загрузчика; компоненты драйвера загружает сама утилита AMD.'
    } elseif ($info.IsAuto) {
        $note = 'Для этой модели AMD предлагает только утилиту Auto-Detect: точный драйвер она определит при запуске. Проверяется только подпись загрузчика.'
    }

    return [pscustomobject]@{
        Url         = $info.Url
        DriverName  = $info.DriverName
        Version     = $info.Version
        ReleaseDate = $info.ReleaseDate
        Size        = $info.Size
        Source      = 'AMD'
        Note        = $note
    }
}

function Get-GpuAdapterList {
    [CmdletBinding()]
    param()
    $controllers = @(Get-CimInstance Win32_VideoController | Where-Object {
        $_.Name -and $_.Name -notmatch '(?i)Microsoft Basic|Remote|Virtual|Parsec'
    })

    $adapters = foreach ($controller in $controllers) {
        $pciVendor = ''
        $pciDevice = ''
        if ($controller.PNPDeviceID -match '(?i)VEN_([0-9A-F]{4})') { $pciVendor = $Matches[1].ToUpperInvariant() }
        if ($controller.PNPDeviceID -match '(?i)DEV_([0-9A-F]{4})') { $pciDevice = $Matches[1].ToUpperInvariant() }

        $vendor = $null
        if ($pciVendor -eq '10DE') { $vendor = 'NVIDIA' }
        elseif ($pciVendor -eq '1002') { $vendor = 'AMD' }
        elseif ($controller.Name -match '(?i)NVIDIA') { $vendor = 'NVIDIA' }
        elseif ($controller.Name -match '(?i)AMD|Radeon') { $vendor = 'AMD' }
        if (-not $vendor) { continue }

        [pscustomobject]@{
            Name        = ([string]$controller.Name).Trim()
            Vendor      = $vendor
            PciVendorId = $pciVendor
            PciDeviceId = $pciDevice
            PnpDeviceId = [string]$controller.PNPDeviceID
            DisplayName = ('{0} [{1}]' -f ([string]$controller.Name).Trim(), $vendor)
        }
    }

    return @($adapters | Sort-Object -Property @{ Expression = { if ($_.Vendor -eq 'NVIDIA') { 0 } else { 1 } } }, Name)
}

function Get-GpuController([string]$Name) {
    if ($Name) {
        $adapters = @(Get-GpuAdapterList)
        $match = $adapters | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if ($match) { return $match }

        if ($Name -match '(?i)NVIDIA') { $vendor = 'NVIDIA' }
        elseif ($Name -match '(?i)AMD|Radeon') { $vendor = 'AMD' }
        else { throw "Неподдерживаемая видеокарта: $Name" }
        return [pscustomobject]@{
            Name        = $Name
            Vendor      = $vendor
            PciVendorId = ''
            PciDeviceId = ''
            PnpDeviceId = ''
            DisplayName = ('{0} [{1}]' -f $Name, $vendor)
        }
    }

    $adapters = @(Get-GpuAdapterList)
    if ($adapters.Count -eq 0) { throw 'Видеокарта AMD или NVIDIA не найдена.' }
    return $adapters[0]
}

function Get-DriverSignatureInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Vendor
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл установщика не найден: $Path"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $certificate = $signature.SignerCertificate
    $subject = ''
    $commonName = ''
    $organization = ''
    $thumbprint = ''
    if ($certificate) {
        $subject = [string]$certificate.Subject
        try { $commonName = [string]$certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } catch { $commonName = '' }
        $organization = Get-CertificateOrganization -Certificate $certificate
        $thumbprint = [string]$certificate.Thumbprint
    }

    $vendorMatches = $false
    if ($Vendor -eq 'AMD') {
        $allowedNames = @('Advanced Micro Devices, Inc.', 'Advanced Micro Devices')
        $vendorMatches = ($allowedNames -contains $organization) -or ($allowedNames -contains $commonName)
    } elseif ($Vendor -eq 'NVIDIA') {
        $allowedNames = @('NVIDIA Corporation')
        $vendorMatches = ($allowedNames -contains $organization) -or ($allowedNames -contains $commonName)
    }

    $machineTrusted = Test-CertificateMachineTrust -Certificate $certificate
    $isValid = ($signature.Status -eq 'Valid') -and $vendorMatches -and $machineTrusted
    return [pscustomobject]@{
        Path              = $Path
        Status            = [string]$signature.Status
        StatusMessage     = [string]$signature.StatusMessage
        Signer            = $subject
        SignerName        = $commonName
        SignerOrganization = $organization
        Thumbprint        = $thumbprint
        Vendor            = $Vendor
        VendorMatches     = $vendorMatches
        MachineTrusted    = $machineTrusted
        IsValid           = $isValid
    }
}

function Assert-DriverInstallerSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Vendor,
        [switch]$NoQuarantine
    )

    $signature = Get-DriverSignatureInfo -Path $Path -Vendor $Vendor
    if (-not $signature.IsValid) {
        $reason = $signature.StatusMessage
        if (-not $signature.MachineTrusted) {
            $reason = 'Корневой сертификат издателя отсутствует в хранилище LocalMachine\Root.'
        } elseif (-not $signature.VendorMatches) {
            $reason = "Издатель не совпадает с производителем драйвера ($Vendor)."
        }

        $quarantinePath = ''
        if (-not $NoQuarantine) {
            $quarantinePath = Move-ToQuarantine -Path $Path -Reason $reason
        }

        $message = "Подпись установщика не подтверждена.`r`nСтатус: $($signature.Status)`r`nИздатель: $($signature.SignerName)`r`n$reason"
        if ($quarantinePath) { $message += "`r`nФайл помещён в карантин: $quarantinePath" }
        elseif (-not $NoQuarantine) { $message += "`r`nФайл не запускался, но переместить его в карантин не удалось." }
        Write-GpuDriverLog 'ERROR' ("Signature check failed: status={0}; signer={1}; thumbprint={2}; file={3}" -f $signature.Status, $signature.SignerName, $signature.Thumbprint, $Path)
        throw $message
    }

    $hash = Get-DriverFileHash -Path $Path
    $signature | Add-Member -NotePropertyName Sha256 -NotePropertyValue $hash
    Write-GpuDriverLog 'INFO' ("Signature verified: signer={0}; thumbprint={1}; status={2}; sha256={3}; file={4}" -f $signature.SignerName, $signature.Thumbprint, $signature.Status, $hash, $Path)
    return $signature
}

function Get-GpuDriverInfo([string]$Name, [string]$Vendor) {
    if (-not $Vendor) {
        if ($Name -match '(?i)NVIDIA') { $Vendor = 'NVIDIA' }
        elseif ($Name -match '(?i)AMD|Radeon') { $Vendor = 'AMD' }
    }
    $driver = $null
    if ($Vendor -eq 'NVIDIA') { $driver = Get-NvidiaDriver $Name }
    elseif ($Vendor -eq 'AMD') { $driver = Get-AmdDriver $Name }
    else { throw "Неподдерживаемая видеокарта: $Name" }

    if (-not $driver -or -not $driver.Url) { throw 'Производитель не вернул ссылку на драйвер.' }
    $allowedDomains = if ($Vendor -eq 'AMD') { @('amd.com') } else { @('nvidia.com', 'geforce.com') }
    if (-not (Test-AllowedUrl -Url ([string]$driver.Url) -AllowedDomains $allowedDomains)) {
        throw 'Производитель вернул ссылку на недопустимый домен. Загрузка заблокирована.'
    }
    return $driver
}
