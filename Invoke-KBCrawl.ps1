#requires -Version 5.1
<#
.SYNOPSIS
    Crawl a website and save HTML pages, optionally downloading linked assets.
.DESCRIPTION
    Uses Invoke-WebRequest. Crawling is restricted to the starting origin unless
    -IncludeSubdomains is supplied. -SourceOnly downloads HTML pages only.
    Use only against sites you own or are authorized to archive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)]
    [ValidateNotNullOrEmpty()]
    [uri]$Url,

    [ValidateRange(0,20)]
    [int]$Depth = 2,

    [string]$OutputDirectory = (Join-Path (Get-Location) 'KnowledgeBase-Download'),

    [switch]$SourceOnly,

    [switch]$UseDefaultCredentials,

    [ValidateRange(0,60)]
    [int]$DelaySeconds = 1,

    [ValidateRange(1,100000)]
    [int]$MaxPages = 2000,

    [switch]$IncludeSubdomains,

    [switch]$AllowInsecureTls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Url.Scheme -notin @('http','https')) {
    throw 'Only HTTP and HTTPS URLs are supported.'
}
$script:StartHost = $Url.Host
$script:StartPort = $Url.Port
$script:Visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:Queue = [System.Collections.Generic.Queue[object]]::new()
$script:Failures = [System.Collections.Generic.List[object]]::new()
$script:Manifest = [System.Collections.Generic.List[object]]::new()
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force

function Get-CanonicalUrl([uri]$Target) {
    $builder = [System.UriBuilder]::new($Target)
    $builder.Fragment = ''
    return $builder.Uri.AbsoluteUri
}

function Test-SameSite([uri]$Candidate) {
    if ($Candidate.Scheme -notin @('http','https')) { return $false }
    if ($IncludeSubdomains) {
        return ($Candidate.Host -eq $script:StartHost -or
            $Candidate.Host.EndsWith('.' + $script:StartHost, [StringComparison]::OrdinalIgnoreCase))
    }
    return ($Candidate.Host -eq $script:StartHost -and $Candidate.Port -eq $script:StartPort)
}

function Get-LocalPath([uri]$Target, [switch]$Asset) {
    $relative = [uri]::UnescapeDataString($Target.AbsolutePath.TrimStart('/'))
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.EndsWith('/')) {
        $relative = $relative + 'index'
    }
    $relative = $relative -replace '[<>:"/\\|?*]', '_'
    $extension = [IO.Path]::GetExtension($relative)
    if (-not $extension) {
        $relative += '.html'
    }

    if ($Target.Query) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Target.Query)
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8)
        } finally {
            $sha.Dispose()
        }
        $directory = [IO.Path]::GetDirectoryName($relative)
        $leaf = [IO.Path]::GetFileNameWithoutExtension($relative)
        $ext = [IO.Path]::GetExtension($relative)
        $relative = [IO.Path]::Combine($directory, ($leaf + '_' + $hash + $ext))
    }

    $full = [IO.Path]::GetFullPath((Join-Path $OutputDirectory $relative))
    $rootPath = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resolved output path escaped the output directory.'
    }
    return $full
}

function Invoke-WebRequestCompat([uri]$Target, [string]$OutFile) {
    $request = @{
        Uri = $Target
        Method = 'GET'
        MaximumRedirection = 10
        ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $request.UseBasicParsing = $true
    }
    if ($UseDefaultCredentials) { $request.UseDefaultCredentials = $true }
    if ($AllowInsecureTls -and $PSVersionTable.PSVersion.Major -ge 6) {
        $request.SkipCertificateCheck = $true
    } elseif ($AllowInsecureTls) {
        Write-Warning 'AllowInsecureTls is unavailable in Windows PowerShell 5.1; certificate validation remains enabled.'
    }
    if ($OutFile) {
        $parent = Split-Path -Parent $OutFile
        $null = New-Item -ItemType Directory -Path $parent -Force
        $request.OutFile = $OutFile
        Invoke-WebRequest @request | Out-Null
        return $null
    }
    return Invoke-WebRequest @request
}

function Get-ExtractedLinks([string]$Html, [uri]$BaseUri) {
    # In source-only mode, only follow href links; never enqueue script/image/media src URLs.
    if ($SourceOnly) {
        $attributePattern = '(?is)\bhref\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))'
    } else {
        $attributePattern = '(?is)\b(?:href|src)\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))'
    }

    foreach ($match in [regex]::Matches($Html, $attributePattern)) {
        $raw = $match.Groups[1].Value
        if (-not $raw) { $raw = $match.Groups[2].Value }
        if (-not $raw) { $raw = $match.Groups[3].Value }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $raw = $raw.Trim()
        if ($raw.StartsWith('#') -or $raw -match '^(?i:javascript|mailto|tel|data):') { continue }

        try {
            $candidate = [uri]::new($BaseUri, $raw)
            if (Test-SameSite $candidate) {
                $kind = 'Page'
                if (-not $SourceOnly -and $candidate.AbsolutePath -match '(?i)\.(css|js|mjs|png|jpe?g|gif|svg|webp|ico|woff2?|ttf|eot|pdf|zip|mp4|mp3|json|xml)$') {
                    $kind = 'Asset'
                }
                if ($SourceOnly -and $candidate.AbsolutePath -match '(?i)\.(css|js|mjs|png|jpe?g|gif|svg|webp|ico|woff2?|ttf|eot|pdf|zip|mp4|mp3|json|xml)$') {
                    continue
                }
                [pscustomobject]@{ Uri = [uri](Get-CanonicalUrl $candidate); Kind = $kind }
            }
        } catch {
            # Ignore malformed or unsupported links.
        }
    }
}

$script:Queue.Enqueue([pscustomobject]@{ Uri = [uri](Get-CanonicalUrl $Url); Level = 0; Kind = 'Page' })
$downloadedPages = 0
$downloadedAssets = 0

while ($script:Queue.Count -gt 0 -and $downloadedPages -lt $MaxPages) {
    $item = $script:Queue.Dequeue()
    $current = [uri]$item.Uri
    $canonical = Get-CanonicalUrl $current
    if (-not $script:Visited.Add($canonical)) { continue }

    try {
        if ($DelaySeconds -gt 0 -and ($downloadedPages + $downloadedAssets) -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }

        $localFile = Get-LocalPath -Target $current
        if ($item.Kind -eq 'Asset') {
            $assetFile = Get-LocalPath -Target $current -Asset
            Write-Host "Asset: $canonical"
            Invoke-WebRequestCompat -Target $current -OutFile $assetFile
            $downloadedAssets++
            $script:Manifest.Add([pscustomobject]@{
                Url=$canonical; File=$assetFile; Depth=$item.Level; Type='Asset'; Status='Downloaded'
            })
            continue
        }

        Write-Host ("Page {0}/{1}: {2}" -f ($downloadedPages + 1), $MaxPages, $canonical) -ForegroundColor Cyan
        $response = Invoke-WebRequestCompat -Target $current -OutFile $null
        $contentType = [string]$response.Headers['Content-Type']
        if ($contentType -and $contentType -notmatch 'text/html|application/xhtml\+xml') {
            continue
        }

        $parent = Split-Path -Parent $localFile
        $null = New-Item -ItemType Directory -Path $parent -Force
        [IO.File]::WriteAllText($localFile, [string]$response.Content, [Text.UTF8Encoding]::new($false))
        $downloadedPages++
        $script:Manifest.Add([pscustomobject]@{
            Url=$canonical; File=$localFile; Depth=$item.Level; Type='HTML'; Status='Downloaded'
        })

        if ($item.Level -lt $Depth) {
            foreach ($link in (Get-ExtractedLinks -Html ([string]$response.Content) -BaseUri $current)) {
                $nextUrl = Get-CanonicalUrl $link.Uri
                if (-not $script:Visited.Contains($nextUrl)) {
                    $nextLevel = $item.Level
                    if ($link.Kind -eq 'Page') { $nextLevel = $item.Level + 1 }
                    $script:Queue.Enqueue([pscustomobject]@{
                        Uri=[uri]$nextUrl; Level=$nextLevel; Kind=$link.Kind
                    })
                }
            }
        }
    } catch {
        $script:Failures.Add([pscustomobject]@{ Url=$canonical; Error=$_.Exception.Message })
        Write-Warning ("Failed: {0} -- {1}" -f $canonical, $_.Exception.Message)
    }
}

$script:Manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputDirectory 'crawl-manifest.csv')
$script:Failures | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputDirectory 'crawl-errors.csv')
Write-Host ("Finished. HTML pages: {0}; assets: {1}; failures: {2}; output: {3}" -f
    $downloadedPages, $downloadedAssets, $script:Failures.Count, (Resolve-Path $OutputDirectory)) -ForegroundColor Green

if ($downloadedPages -ge $MaxPages -and $script:Queue.Count -gt 0) {
    Write-Warning "MaxPages limit ($MaxPages) reached; some queued items were not processed."
}
