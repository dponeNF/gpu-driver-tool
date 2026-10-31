#requires -Version 5.1

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

function Get-WebContent([string]$Url) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return (Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers @{ 'User-Agent' = $userAgent } -TimeoutSec 90).Content
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    throw $lastError
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
    [xml]$xml = Get-WebContent 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=4'
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

    [xml]$xml = Get-WebContent 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
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
            try { $json = (Get-WebContent "$endpoint`?$query") | ConvertFrom-Json } catch { continue }
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
    $supportHtml = Get-WebContent 'https://www.amd.com/en/support/download/drivers.html'
    $products = @(Get-AmdProductList $supportHtml)
    $product = Find-BestMatch $products $Name 'Title'
    $build = [Environment]::OSVersion.Version.Build
    $info = $null

    if ($product) {
        try {
            $page = Get-WebContent $product.Url
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
        $note = 'Точный пакет для модели не найден: скачивается официальная утилита AMD Auto-Detect, которая сама подберёт драйвер.'
    } elseif ($info.IsAuto) {
        $note = 'Для этой модели AMD предлагает только утилиту Auto-Detect: точный драйвер она определит при запуске.'
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

function Get-GpuController([string]$Name) {
    if ($Name) {
        if ($Name -match '(?i)NVIDIA') { $vendor = 'NVIDIA' }
        elseif ($Name -match '(?i)AMD|Radeon') { $vendor = 'AMD' }
        else { throw "Неподдерживаемая видеокарта: $Name" }
        return [pscustomobject]@{ Name = $Name; Vendor = $vendor }
    }

    $controllers = @(Get-CimInstance Win32_VideoController | Where-Object {
        $_.Name -and $_.Name -notmatch '(?i)Microsoft Basic|Remote|Virtual|Parsec'
    })
    $gpu = $controllers | Where-Object { $_.Name -match '(?i)NVIDIA' } | Select-Object -First 1
    if (-not $gpu) { $gpu = $controllers | Where-Object { $_.Name -match '(?i)AMD|Radeon' } | Select-Object -First 1 }
    if (-not $gpu) { throw 'Видеокарта AMD или NVIDIA не найдена.' }
    $vendor = if ($gpu.Name -match '(?i)NVIDIA') { 'NVIDIA' } else { 'AMD' }
    return [pscustomobject]@{ Name = $gpu.Name; Vendor = $vendor }
}

function Get-GpuDriverInfo([string]$Name) {
    if ($Name -match '(?i)NVIDIA') { return Get-NvidiaDriver $Name }
    if ($Name -match '(?i)AMD|Radeon') { return Get-AmdDriver $Name }
    throw "Неподдерживаемая видеокарта: $Name"
}
