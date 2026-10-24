<#
.SYNOPSIS
    Tests VoiceBeam.bat: the file itself, and the real server inside it.

.DESCRIPTION
    Runs with the Windows PowerShell 5.1 that Windows ships and with PowerShell 7 (Windows, macOS, Linux).
    No modules needed. The server is the PowerShell program embedded in VoiceBeam.bat, started for real;
    only its last step - pasting into the window in front, which needs a Windows desktop - is replaced by
    a stub that writes what it was given to a log.

    This file is pure ASCII on purpose (Windows PowerShell reads a .ps1 without a BOM in the ANSI code
    page), so the non-ASCII test text is built from character codes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests/run.ps1
    pwsh -File tests/run.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Failed = 0
$script:Passed = 0

function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        $script:Passed++
        Write-Host ('PASS  ' + $Name)
    } else {
        $script:Failed++
        Write-Host ('FAIL  ' + $Name + $(if ($Detail) { '  [' + $Detail + ']' } else { '' }))
    }
}

# ---------- the file ----------

$batPath = Join-Path $Root 'VoiceBeam.bat'
$raw = [System.IO.File]::ReadAllBytes($batPath)
$text = [System.Text.Encoding]::ASCII.GetString($raw)
$fresh = [System.IO.Path]::GetTempFileName()
& (Join-Path $Root 'build.ps1') -Out $fresh *> $null
Check 'VoiceBeam.bat is what build.ps1 makes from web/ and src/server.ps1' (([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fresh))) -ceq ([System.Convert]::ToBase64String($raw)))
Remove-Item -LiteralPath $fresh
Check 'it is pure ASCII' (-not ([System.Text.Encoding]::UTF8.GetString($raw) -match '[^\x00-\x7F]'))
Check 'every line ends in CR LF (cmd.exe wants that)' (([regex]::Matches($text, "`n")).Count -eq ([regex]::Matches($text, "`r`n")).Count)
$lines = $text -split "`r`n"
Check 'there is exactly one payload marker line' (@($lines | Where-Object { $_ -ceq '@@PAYLOAD@@' }).Count -eq 1)
Check 'the launcher pauses on errors instead of flashing shut' ($text.Contains('if errorlevel 1 pause'))
$payload = ($lines[([array]::IndexOf($lines, '@@PAYLOAD@@') + 1)..($lines.Length - 1)]) -join "`n"
$encoded = [regex]::Match($payload, "FromBase64String\('([A-Za-z0-9+/=]+)'\)").Groups[1].Value
$page = $Utf8.GetString([System.Convert]::FromBase64String($encoded))
Check 'the embedded page is a whole HTML document' ($page.StartsWith('<!doctype html>') -and $page.TrimEnd().EndsWith('</html>'))
Check 'no placeholder was left in the page' (-not $page.Contains('/*@'))

# ---------- the server ----------

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('voicebeam-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$log = Join-Path $work 'pasted.jsonl'
[System.IO.File]::WriteAllText($log, '', $Utf8)
$stub = @'
function Send-TextToForeground {
    param([string]$Text, [bool]$AppendEnter)
    if ($Text -eq 'FAIL') { throw 'Windows clipboard is busy' }
    $line = (@{ text = $Text; enter = $AppendEnter } | ConvertTo-Json -Compress) + "`n"
    [System.IO.File]::AppendAllText($env:VB_LOG, $line, (New-Object System.Text.UTF8Encoding($false)))
}
'@
$harness = $payload.Replace("Add-Type -AssemblyName System.Windows.Forms`n", '').Replace("`$Port = 8123`n", "`$Port = $port`n").Replace("`$listener = `$null`n", $stub + "`n`$listener = `$null`n")
$harnessPath = Join-Path $work 'server.ps1'
[System.IO.File]::WriteAllText($harnessPath, $harness, [System.Text.Encoding]::ASCII)

$env:VB_LOG = $log
$shell = (Get-Process -Id $PID).Path
$server = Start-Process -FilePath $shell -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $work 'out.txt') -RedirectStandardError (Join-Path $work 'err.txt') `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $harnessPath + '"'))

function Send-Request([string]$Method, [string]$Path, $Body = $null, [hashtable]$Headers = @{}) {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
    try {
        $stream = $client.GetStream()
        $bodyBytes = if ($null -ne $Body) { $Utf8.GetBytes([string]$Body) } else { [byte[]]@() }
        $all = [ordered]@{ 'Host' = "127.0.0.1:$port"; 'Connection' = 'close' }
        if ($null -ne $Body) { $all['Content-Type'] = 'application/json'; $all['Content-Length'] = [string]$bodyBytes.Length }
        foreach ($key in $Headers.Keys) { $all[$key] = $Headers[$key] }
        $head = "$Method $Path HTTP/1.1`r`n"
        foreach ($key in $all.Keys) { $head += $key + ': ' + $all[$key] + "`r`n" }
        $head += "`r`n"
        $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($headBytes, 0, $headBytes.Length)
        if ($bodyBytes.Length) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        $response = $buffer.ToArray()
    } finally {
        $client.Close()
    }
    $split = 0
    for ($i = 0; $i -lt $response.Length - 3; $i++) {
        if ($response[$i] -eq 13 -and $response[$i + 1] -eq 10 -and $response[$i + 2] -eq 13 -and $response[$i + 3] -eq 10) { $split = $i; break }
    }
    $status = [int](([System.Text.Encoding]::ASCII.GetString($response, 0, $split) -split ' ')[1])
    $content = $Utf8.GetString($response, $split + 4, $response.Length - $split - 4)
    $json = $null
    try { $json = $content | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Status = $status; Text = $content; Json = $json }
}

function Get-Pasted {
    return @([System.IO.File]::ReadAllLines($log, $Utf8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

try {
    $deadline = (Get-Date).AddSeconds(90)
    $up = $false
    while (-not $up -and (Get-Date) -lt $deadline) {
        if ($server.HasExited) { break }
        try { (New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)).Close(); $up = $true } catch { Start-Sleep -Milliseconds 300 }
    }
    Check 'the server starts' $up ('see ' + $work)
    if (-not $up) { throw 'the server did not start' }

    $r = Send-Request 'GET' '/'
    Check 'GET / serves the embedded page' ($r.Status -eq 200 -and $r.Text -ceq $page) ('HTTP ' + $r.Status)
    Check 'a query string is ignored' ((Send-Request 'GET' '/?from=qr').Status -eq 200)
    $r = Send-Request 'GET' '/api/health'
    Check 'GET /api/health' ($r.Status -eq 200 -and $r.Json.ok -and $r.Json.service -eq 'voicebeam' -and $r.Json.demo -eq $false)
    Check 'GET /favicon.ico is empty, not an error' ((Send-Request 'GET' '/favicon.ico').Status -eq 204)
    $r = Send-Request 'GET' '/nope'
    Check 'an unknown path is a 404 with a code' ($r.Status -eq 404 -and $r.Json.code -eq 'not_found')

    $hello = (-join @([char]0x4F60, [char]0x597D)) + "`n" + 'line 2 ' + [char]::ConvertFromUtf32(0x1F600)
    $r = Send-Request 'POST' '/api/send' ((@{ text = $hello } | ConvertTo-Json -Compress))
    Check 'Chinese text, a new line and an emoji are delivered, Enter by default' ($r.Status -eq 200 -and $r.Json.ok) $r.Text
    $r = Send-Request 'POST' '/api/send' '{"text":"no enter","append_enter":false}'
    $pasted = Get-Pasted
    Check 'the pasted text is exactly what was sent' ($pasted.Count -eq 2 -and $pasted[0].text -ceq $hello -and $pasted[0].enter -eq $true)
    Check 'Enter can be turned off' ($pasted[1].text -eq 'no enter' -and $pasted[1].enter -eq $false)

    foreach ($body in @('{"text":""}', '{"text":"  \n"}', '{"text":5}', '{}')) {
        $r = Send-Request 'POST' '/api/send' $body
        Check ('blank text is refused: ' + $body) ($r.Status -eq 400 -and $r.Json.code -eq 'empty')
    }
    $r = Send-Request 'POST' '/api/send' '{"text":"x","append_enter":"yes"}'
    Check 'append_enter must be true or false' ($r.Status -eq 400 -and $r.Json.code -eq 'bad_type')
    foreach ($body in @('not json', '[1, 2]', '"text"')) {
        $r = Send-Request 'POST' '/api/send' $body
        Check ('malformed JSON is refused: ' + $body) ($r.Status -eq 400 -and $r.Json.code -eq 'bad_json')
    }
    $r = Send-Request 'POST' '/api/send' ('{"text":"' + ('a' * 16384) + '"}')
    Check 'exactly 16384 characters are fine' ($r.Status -eq 200)
    $r = Send-Request 'POST' '/api/send' ('{"text":"' + ([char]::ConvertFromUtf32(0x1F600) * 16384) + '"}')
    Check '16384 emoji count as 16384 characters' ($r.Status -eq 200)
    $r = Send-Request 'POST' '/api/send' ('{"text":"' + ('a' * 16385) + '"}')
    Check 'one more is refused, with the limit' ($r.Status -eq 400 -and $r.Json.code -eq 'too_long' -and $r.Json.max -eq 16384)
    $r = Send-Request 'POST' '/api/send' $null @{ 'Content-Type' = 'application/json'; 'Content-Length' = [string](16384 * 12 + 257) }
    Check 'an oversized body is refused before it is read' ($r.Status -eq 413 -and $r.Json.code -eq 'body_too_large')

    $before = (Get-Pasted).Count
    $r = Send-Request 'POST' '/api/send' '{"text":"x"}' @{ 'Content-Type' = 'text/plain' }
    Check 'other websites: a text/plain post is refused' ($r.Status -eq 415 -and $r.Json.code -eq 'bad_content_type')
    $r = Send-Request 'POST' '/api/send' '{"text":"x"}' @{ 'Origin' = 'http://evil.example' }
    Check 'other websites: a foreign Origin is refused' ($r.Status -eq 403 -and $r.Json.code -eq 'bad_origin')
    $r = Send-Request 'POST' '/api/send' '{"text":"x"}' @{ 'Origin' = 'null' }
    Check 'other websites: Origin null is refused' ($r.Status -eq 403 -and $r.Json.code -eq 'bad_origin')
    $r = Send-Request 'POST' '/api/send' '{"text":"x"}' @{ 'Host' = "evil.example:$port" }
    Check 'DNS rebinding: a made-up host name is refused' ($r.Status -eq 403 -and $r.Json.code -eq 'bad_host')
    Check 'none of those reached the clipboard' ((Get-Pasted).Count -eq $before)
    $r = Send-Request 'POST' '/api/send' '{"text":"same site"}' @{ 'Origin' = "http://127.0.0.1:$port" }
    Check 'the page itself (same origin) is allowed' ($r.Status -eq 200)

    $r = Send-Request 'POST' '/api/send' '{"text":"FAIL"}'
    Check 'a failed paste is reported, not swallowed' ($r.Status -eq 500 -and $r.Json.code -eq 'paste_failed' -and $r.Json.error -eq 'Windows clipboard is busy') $r.Text
} finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Passed, $script:Failed)
if ($script:Failed) { exit 1 }
exit 0
