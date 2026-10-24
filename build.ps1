<#
.SYNOPSIS
    Builds VoiceBeam.bat from web/ (the page the phone opens) and src/server.ps1 (the PC side).

.DESCRIPTION
    VoiceBeam.bat is a small cmd launcher followed by the PowerShell program in src/server.ps1. The page is
    assembled from web/index.html, style.css, app.js and every web/locales/<code>.json, and embedded as
    base64, so the .bat stays pure ASCII (cmd.exe and legacy code pages do not get along with UTF-8).
    Works with the Windows PowerShell 5.1 that Windows ships and with PowerShell 7.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build.ps1           # write VoiceBeam.bat
    powershell -ExecutionPolicy Bypass -File build.ps1 -Check    # exit 1 if VoiceBeam.bat is out of date
#>
param([switch]$Check, [string]$Out)

$ErrorActionPreference = 'Stop'
$Version = '0.1.0'
$MaxLength = 16384    # characters per message; src/server.ps1 must say the same ($MaxLen)
$Root = $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Header = @(
    '@echo off'
    ':: ============================================================'
    ':: VoiceBeam - double-click to start. Nothing to install.'
    '::'
    ':: Dictate on your phone (with its keyboard''s voice input), tap send, and'
    ':: the text is pasted at the cursor of whatever window is in front on this PC.'
    '::'
    ':: This file is the whole program: a tiny cmd launcher, then PowerShell'
    ':: (which Windows ships) serving the page your phone opens.'
    '::'
    ':: Open the printed "Phone URL" on a phone on the same Wi-Fi, or scan the QR'
    ':: code. Press Ctrl+C in this window to stop.'
    '::'
    ':: Source, issues and the latest version:'
    '::   https://github.com/unnamedfish2017/VoiceBeam'
    ':: ============================================================'
    'setlocal'
    'powershell -NoProfile -ExecutionPolicy Bypass -Sta -Command "$lines = Get-Content -LiteralPath ''%~f0''; $i = [array]::IndexOf($lines, ''@@PAYLOAD@@''); if ($i -lt 0) { Write-Error ''payload marker not found''; exit 1 }; $code = ($lines[($i+1)..($lines.Length-1)] -join [char]10); Invoke-Expression $code"'
    'if errorlevel 1 pause'
    'exit /b %ERRORLEVEL%'
)

function Read-Text([string]$Relative) {
    return [System.IO.File]::ReadAllText((Join-Path $Root $Relative), $Utf8)
}

# The page: one HTML file with the stylesheet, the script, the settings and every language inlined.
function Get-Page {
    $html = Read-Text 'web/index.html'
    $pattern = '/\*@(CSS|JS|CONFIG|LOCALES)@\*/'
    $found = @([regex]::Matches($html, $pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    if (($found -join ',') -ne 'CONFIG,CSS,JS,LOCALES') {
        throw 'web/index.html must contain each of the CSS, JS, CONFIG and LOCALES placeholders exactly once'
    }
    $names = [string[]]@(Get-ChildItem -LiteralPath (Join-Path $Root 'web/locales') -Filter '*.json' | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $locales = @($names | ForEach-Object {
        '"' + [System.IO.Path]::GetFileNameWithoutExtension($_) + '":' + (Read-Text ('web/locales/' + $_)).Trim()
    }) -join ','
    $values = @{
        CSS     = Read-Text 'web/style.css'
        JS      = Read-Text 'web/app.js'
        CONFIG  = '{"maxLength":' + $MaxLength + ',"version":"' + $Version + '","theme":null,"demo":false}'
        LOCALES = ('{' + $locales + '}').Replace('<', '<')   # nothing in it may close the <script>
    }
    # One pass: text inserted for one placeholder is never scanned for the others.
    return [regex]::Replace($html, $pattern, { param($m) $values[$m.Groups[1].Value] })
}

function Get-Bat {
    $payload = Read-Text 'src/server.ps1'
    if ($payload -notmatch '(?m)^\$MaxLen = (\d+)\r?$') { throw 'src/server.ps1 has no "$MaxLen = <number>" line' }
    if ([int]$Matches[1] -ne $MaxLength) { throw ('src/server.ps1 says $MaxLen = ' + $Matches[1] + ' but build.ps1 says ' + $MaxLength) }
    $page = [System.Convert]::ToBase64String($Utf8.GetBytes((Get-Page)))
    $payload = $payload.Replace('@@PAGE_BASE64@@', $page).Replace('@@VERSION@@', $Version)
    $left = @([regex]::Matches($payload, '@@[A-Z_0-9]+@@') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($left.Count) { throw ('unfilled placeholders in src/server.ps1: ' + ($left -join ', ')) }
    $text = ($Header -join "`n") + "`n@@PAYLOAD@@`n" + $payload
    $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    if ($text -match '[^\x00-\x7F]') { throw 'VoiceBeam.bat must be pure ASCII (a non-ASCII character slipped into src/server.ps1)' }
    return [System.Text.Encoding]::ASCII.GetBytes($text)
}

$built = Get-Bat
$target = if ($Out) { $Out } else { Join-Path $Root 'VoiceBeam.bat' }
if ($Check) {
    $current = if (Test-Path -LiteralPath $target) { [System.IO.File]::ReadAllBytes($target) } else { [byte[]]@() }
    if ([System.Convert]::ToBase64String($current) -cne [System.Convert]::ToBase64String($built)) {
        Write-Host 'VoiceBeam.bat is out of date: run build.ps1'
        exit 1
    }
    Write-Host ('VoiceBeam.bat is up to date ({0} bytes)' -f $built.Length)
    exit 0
}
[System.IO.File]::WriteAllBytes($target, $built)
Write-Host ('wrote {0} ({1} bytes)' -f $target, $built.Length)
