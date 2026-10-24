@echo off
:: ============================================================
:: VoiceBeam - double-click to start. Nothing to install.
::
:: Dictate on your phone (with its keyboard's voice input), tap send, and
:: the text is pasted at the cursor of whatever window is in front on this PC.
::
:: This file is the whole program: a tiny cmd launcher, then PowerShell
:: (which Windows ships) serving the page your phone opens.
::
:: Open the printed "Phone URL" on a phone on the same Wi-Fi, or scan the QR
:: code. Press Ctrl+C in this window to stop.
::
:: Source, issues and the latest version:
::   https://github.com/unnamedfish2017/VoiceBeam
:: ============================================================
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Sta -Command "$lines = Get-Content -LiteralPath '%~f0'; $i = [array]::IndexOf($lines, '@@PAYLOAD@@'); if ($i -lt 0) { Write-Error 'payload marker not found'; exit 1 }; $code = ($lines[($i+1)..($lines.Length-1)] -join [char]10); Invoke-Expression $code"
if errorlevel 1 pause
exit /b %ERRORLEVEL%
@@PAYLOAD@@
Add-Type -AssemblyName System.Windows.Forms

$Port = 8123
$MaxLen = 16384

# ---- QR encoder (Byte mode, EC level M, versions 1-6) ----
# Ported from a from-spec Python reference that was cross-checked bit-exact
# against the qrcode PyPI package and verified with a real QR decoder
# (OpenCV QRCodeDetector) before porting; this PowerShell port was in turn
# verified bit-exact identical to that Python reference, module for module,
# for every test string tried. No external QR library or network call.

$Script:QrExpTable = New-Object int[] 256
$Script:QrLogTable = New-Object int[] 256
for ($i = 0; $i -lt 8; $i++) { $Script:QrExpTable[$i] = 1 -shl $i }
for ($i = 8; $i -lt 255; $i++) {
    $Script:QrExpTable[$i] = $Script:QrExpTable[$i-4] -bxor $Script:QrExpTable[$i-5] -bxor $Script:QrExpTable[$i-6] -bxor $Script:QrExpTable[$i-8]
}
$Script:QrExpTable[255] = $Script:QrExpTable[0]
for ($i = 0; $i -lt 255; $i++) { $Script:QrLogTable[$Script:QrExpTable[$i]] = $i }

function QrGexp([int]$n) {
    $m = $n % 255
    if ($m -lt 0) { $m += 255 }
    return $Script:QrExpTable[$m]
}
function QrGlog([int]$n) { return $Script:QrLogTable[$n] }

function QrPolyMul([int[]]$a, [int[]]$b) {
    $num = New-Object int[] ($a.Length + $b.Length - 1)
    for ($i = 0; $i -lt $a.Length; $i++) {
        if ($a[$i] -eq 0) { continue }
        $la = QrGlog $a[$i]
        for ($j = 0; $j -lt $b.Length; $j++) {
            if ($b[$j] -eq 0) { continue }
            $num[$i+$j] = $num[$i+$j] -bxor (QrGexp ($la + (QrGlog $b[$j])))
        }
    }
    return $num
}

function QrPolyTrim([int[]]$num) {
    $offset = 0
    while ($offset -lt $num.Length - 1 -and $num[$offset] -eq 0) { $offset++ }
    if ($offset -eq 0) { return $num }
    return $num[$offset..($num.Length-1)]
}

function QrPolyMod([int[]]$a, [int[]]$b) {
    $cur = QrPolyTrim $a
    while ($true) {
        $diff = $cur.Length - $b.Length
        if ($diff -lt 0) { return $cur }
        $ratio = (QrGlog $cur[0]) - (QrGlog $b[0])
        $num = New-Object int[] $cur.Length
        for ($i = 0; $i -lt $b.Length; $i++) {
            $num[$i] = $cur[$i] -bxor (QrGexp ((QrGlog $b[$i]) + $ratio))
        }
        for ($i = $b.Length; $i -lt $cur.Length; $i++) { $num[$i] = $cur[$i] }
        $cur = QrPolyTrim $num
    }
}

# RS_BLOCK_TABLE rows for versions 1-6, EC order L,M,Q,H (flattened triples)
$Script:QrRsBlockTable = @(
    ,@(1,26,19)  ,@(1,26,16)  ,@(1,26,13)  ,@(1,26,9),
    ,@(1,44,34)  ,@(1,44,28)  ,@(1,44,22)  ,@(1,44,16),
    ,@(1,70,55)  ,@(1,70,44)  ,@(2,35,17)  ,@(2,35,13),
    ,@(1,100,80) ,@(2,50,32)  ,@(2,50,24)  ,@(4,25,9),
    ,@(1,134,108),@(2,67,43)  ,@(2,33,15,2,34,16),@(2,33,11,2,34,12),
    ,@(2,86,68)  ,@(4,43,27)  ,@(4,43,19)  ,@(4,43,15)
)
$Script:QrEcPerBlock = @(7,10,13,17, 10,16,22,28, 15,26,18,22, 20,18,26,16, 26,24,18,22, 18,16,24,28)
$Script:QrEcOffset = @{ L = 0; M = 1; Q = 2; H = 3 }
$Script:QrPatternPositionTable = @(
    @(),
    @(6,18),
    @(6,22),
    @(6,26),
    @(6,30),
    @(6,34),
    @(6,22,38)
)

$Script:QrG15 = (1 -shl 10) -bor (1 -shl 8) -bor (1 -shl 5) -bor (1 -shl 4) -bor (1 -shl 2) -bor (1 -shl 1) -bor (1 -shl 0)
$Script:QrG18 = (1 -shl 12) -bor (1 -shl 11) -bor (1 -shl 10) -bor (1 -shl 9) -bor (1 -shl 8) -bor (1 -shl 5) -bor (1 -shl 2) -bor (1 -shl 0)
$Script:QrG15Mask = (1 -shl 14) -bor (1 -shl 12) -bor (1 -shl 10) -bor (1 -shl 4) -bor (1 -shl 1)

function QrBchDigit([long]$data) {
    $d = 0
    while ($data -ne 0) { $d++; $data = $data -shr 1 }
    return $d
}
function QrBchTypeInfo([int]$data) {
    $d = [long]$data -shl 10
    while ((QrBchDigit $d) - (QrBchDigit $Script:QrG15) -ge 0) {
        $d = $d -bxor ([long]$Script:QrG15 -shl ((QrBchDigit $d) - (QrBchDigit $Script:QrG15)))
    }
    return (([long]$data -shl 10) -bor $d) -bxor $Script:QrG15Mask
}
function QrBchTypeNumber([int]$data) {
    $d = [long]$data -shl 12
    while ((QrBchDigit $d) - (QrBchDigit $Script:QrG18) -ge 0) {
        $d = $d -bxor ([long]$Script:QrG18 -shl ((QrBchDigit $d) - (QrBchDigit $Script:QrG18)))
    }
    return ([long]$data -shl 12) -bor $d
}

function QrCharCountBits([int]$version) {
    if ($version -lt 10) { return 8 } else { return 16 }
}

function QrCapacityBits([int]$version, [string]$ec) {
    $offset = $Script:QrEcOffset[$ec]
    $idx = ($version - 1) * 4 + $offset
    $row = $Script:QrRsBlockTable[$idx]
    $sum = 0
    for ($i = 0; $i -lt $row.Length; $i += 3) {
        $count = $row[$i]; $dataCount = $row[$i+2]
        $sum += $count * $dataCount
    }
    return $sum * 8
}

function QrRsBlocksFor([int]$version, [string]$ec) {
    $offset = $Script:QrEcOffset[$ec]
    $idx = ($version - 1) * 4 + $offset
    $row = $Script:QrRsBlockTable[$idx]
    $ecPer = $Script:QrEcPerBlock[$idx]
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $row.Length; $i += 3) {
        $count = $row[$i]; $total = $row[$i+1]; $dataCount = $row[$i+2]
        for ($k = 0; $k -lt $count; $k++) {
            $blocks.Add(@{ total = $total; data = $dataCount })
        }
    }
    return @{ blocks = $blocks; ecPer = $ecPer }
}

function QrBitBufferNew {
    return @{ buf = (New-Object System.Collections.Generic.List[int]); length = 0 }
}
function QrBitBufferPutBit($bb, [bool]$bit) {
    $idx = [math]::Floor($bb.length / 8)
    while ($bb.buf.Count -le $idx) { $bb.buf.Add(0) }
    if ($bit) { $bb.buf[$idx] = $bb.buf[$idx] -bor (0x80 -shr ($bb.length % 8)) }
    $bb.length++
}
function QrBitBufferPut($bb, [long]$num, [int]$length) {
    for ($i = 0; $i -lt $length; $i++) {
        $bit = ((($num -shr ($length - $i - 1)) -band 1) -eq 1)
        QrBitBufferPutBit $bb $bit
    }
}

function QrCreateData([int]$version, [string]$ec, [byte[]]$dataBytes) {
    $bb = QrBitBufferNew
    QrBitBufferPut $bb 0x4 4
    QrBitBufferPut $bb $dataBytes.Length (QrCharCountBits $version)
    foreach ($b in $dataBytes) { QrBitBufferPut $bb $b 8 }

    $bitLimit = QrCapacityBits $version $ec
    $termBits = [math]::Min($bitLimit - $bb.length, 4)
    for ($i = 0; $i -lt $termBits; $i++) { QrBitBufferPutBit $bb $false }
    while (($bb.length % 8) -ne 0) { QrBitBufferPutBit $bb $false }

    $padBytesNeeded = [int](($bitLimit - $bb.length) / 8)
    for ($i = 0; $i -lt $padBytesNeeded; $i++) {
        if ($i % 2 -eq 0) { QrBitBufferPut $bb 0xEC 8 } else { QrBitBufferPut $bb 0x11 8 }
    }

    $rsInfo = QrRsBlocksFor $version $ec
    $blocks = $rsInfo.blocks
    $ecPerBlock = $rsInfo.ecPer
    $offset = 0
    $dcdata = New-Object System.Collections.Generic.List[object]
    $ecdata = New-Object System.Collections.Generic.List[object]
    $maxDc = 0

    $rsPolyBase = @(1)
    for ($i = 0; $i -lt $ecPerBlock; $i++) {
        $rsPolyBase = QrPolyMul $rsPolyBase @(1, (QrGexp $i))
    }

    foreach ($blk in $blocks) {
        $dcCount = $blk.data
        $dc = New-Object int[] $dcCount
        for ($i = 0; $i -lt $dcCount; $i++) { $dc[$i] = $bb.buf[$offset + $i] }
        $offset += $dcCount
        if ($dcCount -gt $maxDc) { $maxDc = $dcCount }

        $raw = New-Object int[] ($dcCount + $ecPerBlock)
        for ($i = 0; $i -lt $dcCount; $i++) { $raw[$i] = $dc[$i] }
        $mod = QrPolyMod $raw $rsPolyBase
        $modOffset = $mod.Length - $ecPerBlock
        $ecArr = New-Object int[] $ecPerBlock
        for ($i = 0; $i -lt $ecPerBlock; $i++) {
            $mi = $modOffset + $i
            if ($mi -ge 0) { $ecArr[$i] = $mod[$mi] } else { $ecArr[$i] = 0 }
        }

        $dcdata.Add($dc)
        $ecdata.Add($ecArr)
    }

    $result = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $maxDc; $i++) {
        foreach ($dc in $dcdata) { if ($i -lt $dc.Length) { $result.Add($dc[$i]) } }
    }
    for ($i = 0; $i -lt $ecPerBlock; $i++) {
        foreach ($ecArr in $ecdata) { if ($i -lt $ecArr.Length) { $result.Add($ecArr[$i]) } }
    }
    return ,$result.ToArray()
}

function QrMaskFunc([int]$pattern, [int]$r, [int]$c) {
    switch ($pattern) {
        0 { return (($r + $c) % 2) -eq 0 }
        1 { return ($r % 2) -eq 0 }
        2 { return ($c % 3) -eq 0 }
        3 { return (($r + $c) % 3) -eq 0 }
        4 { return (([math]::Floor($r/2) + [math]::Floor($c/3)) % 2) -eq 0 }
        5 { return ((($r*$c) % 2) + (($r*$c) % 3)) -eq 0 }
        6 { return ((($r*$c) % 2) + (($r*$c) % 3)) % 2 -eq 0 }
        7 { return ((($r*$c) % 3) + (($r+$c) % 2)) % 2 -eq 0 }
    }
}

# `modules` is a FLAT object[] of length n*n (row-major: index = row*n+col),
# not a native .NET 2-D array. PowerShell's `$a[$x+1, $y+1] = $v` assignment
# syntax silently mis-parses a comma-separated index list that contains any
# expression (confirmed: it collapses/splits the arguments and throws
# "cannot index into a 2 dimensional array" or writes to the wrong cell) -
# flat indexing with a single subscript sidesteps that parser gotcha entirely.
function QrBuildMatrix([int]$version, [string]$ec, [int]$maskPattern, [int[]]$dataCodewords, [bool]$test) {
    $n = $version * 4 + 17
    $modules = New-Object 'object[]' ($n * $n)

    function QrSetFinder($modules, [int]$n, [int]$row, [int]$col) {
        for ($r = -1; $r -lt 8; $r++) {
            if ($row + $r -le -1 -or $n -le ($row + $r)) { continue }
            for ($c = -1; $c -lt 8; $c++) {
                if ($col + $c -le -1 -or $n -le ($col + $c)) { continue }
                $val = $false
                if ((($r -ge 0 -and $r -le 6) -and ($c -eq 0 -or $c -eq 6)) -or
                    (($c -ge 0 -and $c -le 6) -and ($r -eq 0 -or $r -eq 6)) -or
                    (($r -ge 2 -and $r -le 4) -and ($c -ge 2 -and $c -le 4))) {
                    $val = $true
                }
                $modules[($row+$r)*$n+($col+$c)] = $val
            }
        }
    }
    QrSetFinder $modules $n 0 0
    QrSetFinder $modules $n ($n-7) 0
    QrSetFinder $modules $n 0 ($n-7)

    $pos = $Script:QrPatternPositionTable[$version-1]
    foreach ($row in $pos) {
        foreach ($col in $pos) {
            if ($null -ne $modules[$row*$n+$col]) { continue }
            for ($r = -2; $r -le 2; $r++) {
                for ($c = -2; $c -le 2; $c++) {
                    $val = $false
                    if ($r -eq -2 -or $r -eq 2 -or $c -eq -2 -or $c -eq 2 -or ($r -eq 0 -and $c -eq 0)) {
                        $val = $true
                    }
                    $modules[($row+$r)*$n+($col+$c)] = $val
                }
            }
        }
    }

    for ($r = 8; $r -lt $n - 8; $r++) {
        if ($null -eq $modules[$r*$n+6]) { $modules[$r*$n+6] = (($r % 2) -eq 0) }
    }
    for ($c = 8; $c -lt $n - 8; $c++) {
        if ($null -eq $modules[6*$n+$c]) { $modules[6*$n+$c] = (($c % 2) -eq 0) }
    }

    $ecBitsMap = @{ L = 1; M = 0; Q = 3; H = 2 }
    $dataBits = ($ecBitsMap[$ec] -shl 3) -bor $maskPattern
    $bits = QrBchTypeInfo $dataBits
    for ($i = 0; $i -lt 15; $i++) {
        $mod = (-not $test) -and ((($bits -shr $i) -band 1) -eq 1)
        if ($i -lt 6) { $modules[$i*$n+8] = $mod }
        elseif ($i -lt 8) { $modules[($i+1)*$n+8] = $mod }
        else { $modules[($n-15+$i)*$n+8] = $mod }
    }
    for ($i = 0; $i -lt 15; $i++) {
        $mod = (-not $test) -and ((($bits -shr $i) -band 1) -eq 1)
        if ($i -lt 8) { $modules[8*$n+($n-$i-1)] = $mod }
        elseif ($i -lt 9) { $modules[8*$n+(15-$i-1+1)] = $mod }
        else { $modules[8*$n+(15-$i-1)] = $mod }
    }
    $modules[($n-8)*$n+8] = (-not $test)

    if ($version -ge 7) {
        $bitsV = QrBchTypeNumber $version
        for ($i = 0; $i -lt 18; $i++) {
            $mod = (-not $test) -and ((($bitsV -shr $i) -band 1) -eq 1)
            $rr = [int][math]::Floor($i/3)
            $cc = ($i % 3) + $n - 8 - 3
            $modules[$rr*$n+$cc] = $mod
        }
        for ($i = 0; $i -lt 18; $i++) {
            $mod = (-not $test) -and ((($bitsV -shr $i) -band 1) -eq 1)
            $rr = ($i % 3) + $n - 8 - 3
            $cc = [int][math]::Floor($i/3)
            $modules[$rr*$n+$cc] = $mod
        }
    }

    $inc = -1
    $row = $n - 1
    $bitIndex = 7
    $byteIndex = 0
    $dataLen = $dataCodewords.Length
    $col = $n - 1
    while ($col -gt 0) {
        if ($col -eq 6) { $col-- }
        # NOTE: `@($col, $col - 1)` mis-parses as `@($col, $col) - 1` in
        # PowerShell (comma binds tighter than binary minus here) and throws
        # "System.Object[] does not contain a method named 'op_Subtraction'"
        # - the second element must be parenthesized.
        $colRange = @($col, ($col - 1))
        while ($true) {
            foreach ($c in $colRange) {
                if ($null -eq $modules[$row*$n+$c]) {
                    $dark = $false
                    if ($byteIndex -lt $dataLen) {
                        $dark = ((($dataCodewords[$byteIndex] -shr $bitIndex) -band 1) -eq 1)
                    }
                    if (QrMaskFunc $maskPattern $row $c) { $dark = -not $dark }
                    $modules[$row*$n+$c] = $dark
                    $bitIndex--
                    if ($bitIndex -eq -1) { $byteIndex++; $bitIndex = 7 }
                }
            }
            $row += $inc
            if ($row -lt 0 -or $n -le $row) {
                $row -= $inc
                $inc = -$inc
                break
            }
        }
        $col -= 2
    }

    return $modules
}

# `modules` is the same flat row-major object[] (index = row*n+col) produced
# by QrBuildMatrix - see the comment above that function for why.
function QrLostPoint($modules, [int]$n) {
    $total = 0
    # rule 1
    $container = New-Object int[] ($n + 1)
    for ($r = 0; $r -lt $n; $r++) {
        $prev = $modules[$r*$n+0]
        $length = 0
        for ($c = 0; $c -lt $n; $c++) {
            $v = $modules[$r*$n+$c]
            if ($v -eq $prev) {
                $length++
            } else {
                if ($length -ge 5) { $container[$length]++ }
                $length = 1
                $prev = $v
            }
        }
        if ($length -ge 5) { $container[$length]++ }
    }
    for ($c = 0; $c -lt $n; $c++) {
        $prev = $modules[0*$n+$c]
        $length = 0
        for ($r = 0; $r -lt $n; $r++) {
            $v = $modules[$r*$n+$c]
            if ($v -eq $prev) {
                $length++
            } else {
                if ($length -ge 5) { $container[$length]++ }
                $length = 1
                $prev = $v
            }
        }
        if ($length -ge 5) { $container[$length]++ }
    }
    for ($l = 5; $l -le $n; $l++) { $total += $container[$l] * ($l - 2) }

    # rule 2
    for ($r = 0; $r -lt $n - 1; $r++) {
        for ($c = 0; $c -lt $n - 1; $c++) {
            $v = $modules[$r*$n+$c]
            if ($v -eq $modules[$r*$n+($c+1)] -and $v -eq $modules[($r+1)*$n+$c] -and $v -eq $modules[($r+1)*$n+($c+1)]) {
                $total += 3
            }
        }
    }

    # rule 3
    $pat1 = @($true,$false,$true,$true,$true,$false,$true,$false,$false,$false,$false)
    $pat2 = @($false,$false,$false,$false,$true,$false,$true,$true,$true,$false,$true)
    for ($r = 0; $r -lt $n; $r++) {
        for ($i = 0; $i -le $n - 11; $i++) {
            $m1 = $true; $m2 = $true
            for ($k = 0; $k -lt 11; $k++) {
                $v = $modules[$r*$n+($i+$k)]
                if ($v -ne $pat1[$k]) { $m1 = $false }
                if ($v -ne $pat2[$k]) { $m2 = $false }
                if (-not $m1 -and -not $m2) { break }
            }
            if ($m1 -or $m2) { $total += 40 }
        }
    }
    for ($c = 0; $c -lt $n; $c++) {
        for ($i = 0; $i -le $n - 11; $i++) {
            $m1 = $true; $m2 = $true
            for ($k = 0; $k -lt 11; $k++) {
                $v = $modules[($i+$k)*$n+$c]
                if ($v -ne $pat1[$k]) { $m1 = $false }
                if ($v -ne $pat2[$k]) { $m2 = $false }
                if (-not $m1 -and -not $m2) { break }
            }
            if ($m1 -or $m2) { $total += 40 }
        }
    }

    # rule 4
    $dark = 0
    for ($r = 0; $r -lt $n; $r++) { for ($c = 0; $c -lt $n; $c++) { if ($modules[$r*$n+$c]) { $dark++ } } }
    $percent = ($dark * 100.0) / ($n * $n)
    $total += [int]([math]::Floor([math]::Abs($percent - 50) / 5)) * 10

    return $total
}

function QrEncode([string]$text, [string]$ec = 'M', [int]$maxVersion = 6) {
    $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $version = -1
    for ($v = 1; $v -le $maxVersion; $v++) {
        $overhead = 4 + (QrCharCountBits $v)
        $capBits = QrCapacityBits $v $ec
        if (($overhead + $dataBytes.Length * 8) -le $capBits) { $version = $v; break }
    }
    if ($version -eq -1) { throw "data too long for QR version <= $maxVersion" }

    $codewords = QrCreateData $version $ec $dataBytes

    $bestPattern = 0
    $bestScore = $null
    for ($pattern = 0; $pattern -lt 8; $pattern++) {
        $m = QrBuildMatrix $version $ec $pattern $codewords $true
        $score = QrLostPoint $m ($version*4+17)
        if ($null -eq $bestScore -or $score -lt $bestScore) {
            $bestScore = $score
            $bestPattern = $pattern
        }
    }

    $finalModules = QrBuildMatrix $version $ec $bestPattern $codewords $false
    return @{ version = $version; pattern = $bestPattern; modules = $finalModules; size = ($version*4+17) }
}

function QrRenderAscii($modules, [int]$n, [int]$border = 1) {
    $useBlock = $false
    try {
        $enc = [Console]::OutputEncoding.WebName
        if ($enc -and $enc.ToLower().Contains('utf-8')) { $useBlock = $true }
    } catch {}
    # Consoles are dark by default (cmd, PowerShell, Windows Terminal), so the *light* cells are the
    # filled blocks and the dark modules are left empty: dark on light, which every scanner reads.
    $filled = if ($useBlock) { [string]([char]0x2588) + [string]([char]0x2588) } else { '##' }
    $empty = '  '
    $sb = New-Object System.Text.StringBuilder
    for ($r = -$border; $r -lt $n + $border; $r++) {
        for ($c = -$border; $c -lt $n + $border; $c++) {
            $v = $false
            if ($r -ge 0 -and $r -lt $n -and $c -ge 0 -and $c -lt $n) { $v = [bool]$modules[$r*$n+$c] }
            if ($v) { [void]$sb.Append($empty) } else { [void]$sb.Append($filled) }
        }
        [void]$sb.Append([Environment]::NewLine)
    }
    return $sb.ToString()
}

# Solid squares in any console: two spaces per module, drawn with a background colour. Unlike block
# characters this needs no UTF-8 console, no particular font and no code page - a Chinese Windows
# (GBK) used to get "##" signs from the character version below.
function QrWriteSolid($modules, [int]$n, [int]$border = 2) {
    for ($r = -$border; $r -lt $n + $border; $r++) {
        $c = -$border
        while ($c -lt $n + $border) {
            $start = $c
            $dark = $false
            if ($r -ge 0 -and $r -lt $n -and $c -ge 0 -and $c -lt $n) { $dark = [bool]$modules[$r*$n+$c] }
            while ($c -lt $n + $border) {
                $v = $false
                if ($r -ge 0 -and $r -lt $n -and $c -ge 0 -and $c -lt $n) { $v = [bool]$modules[$r*$n+$c] }
                if ($v -ne $dark) { break }
                $c++
            }
            $colour = if ($dark) { 'Black' } else { 'White' }
            Write-Host (' ' * (2 * ($c - $start))) -NoNewline -BackgroundColor $colour
        }
        Write-Host ''
    }
}

# Two modules per text row: a lower half block drawn in the colour of the lower module on a background
# in the colour of the upper one. Half as tall as QrWriteSolid, so a v3 code (29 modules + quiet zone)
# takes 17 lines and fits the default 30-line window with room to spare.
# (U+2584 rather than the upper half block: it is in the GBK code page, so Chinese console fonts have it.)
function QrDark($modules, [int]$n, [int]$r, [int]$c) {
    if ($r -lt 0 -or $r -ge $n -or $c -lt 0 -or $c -ge $n) { return $false }
    return [bool]$modules[$r*$n+$c]
}
function QrWriteHalf($modules, [int]$n, [int]$border = 2) {
    $half = [string][char]0x2584
    for ($r = -$border; $r -lt $n + $border; $r += 2) {
        $c = -$border
        while ($c -lt $n + $border) {
            $upper = QrDark $modules $n $r $c
            $lower = QrDark $modules $n ($r + 1) $c
            $start = $c
            while ($c -lt $n + $border -and (QrDark $modules $n $r $c) -eq $upper -and (QrDark $modules $n ($r + 1) $c) -eq $lower) { $c++ }
            $fg = if ($lower) { 'Black' } else { 'White' }
            $bg = if ($upper) { 'Black' } else { 'White' }
            Write-Host ($half * ($c - $start)) -NoNewline -ForegroundColor $fg -BackgroundColor $bg
        }
        Write-Host ''
    }
}

# half  - block characters are drawn one cell wide: Windows Terminal, and most consoles.
# full  - the classic console with a Chinese/Japanese/Korean code page and font draws them two cells wide,
#         which would stretch the code; there it is drawn with coloured spaces, and the window is made tall
#         enough to show all of it.
# text  - output redirected to a file or a pipe.
# The width is measured, not guessed: one half block is printed and the cursor movement read back, then
# wiped. (Guessing from WT_SESSION fails exactly where it matters: Windows 11 hands a double-clicked .bat
# over to Windows Terminal without setting it, while the code page still says 936.)
# VOICEBEAM_QR=half or VOICEBEAM_QR=full overrides all of this.
function QrMode {
    $forced = [string]$env:VOICEBEAM_QR
    if ($forced -eq 'half' -or $forced -eq 'full') { return $forced }
    if ([Console]::IsOutputRedirected) { return 'text' }
    try {
        $before = [Console]::CursorLeft
        [Console]::Write([string][char]0x2584)
        $width = [Console]::CursorLeft - $before
        [Console]::Write("`r" + (' ' * ($before + 2)) + "`r")
        if ($width -eq 1) { return 'half' }
        if ($width -ge 2) { return 'full' }
    } catch {}
    if ($env:WT_SESSION) { return 'half' }
    $codePage = 0
    try { $codePage = [Console]::OutputEncoding.CodePage } catch {}
    if (@(932, 936, 949, 950) -contains $codePage) { return 'full' }
    return 'half'
}

# Make the console window at least $rows lines tall (as tall as the screen allows). Only the classic console
# can do this; Windows Terminal and redirected output simply refuse, which is fine.
function Grow-ConsoleFor([int]$rows) {
    try {
        $raw = $Host.UI.RawUI
        $want = [Math]::Min($rows, $raw.MaxPhysicalWindowSize.Height)
        if ($raw.WindowSize.Height -ge $want) { return }
        if ($raw.BufferSize.Height -lt $want) {
            $raw.BufferSize = New-Object System.Management.Automation.Host.Size($raw.BufferSize.Width, $want)
        }
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size($raw.WindowSize.Width, $want)
    } catch {}
}

function Show-PhoneQrCode([string]$url) {
    try {
        $r = QrEncode $url 'M' 6
        $mode = QrMode
        if ($mode -eq 'full') { Grow-ConsoleFor ($r.size + 4 + 12) }   # the code plus the lines around it
        Write-Host ''
        Write-Host 'Scan this with your phone to open the input page:'
        Write-Host ''
        if ($mode -eq 'text') {
            Write-Host (QrRenderAscii $r.modules $r.size 2)   # a file or a pipe has no colours to draw with
        } elseif ($mode -eq 'full') {
            QrWriteSolid $r.modules $r.size 2
        } else {
            QrWriteHalf $r.modules $r.size 2
        }
    } catch {
        Write-Host ("(QR code unavailable: " + $_.Exception.Message + " - use the text URL below instead)")
    }
}

function Get-LocalIP {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            Select-Object -First 1
        if ($cfg) { return $cfg.IPv4Address.IPAddress }
    } catch {}
    return '127.0.0.1'
}

function Get-ClipboardTextSafe {
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            return [System.Windows.Forms.Clipboard]::GetText()
        }
    } catch {}
    return $null
}

function Set-ClipboardTextSafe {
    param([string]$Text)
    for ($i = 0; $i -lt 10; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText($Text); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Send-TextToForeground {
    param([string]$Text, [bool]$AppendEnter)
    $prev = Get-ClipboardTextSafe
    if (-not (Set-ClipboardTextSafe -Text $Text)) { throw 'clipboard busy' }
    try {
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        if ($AppendEnter) {
            Start-Sleep -Milliseconds 40
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        }
        Start-Sleep -Milliseconds 150
    } finally {
        if ($null -ne $prev) { Set-ClipboardTextSafe -Text $prev | Out-Null }
    }
}

function Read-RequestHead {
    param($Stream)
    $bytesList = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    $matched = 0
    $term = [byte[]](13,10,13,10)
    while ($true) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -le 0) { break }
        $b = $one[0]
        $bytesList.Add($b)
        if ($b -eq $term[$matched]) {
            $matched++
            if ($matched -eq 4) { break }
        } else {
            if ($b -eq $term[0]) { $matched = 1 } else { $matched = 0 }
        }
        if ($bytesList.Count -gt 16384) { break }
    }
    return [System.Text.Encoding]::ASCII.GetString($bytesList.ToArray())
}

function Write-RawResponse {
    param($Stream, [int]$Status, [string]$StatusText, [string]$ContentType, [byte[]]$Body)
    $header = "HTTP/1.1 $Status $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-JsonResponse {
    param($Stream, [int]$Status, [string]$StatusText, [hashtable]$Obj)
    $json = $Obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Write-RawResponse -Stream $Stream -Status $Status -StatusText $StatusText -ContentType 'application/json; charset=utf-8' -Body $bytes
}

# ---- request checks (what they stop is described in SECURITY.md) ----

function Get-HeaderTable {
    param([string[]]$HeadLines)
    $table = @{}
    for ($i = 1; $i -lt $HeadLines.Length; $i++) {
        $idx = $HeadLines[$i].IndexOf(':')
        if ($idx -gt 0) {
            $table[$HeadLines[$i].Substring(0, $idx).Trim().ToLowerInvariant()] = $HeadLines[$i].Substring($idx + 1).Trim()
        }
    }
    return $table
}

# Addresses, localhost, mDNS names and this machine's own name. Anything else is a made-up
# domain pointing at this PC, which is how DNS-rebinding attacks reach a service on a LAN.
function Test-HostAllowed {
    param([string]$HostHeader)
    $name = $HostHeader.Trim().ToLowerInvariant()
    if ($name -eq '') { return $true }
    if ($name.StartsWith('[')) {
        $end = $name.IndexOf(']')
        if ($end -gt 0) { $name = $name.Substring(1, $end - 1) }
    } elseif ($name.IndexOf(':') -ge 0 -and $name.IndexOf(':') -eq $name.LastIndexOf(':')) {
        $name = $name.Substring(0, $name.LastIndexOf(':'))
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$ip)) { return $true }
    return ($name -eq 'localhost' -or $name.EndsWith('.local') -or $name -eq [System.Net.Dns]::GetHostName().ToLowerInvariant())
}

function Send-ApiError {
    param($Stream, [int]$Status, [string]$StatusText, [string]$Code, [string]$Message, [hashtable]$Extra = @{})
    $body = @{ ok = $false; code = $Code; error = $Message }
    foreach ($key in $Extra.Keys) { $body[$key] = $Extra[$key] }
    Send-JsonResponse -Stream $Stream -Status $Status -StatusText $StatusText -Obj $body
}

# Characters as people count them: a UTF-16 surrogate pair (an emoji) is one character.
function Get-CharCount {
    param([string]$Text)
    return $Text.Length - [regex]::Matches($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]').Count
}

function Invoke-SendRequest {
    param($Stream, [hashtable]$Headers)
    $hostHeader = ''
    if ($Headers.ContainsKey('host')) { $hostHeader = [string]$Headers['host'] }
    if (-not (Test-HostAllowed $hostHeader)) {
        Send-ApiError $Stream 403 'Forbidden' 'bad_host' ("Host '{0}' is not allowed. Open the page by IP address." -f $hostHeader)
        return
    }
    if ($Headers.ContainsKey('origin')) {
        $m = [regex]::Match([string]$Headers['origin'], '^https?://([^/]+)$', 'IgnoreCase')
        if (-not $m.Success -or $m.Groups[1].Value.ToLowerInvariant() -ne $hostHeader.Trim().ToLowerInvariant()) {
            Send-ApiError $Stream 403 'Forbidden' 'bad_origin' 'cross-origin requests are not allowed'
            return
        }
    }
    $contentType = ''
    if ($Headers.ContainsKey('content-type')) { $contentType = ([string]$Headers['content-type'] -split ';')[0].Trim().ToLowerInvariant() }
    if ($contentType -ne 'application/json') {
        Send-ApiError $Stream 415 'Unsupported Media Type' 'bad_content_type' 'Content-Type must be application/json'
        return
    }
    $contentLength = -1
    $parsedLength = 0
    if ($Headers.ContainsKey('content-length') -and [int]::TryParse([string]$Headers['content-length'], [ref]$parsedLength)) { $contentLength = $parsedLength }
    if ($contentLength -lt 0) {
        Send-ApiError $Stream 400 'Bad Request' 'bad_json' 'missing or invalid Content-Length'
        return
    }
    if ($contentLength -gt $MaxBody) {
        Send-ApiError $Stream 413 'Payload Too Large' 'body_too_large' 'request body too large'
        return
    }
    $buf = New-Object byte[] $contentLength
    $readTotal = 0
    while ($readTotal -lt $contentLength) {
        $n = $Stream.Read($buf, $readTotal, $contentLength - $readTotal)
        if ($n -le 0) { break }
        $readTotal += $n
    }
    $payload = $null
    try {
        $payload = [System.Text.Encoding]::UTF8.GetString($buf, 0, $readTotal) | ConvertFrom-Json
    } catch {
        Send-ApiError $Stream 400 'Bad Request' 'bad_json' 'the request body is not valid JSON'
        return
    }
    if ($payload -isnot [System.Management.Automation.PSCustomObject]) {
        Send-ApiError $Stream 400 'Bad Request' 'bad_json' 'the request body must be a JSON object'
        return
    }
    $text = $payload.text
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) {
        Send-ApiError $Stream 400 'Bad Request' 'empty' 'nothing to send'
        return
    }
    if ((Get-CharCount $text) -gt $MaxLen) {
        Send-ApiError $Stream 400 'Bad Request' 'too_long' ("text is longer than {0} characters" -f $MaxLen) @{ max = $MaxLen }
        return
    }
    $appendEnter = $true
    if ($payload.PSObject.Properties.Name -contains 'append_enter') {
        if ($payload.append_enter -isnot [bool]) {
            Send-ApiError $Stream 400 'Bad Request' 'bad_type' 'append_enter must be true or false'
            return
        }
        $appendEnter = $payload.append_enter
    }
    try {
        Send-TextToForeground -Text $text -AppendEnter $appendEnter
    } catch {
        Send-ApiError $Stream 500 'Internal Server Error' 'paste_failed' $_.Exception.Message
        return
    }
    Send-JsonResponse -Stream $Stream -Status 200 -StatusText 'OK' -Obj @{ ok = $true }
}

# The page is assembled from web/ by build.ps1 and embedded as base64, so this file stays pure ASCII.
$PageHtml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIiBkYXRhLXRoZW1lPSJiZWFkcyIgZGF0YS1tb2RlPSJsaWdodCIgZGF0YS1zaXplPSJzdGQiIGRhdGEtY29tcGFjdD0iMCI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJ1dGYtOCI+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xLHZpZXdwb3J0LWZpdD1jb3ZlcixpbnRlcmFjdGl2ZS13aWRnZXQ9cmVzaXplcy1jb250ZW50Ij4KPG1ldGEgbmFtZT0iY29sb3Itc2NoZW1lIiBjb250ZW50PSJsaWdodCBkYXJrIj4KPG1ldGEgbmFtZT0idGhlbWUtY29sb3IiIGNvbnRlbnQ9IiNmOGYyZTgiPgo8bWV0YSBuYW1lPSJhcHBsZS1tb2JpbGUtd2ViLWFwcC1jYXBhYmxlIiBjb250ZW50PSJ5ZXMiPgo8dGl0bGU+Vm9pY2VCZWFtPC90aXRsZT4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSJkYXRhOmltYWdlL3N2Zyt4bWwsJTNDc3ZnIHhtbG5zPSdodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2Zycgdmlld0JveD0nMCAwIDY0IDY0JyUzRSUzQ2RlZnMlM0UlM0NsaW5lYXJHcmFkaWVudCBpZD0nZycgeDE9JzAnIHkxPScwJyB4Mj0nMScgeTI9JzEnJTNFJTNDc3RvcCBvZmZzZXQ9JzAnIHN0b3AtY29sb3I9JyUyM2ZmNWZhMicvJTNFJTNDc3RvcCBvZmZzZXQ9Jy41NScgc3RvcC1jb2xvcj0nJTIzYTA2NmZmJy8lM0UlM0NzdG9wIG9mZnNldD0nMScgc3RvcC1jb2xvcj0nJTIzMmY5YmZmJy8lM0UlM0MvbGluZWFyR3JhZGllbnQlM0UlM0MvZGVmcyUzRSUzQ3JlY3Qgd2lkdGg9JzY0JyBoZWlnaHQ9JzY0JyByeD0nMTYnIGZpbGw9J3VybCglMjNnKScvJTNFJTNDcmVjdCB4PScyNScgeT0nMTInIHdpZHRoPScxNCcgaGVpZ2h0PScyNicgcng9JzcnIGZpbGw9JyUyM2ZmZicvJTNFJTNDcGF0aCBkPSdNMTggMzFhMTQgMTQgMCAwIDAgMjggME0zMiA0NXY4TTI0IDUzaDE2JyBmaWxsPSdub25lJyBzdHJva2U9JyUyM2ZmZicgc3Ryb2tlLXdpZHRoPSc0JyBzdHJva2UtbGluZWNhcD0ncm91bmQnLyUzRSUzQy9zdmclM0UiPgo8c2NyaXB0PndpbmRvdy5fX1ZCX189eyJtYXhMZW5ndGgiOjE2Mzg0LCJ2ZXJzaW9uIjoiMC4xLjAiLCJ0aGVtZSI6bnVsbCwiZGVtbyI6ZmFsc2V9O3dpbmRvdy5fX1ZCX0xPQ0FMRVNfXz17ImVuIjp7CiAgIl9uYW1lIjogIkVuZ2xpc2giLAogICJoaW50IjogIlR5cGUgb3IgZGljdGF0ZSwgdGhlbiBzZW5kIGl0IHRvIHlvdXIgUEMncyBjdXJzb3IiLAogICJwbGFjZWhvbGRlciI6ICJUYXAgaGVyZSwgdGhlbiB1c2UgeW91ciBrZXlib2FyZCdzIHZvaWNlIGlucHV0IiwKICAic2VuZCI6ICJTZW5kIHRvIFBDIiwKICAic2VuZGluZyI6ICJTZW5kaW5n4oCmIiwKICAic2VudCI6ICJTZW50IiwKICAic2VudF9lbnRlciI6ICJTZW50IGFuZCBFbnRlciBwcmVzc2VkIiwKICAiZW50ZXIiOiAiUHJlc3MgRW50ZXIgYWZ0ZXIgc2VuZGluZyIsCiAgImNsZWFyIjogIkNsZWFyIiwKICAibm90aWNlIjogIlRydXN0ZWQgV2nigJFGaSBvbmx5IMK3IG5vdGhpbmcgaXMgc3RvcmVkIiwKICAiZGVtb19iYW5uZXIiOiAiRGVtbyBtb2RlOiBub3RoaW5nIGlzIHBhc3RlZCB0byB0aGUgUEMiLAogICJjb25uLm9rIjogIkNvbm5lY3RlZCB0byB5b3VyIFBDIiwKICAiY29ubi5iYWQiOiAiQ2FuJ3QgcmVhY2ggeW91ciBQQy4gQ2hlY2sgdGhhdCBWb2ljZUJlYW0gaXMgc3RpbGwgcnVubmluZyBhbmQgdGhhdCBib3RoIGRldmljZXMgYXJlIG9uIHRoZSBzYW1lIFdp4oCRRmkuIiwKICAidGhlbWUubGFiZWwiOiAiU3R5bGUiLAogICJ0aGVtZS5idXNpbmVzcyI6ICJCdXNpbmVzcyIsCiAgInRoZW1lLmJlYWRzIjogIkJlYWRzIiwKICAidGhlbWUuYnVzaW5lc3MuZGVzYyI6ICJDbGVhbiBhbmQgY2FsbSwgbGlrZSBhIHdvcmsgZG9jdW1lbnQiLAogICJ0aGVtZS5iZWFkcy5kZXNjIjogIlRoZSBvcmlnaW5hbDogY3JlYW0gcGFwZXIsIGJvbGQgb3V0bGluZXMsIGJlYWQgdGlsZXMiLAogICJzZXR0aW5ncy5vcGVuIjogIkFwcGVhcmFuY2UgYW5kIHNldHRpbmdzIiwKICAic2V0dGluZ3MudGl0bGUiOiAiQXBwZWFyYW5jZSBhbmQgc2V0dGluZ3MiLAogICJzZXR0aW5ncy5tb2RlIjogIkFwcGVhcmFuY2UiLAogICJtb2RlLmF1dG8iOiAiQXV0byIsCiAgIm1vZGUubGlnaHQiOiAiTGlnaHQiLAogICJtb2RlLmRhcmsiOiAiRGFyayIsCiAgInNldHRpbmdzLnNpemUiOiAiVGV4dCBzaXplIiwKICAic2l6ZS5zdGQiOiAiU3RhbmRhcmQiLAogICJzaXplLmxnIjogIkxhcmdlIiwKICAic2l6ZS54bCI6ICJFeHRyYSBsYXJnZSIsCiAgInNldHRpbmdzLmFmdGVyIjogIkFmdGVyIHNlbmRpbmciLAogICJhZnRlci5rZWVwIjogIktlZXAgdGhlIGtleWJvYXJkIiwKICAiYWZ0ZXIuY2xvc2UiOiAiQ2xvc2UgdGhlIGtleWJvYXJkIiwKICAiYWZ0ZXIubm90ZSI6ICJJZiB5b3VyIHBob25lIGtlZXBzIGRpY3RhdGluZyBhZnRlciB5b3Ugc2VuZCwgY2hvb3NlIOKAnENsb3NlIHRoZSBrZXlib2FyZOKAnS4iLAogICJzZXR0aW5ncy5sYW5nIjogIkxhbmd1YWdlIiwKICAibGFuZy5hdXRvIjogIkF1dG8iLAogICJjbG9zZSI6ICJEb25lIiwKICAiZXJyLmVtcHR5IjogIlR5cGUgb3IgZGljdGF0ZSBzb21ldGhpbmcgZmlyc3QiLAogICJlcnIudG9vX2xvbmciOiAiVXAgdG8ge21heH0gY2hhcmFjdGVycyBwZXIgbWVzc2FnZSIsCiAgImVyci5ib2R5X3Rvb19sYXJnZSI6ICJUaGF0IGlzIHRvbyBsb25nLCBzZW5kIGl0IGluIHBhcnRzIiwKICAiZXJyLmJhZF9qc29uIjogIlRoZSByZXF1ZXN0IHdhcyBtYWxmb3JtZWQsIHJlbG9hZCB0aGUgcGFnZSBhbmQgdHJ5IGFnYWluIiwKICAiZXJyLmJhZF90eXBlIjogIlRoZSByZXF1ZXN0IHdhcyBtYWxmb3JtZWQsIHJlbG9hZCB0aGUgcGFnZSBhbmQgdHJ5IGFnYWluIiwKICAiZXJyLmJhZF9ob3N0IjogIlRoZSBQQyByZWZ1c2VkIHRoaXMgYWRkcmVzcywgb3BlbiB0aGUgcGFnZSBmcm9tIHRoZSBRUiBjb2RlIG9yIGJ5IElQIGFkZHJlc3MiLAogICJlcnIuYmFkX29yaWdpbiI6ICJUaGUgUEMgcmVmdXNlZCB0aGlzIG9yaWdpbiwgb3BlbiB0aGUgcGFnZSBmcm9tIHRoZSBRUiBjb2RlIG9yIGJ5IElQIGFkZHJlc3MiLAogICJlcnIuYmFkX2NvbnRlbnRfdHlwZSI6ICJUaGUgcmVxdWVzdCB3YXMgbWFsZm9ybWVkLCByZWxvYWQgdGhlIHBhZ2UgYW5kIHRyeSBhZ2FpbiIsCiAgImVyci5ub3RfZm91bmQiOiAiRW5kcG9pbnQgbm90IGZvdW5kLCByZWxvYWQgdGhlIHBhZ2UgYW5kIHRyeSBhZ2FpbiIsCiAgImVyci5wYXN0ZV9mYWlsZWQiOiAiVGhlIFBDIGNvdWxkIG5vdCBwYXN0ZSBpdCIsCiAgImVyci5uZXR3b3JrIjogIkNvdWxkIG5vdCByZWFjaCB0aGUgUEMuIFlvdXIgdGV4dCBpcyBzdGlsbCBoZXJlLCB0YXAgU2VuZCB0byB0cnkgYWdhaW4iLAogICJlcnIuaHR0cCI6ICJTb21ldGhpbmcgd2VudCB3cm9uZyAoSFRUUCB7c3RhdHVzfSkiCn0sInpoLUNOIjp7CiAgIl9uYW1lIjogIueugOS9k+S4reaWhyIsCiAgImhpbnQiOiAi6L6T5YWl5paH5a2X77yM5Y+R6YCB5Yiw55S16ISR5b2T5YmN5YWJ5qCHIiwKICAicGxhY2Vob2xkZXIiOiAi54K55Ye76L+Z6YeM77yM5L2/55So5omL5py66K+t6Z+z6L6T5YWlIiwKICAic2VuZCI6ICLlj5HpgIHliLDnlLXohJEiLAogICJzZW5kaW5nIjogIuWPkemAgeS4reKApiIsCiAgInNlbnQiOiAi5bey5Y+R6YCBIiwKICAic2VudF9lbnRlciI6ICLlt7Llj5HpgIHlubblm57ovaYiLAogICJlbnRlciI6ICLlj5HpgIHlkI7mjInlm57ovaYiLAogICJjbGVhciI6ICLmuIXnqboiLAogICJub3RpY2UiOiAi5LuF6YCC55So5LqO5Y+v5L+h5bGA5Z+f572RIMK3IOS4jeS/neWtmOi+k+WFpeWGheWuuSIsCiAgImRlbW9fYmFubmVyIjogIua8lOekuuaooeW8j++8muaWh+Wtl+S4jeS8mueymOi0tOWIsOeUteiEkSIsCiAgImNvbm4ub2siOiAi5bey6L+e5o6l55S16ISRIiwKICAiY29ubi5iYWQiOiAi6L+e5LiN5LiK55S16ISR44CC6K+356Gu6K6k55S16ISR5LiK55qEIFZvaWNlQmVhbSDov5jlnKjov5DooYzvvIzlubbkuJTmiYvmnLrlkoznlLXohJHlnKjlkIzkuIDkuKogV2nigJFGaeOAgiIsCiAgInRoZW1lLmxhYmVsIjogIumjjuagvCIsCiAgInRoZW1lLmJ1c2luZXNzIjogIuWVhuWKoSIsCiAgInRoZW1lLmJlYWRzIjogIuaLvOixhiIsCiAgInRoZW1lLmJ1c2luZXNzLmRlc2MiOiAi566A5rSB5LiT5Lia77yM6YCC5ZCI5Yqe5YWsIiwKICAidGhlbWUuYmVhZHMuZGVzYyI6ICLljp/niYjvvJrlpbbmsrnnurjjgIHnspfmj4/ovrkiLAogICJzZXR0aW5ncy5vcGVuIjogIuWkluinguS4juiuvue9riIsCiAgInNldHRpbmdzLnRpdGxlIjogIuWkluinguS4juiuvue9riIsCiAgInNldHRpbmdzLm1vZGUiOiAi5piO5pqXIiwKICAibW9kZS5hdXRvIjogIui3n+maj+ezu+e7nyIsCiAgIm1vZGUubGlnaHQiOiAi5rWF6ImyIiwKICAibW9kZS5kYXJrIjogIua3seiJsiIsCiAgInNldHRpbmdzLnNpemUiOiAi6L6T5YWl5a2X5Y+3IiwKICAic2l6ZS5zdGQiOiAi5qCH5YeGIiwKICAic2l6ZS5sZyI6ICLlpKciLAogICJzaXplLnhsIjogIueJueWkpyIsCiAgInNldHRpbmdzLmFmdGVyIjogIuWPkemAgeWQjiIsCiAgImFmdGVyLmtlZXAiOiAi6ZSu55uY5L+d5oyB5omT5byAIiwKICAiYWZ0ZXIuY2xvc2UiOiAi5pS26LW36ZSu55uYIiwKICAiYWZ0ZXIubm90ZSI6ICLlpoLmnpzlj5HpgIHlkI7or63pn7PovpPlhaXov5jlnKjnu6fnu63lkKzlhpnvvIzor7fpgInigJzmlLbotbfplK7nm5jigJ3jgIIiLAogICJzZXR0aW5ncy5sYW5nIjogIuivreiogCIsCiAgImxhbmcuYXV0byI6ICLoh6rliqgiLAogICJjbG9zZSI6ICLlrozmiJAiLAogICJlcnIuZW1wdHkiOiAi6K+36L6T5YWl5paH5a2XIiwKICAiZXJyLnRvb19sb25nIjogIuWNleadoeaWh+Wtl+S4jeiDvei2hei/hyB7bWF4fSDkuKrlrZfnrKYiLAogICJlcnIuYm9keV90b29fbGFyZ2UiOiAi5YaF5a655aSq6ZW/77yM6K+35YiG5Yeg5qyh5Y+R6YCBIiwKICAiZXJyLmJhZF9qc29uIjogIuivt+axguagvOW8j+S4jeWvue+8jOivt+WIt+aWsOmhtemdouWGjeivlSIsCiAgImVyci5iYWRfdHlwZSI6ICLor7fmsYLmoLzlvI/kuI3lr7nvvIzor7fliLfmlrDpobXpnaLlho3or5UiLAogICJlcnIuYmFkX2hvc3QiOiAi55S16ISR5ouS57ud5LqG6L+Z5Liq6K6/6Zeu5Zyw5Z2A77yM6K+355So5LqM57u056CB5oiWIElQIOWcsOWdgOaJk+W8gOacrOmhtSIsCiAgImVyci5iYWRfb3JpZ2luIjogIueUteiEkeaLkue7neS6hui/meS4quadpea6kO+8jOivt+eUqOS6jOe7tOeggeaIliBJUCDlnLDlnYDmiZPlvIDmnKzpobUiLAogICJlcnIuYmFkX2NvbnRlbnRfdHlwZSI6ICLor7fmsYLmoLzlvI/kuI3lr7nvvIzor7fliLfmlrDpobXpnaLlho3or5UiLAogICJlcnIubm90X2ZvdW5kIjogIuaJvuS4jeWIsOaOpeWPo++8jOivt+WIt+aWsOmhtemdouWGjeivlSIsCiAgImVyci5wYXN0ZV9mYWlsZWQiOiAi55S16ISR56uv5pyq6IO957KY6LS0IiwKICAiZXJyLm5ldHdvcmsiOiAi5rKh5pyJ6L+e5LiK55S16ISR77yM5paH5a2X6L+Y55WZ5Zyo6L6T5YWl5qGG6YeM77yM5Y+v5Lul5YaN54K55LiA5qyh5Y+R6YCBIiwKICAiZXJyLmh0dHAiOiAi5Ye66ZSZ5LqG77yISFRUUCB7c3RhdHVzfe+8iSIKfX07PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8qIFJ1bnMgYmVmb3JlIHRoZSBmaXJzdCBwYWludCBzbyBhIHBob25lIHRoYXQgY2hvc2UgYW5vdGhlciBzdHlsZSBuZXZlciBmbGFzaGVzIHRoZSBkZWZhdWx0IG9uZS4gKi8KKGZ1bmN0aW9uICgpIHsKICB2YXIgZCA9IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudCwgYyA9IHdpbmRvdy5fX1ZCX18gfHwge307CiAgZnVuY3Rpb24gZ2V0KGspIHsgdHJ5IHsgcmV0dXJuIGxvY2FsU3RvcmFnZS5nZXRJdGVtKCd2Yi4nICsgayk7IH0gY2F0Y2ggKGUpIHsgcmV0dXJuIG51bGw7IH0gfQogIHZhciB0aGVtZSA9IGdldCgndGhlbWUnKTsKICBpZiAodGhlbWUgIT09ICdidXNpbmVzcycgJiYgdGhlbWUgIT09ICdiZWFkcycpIHRoZW1lID0gYy50aGVtZSB8fCAnYmVhZHMnOyAvKiBhbiB1bmtub3duIG9yIHJldGlyZWQgbmFtZSBmYWxscyBiYWNrIHRvIHRoZSBkZWZhdWx0ICovCiAgdmFyIG1vZGUgPSBnZXQoJ21vZGUnKSB8fCAnYXV0byc7CiAgaWYgKG1vZGUgPT09ICdhdXRvJykgbW9kZSA9IHdpbmRvdy5tYXRjaE1lZGlhICYmIG1hdGNoTWVkaWEoJyhwcmVmZXJzLWNvbG9yLXNjaGVtZTogZGFyayknKS5tYXRjaGVzID8gJ2RhcmsnIDogJ2xpZ2h0JzsKICBkLnNldEF0dHJpYnV0ZSgnZGF0YS10aGVtZScsIHRoZW1lKTsKICBkLnNldEF0dHJpYnV0ZSgnZGF0YS1tb2RlJywgbW9kZSk7CiAgZC5zZXRBdHRyaWJ1dGUoJ2RhdGEtc2l6ZScsIGdldCgnc2l6ZScpIHx8ICdzdGQnKTsKfSkoKTsKPC9zY3JpcHQ+CjxzdHlsZT4vKiBWb2ljZUJlYW0gLSBvbmUgc3R5bGVzaGVldCwgdHdvIHN0eWxlcyAoYnVzaW5lc3MsIGJlYWRzKSwgZWFjaCBpbiBsaWdodCBhbmQgZGFyay4KICoKICogVGhlIHRleHQgYm94IGlzIHRoZSBwb2ludCBvZiB0aGUgcGFnZSwgc28gaXRzIHNpemUgaXMgYSBmaXJzdC1jbGFzcyBzZXR0aW5nOgogKiAgIC0tdGEtc2l6ZSAgZm9udCBzaXplLCAxOHB4IGxpa2UgdGhlIG9yaWdpbmFsIHBhZ2UgKG5ldmVyIHNtYWxsZXI7ICJsYXJnZSIvImV4dHJhIGxhcmdlIiBnbyB1cCkKICogICAtLXRhLW1pbiAgIG1pbmltdW0gaGVpZ2h0LCAyMjBweCAodGhlIG9yaWdpbmFsIHdhcyAxNjQtMjAwcHgpOyBpdCBncm93cyB0byBmaWxsIHRoZSBzY3JlZW4KICoKICogIkJlYWRzIiAo5ou86LGGKSBrZWVwcyB0aGUgbG9vayBvZiB0aGUgcGFnZSB0aGlzIHByb2plY3Qgc3RhcnRlZCBmcm9tOiBjcmVhbSBwYXBlciwgdGhpY2sgaW5rIG91dGxpbmVzLAogKiBoYXJkIG9mZnNldCBzaGFkb3dzLCBhIHllbGxvdyBidXR0b24sIGFuZCBhIHN0cmlwIG9mIGJlYWQgdGlsZXMgaW4gc2l4IGJyaWdodCBjb2xvdXJzLgogKi8KCi8qIC0tLS0tLS0tLS0gc2hhcmVkIHRva2VucyAtLS0tLS0tLS0tICovCjpyb290IHsKICAtLXRhLXNpemU6IDE4cHg7CiAgLS10YS1taW46IDIyMHB4OwogIC0tZ2FwOiAxMnB4OwogIC0tci1sZzogMTZweDsKICAtLXItbWQ6IDEycHg7CiAgLS11aTogLWFwcGxlLXN5c3RlbSwgQmxpbmtNYWNTeXN0ZW1Gb250LCAiU2Vnb2UgVUkiLCAiUGluZ0ZhbmcgU0MiLCAiSGlyYWdpbm8gU2FucyBHQiIsICJNaWNyb3NvZnQgWWFIZWkgVUkiLCAiTWljcm9zb2Z0IFlhSGVpIiwgUm9ib3RvLCAiTm90byBTYW5zIENKSyBTQyIsICJOb3RvIFNhbnMgU0MiLCBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7CiAgLS10ZXh0LWZvbnQ6IHN5c3RlbS11aSwgLWFwcGxlLXN5c3RlbSwgIlBpbmdGYW5nIFNDIiwgIk1pY3Jvc29mdCBZYUhlaSIsIHNhbnMtc2VyaWY7CiAgLS1ibHVyOiBub25lOwogIC0tZmllbGQtYmx1cjogdmFyKC0tYmx1cik7CiAgLS1maWVsZC1idzogMS41cHg7ICAgICAvKiBib3JkZXIgb2YgdGhlIHRleHQgYm94ICh0aGUgYmVhZHMgc3R5bGUgaGFzIGEgdGhpY2sgaW5rIG91dGxpbmUpICovCiAgLS1idG4tYnc6IDEuNXB4OwogIC0tYnRuLWg6IDU4cHg7Cn0KaHRtbFtkYXRhLXNpemU9ImxnIl0geyAtLXRhLXNpemU6IDIycHg7IH0KaHRtbFtkYXRhLXNpemU9InhsIl0geyAtLXRhLXNpemU6IDI2cHg7IH0KCi8qIC0tLS0tLS0tLS0gYnVzaW5lc3M6IGxpZ2h0IC0tLS0tLS0tLS0gKi8KaHRtbFtkYXRhLXRoZW1lPSJidXNpbmVzcyJdIHsKICAtLWJnOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZjhmYWZkIDAlLCAjZWVmMmY4IDEwMCUpOwogIC0tY2hyb21lOiAjZjhmYWZkOwogIC0tcmluZy1iZzogI2Y4ZmFmZDsKICAtLWluazogIzBmMTcyYTsgLS1pbmsyOiAjNDc1NTY5OyAtLWluazM6ICM1YjZhODA7CiAgLS1wYW5lbDogI2ZmZmZmZjsgLS1wYW5lbC1saW5lOiAjZGZlNWVlOyAtLXBhbmVsLXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMTUsIDIzLCA0MiwgLjA2KTsKICAtLWZpZWxkLWJnOiAjZmZmZmZmOyAtLWZpZWxkLWxpbmU6ICNjM2NkZGE7CiAgLS1maWVsZC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDE1LCAyMywgNDIsIC4wNSksIDAgMTRweCAyOHB4IC0xOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjM1KTsKICAtLWZpZWxkLWZvY3VzOiAwIDAgMCA0cHggcmdiYSg0NywgMTA3LCAyNDIsIC4xNyksIDAgMTRweCAyOHB4IC0xOHB4IHJnYmEoMTUsIDIzLCA0MiwgLjM1KTsKICAtLWZpZWxkLWxpbmUtZm9jdXM6ICMyZjZiZjI7CiAgLS1hY2NlbnQ6ICMyZjZiZjI7CiAgLS1idG4tYmc6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICMzYjc4ZjcgMCUsICMyNTU5ZDkgMTAwJSk7CiAgLS1idG4taW5rOiAjZmZmZmZmOyAtLWJ0bi1saW5lOiAjMWY0ZmMwOwogIC0tYnRuLXNoYWRvdzogMCAxcHggMCByZ2JhKDI1NSwgMjU1LCAyNTUsIC4yOCkgaW5zZXQsIDAgMTJweCAyMnB4IC0xMnB4IHJnYmEoMzcsIDg5LCAyMTcsIC44KTsKICAtLWJ0bi1kb3duOiAwIDFweCAwIHJnYmEoMjU1LCAyNTUsIDI1NSwgLjIpIGluc2V0LCAwIDRweCAxMHB4IC02cHggcmdiYSgzNywgODksIDIxNywgLjgpOwogIC0tYnRuLW9rLWJnOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjMWZhOTcxIDAlLCAjMGY3YjRkIDEwMCUpOwogIC0tc2VnLWJnOiAjZThlZGY1OyAtLXNlZy1saW5lOiB0cmFuc3BhcmVudDsKICAtLXNlZy1vbi1iZzogI2ZmZmZmZjsgLS1zZWctb24taW5rOiAjMGYxNzJhOwogIC0tc2VnLW9uLXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMTUsIDIzLCA0MiwgLjIpLCAwIDAgMCAxcHggcmdiYSgxNSwgMjMsIDQyLCAuMDUpOwogIC0tY2hpcC1iZzogI2VlZjJmODsgLS1jaGlwLWluazogIzMzNDE1NTsgLS1jaGlwLWxpbmU6ICNkNmRlZWE7CiAgLS1zdy1vZmY6ICNjM2NkZGE7IC0tc3ctb246ICMyZjZiZjI7IC0tc3cta25vYjogI2ZmZmZmZjsKICAtLW9rOiAjMGY3YjRkOyAtLWVycjogI2I0MjMxODsgLS13YXJuOiAjOWE1YjAwOyAtLWVyci1iZzogI2ZkZWNlYTsKICAtLXNoZWV0LWJnOiAjZmZmZmZmOyAtLXNjcmltOiByZ2JhKDE1LCAyMywgNDIsIC40NSk7CiAgLS1sb2dvLWJnOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjM2I3OGY3LCAjMjU1OWQ5KTsKICAtLWxvZ28tc2hhZG93OiAwIDZweCAxNHB4IC02cHggcmdiYSgzNywgODksIDIxNywgLjgpOwogIC0tZm9jdXMtb3V0bGluZTogIzJmNmJmMjsKICAtLXItbGc6IDE0cHg7IC0tci1tZDogMTBweDsKfQoKLyogLS0tLS0tLS0tLSBidXNpbmVzczogZGFyayAtLS0tLS0tLS0tICovCmh0bWxbZGF0YS10aGVtZT0iYnVzaW5lc3MiXVtkYXRhLW1vZGU9ImRhcmsiXSB7CiAgLS1iZzogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgIzBjMTMyNCAwJSwgIzA4MGQxOCAxMDAlKTsKICAtLWNocm9tZTogIzBjMTMyNDsKICAtLXJpbmctYmc6ICMwYzEzMjQ7CiAgLS1pbms6ICNlOGVlZjg7IC0taW5rMjogI2FhYjdjYjsgLS1pbmszOiAjOGE5OGFlOwogIC0tcGFuZWw6ICMxMTFiMzA7IC0tcGFuZWwtbGluZTogIzIyMzA0YzsgLS1wYW5lbC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgyNTUsIDI1NSwgMjU1LCAuMDMpIGluc2V0OwogIC0tZmllbGQtYmc6ICMwZTE3Mjk7IC0tZmllbGQtbGluZTogIzJhMzk1NjsKICAtLWZpZWxkLXNoYWRvdzogMCAxNnB4IDMwcHggLTE4cHggcmdiYSgwLCAwLCAwLCAuOCk7CiAgLS1maWVsZC1mb2N1czogMCAwIDAgNHB4IHJnYmEoMTA2LCAxNTUsIDI1NSwgLjI0KSwgMCAxNnB4IDMwcHggLTE4cHggcmdiYSgwLCAwLCAwLCAuOCk7CiAgLS1maWVsZC1saW5lLWZvY3VzOiAjNmE5YmZmOwogIC0tYWNjZW50OiAjNmE5YmZmOwogIC0tYnRuLWJnOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjNWY5MGZmIDAlLCAjM2Y3MGVhIDEwMCUpOwogIC0tYnRuLWxpbmU6ICMzNjVmYzk7CiAgLS1idG4tc2hhZG93OiAwIDFweCAwIHJnYmEoMjU1LCAyNTUsIDI1NSwgLjI1KSBpbnNldCwgMCAxMnB4IDIycHggLTEycHggcmdiYSg2MywgMTEyLCAyMzQsIC45KTsKICAtLWJ0bi1kb3duOiAwIDFweCAwIHJnYmEoMjU1LCAyNTUsIDI1NSwgLjIpIGluc2V0LCAwIDRweCAxMHB4IC02cHggcmdiYSg2MywgMTEyLCAyMzQsIC45KTsKICAtLWJ0bi1vay1iZzogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgIzI1YjU3YSAwJSwgIzE0ODk1YSAxMDAlKTsKICAtLXNlZy1iZzogIzE3MjMzYjsKICAtLXNlZy1vbi1iZzogIzJiM2Q2MjsgLS1zZWctb24taW5rOiAjZjJmNmZmOwogIC0tc2VnLW9uLXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwgMCwgMCwgLjUpLCAwIDAgMCAxcHggcmdiYSgyNTUsIDI1NSwgMjU1LCAuMDYpOwogIC0tY2hpcC1iZzogIzE3MjMzYjsgLS1jaGlwLWluazogI2M3ZDNlNjsgLS1jaGlwLWxpbmU6ICMyNjM2NWE7CiAgLS1zdy1vZmY6ICMzNDQ0NWY7IC0tc3ctb246ICM2YTliZmY7CiAgLS1vazogIzRhZGU4MDsgLS1lcnI6ICNmZjhmODY7IC0td2FybjogI2ZiYmYyNDsgLS1lcnItYmc6IHJnYmEoMjU1LCAxNDMsIDEzNCwgLjEyKTsKICAtLXNoZWV0LWJnOiAjMGYxOTJkOyAtLXNjcmltOiByZ2JhKDAsIDAsIDAsIC42KTsKICAtLWxvZ28tYmc6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsICM1ZjkwZmYsICMzZjcwZWEpOwogIC0tbG9nby1zaGFkb3c6IDAgNnB4IDE0cHggLTZweCByZ2JhKDYzLCAxMTIsIDIzNCwgLjkpOwogIC0tZm9jdXMtb3V0bGluZTogIzhmYjNmZjsKfQoKLyogLS0tLS0tLS0tLSBiZWFkcyAo5ou86LGGKTogbGlnaHQgLSB0aGUgb3JpZ2luYWwgcGFnZTogY3JlYW0gcGFwZXIsIGluayBvdXRsaW5lcywgaGFyZCBzaGFkb3dzIC0tLS0tLS0tLS0gKi8KaHRtbFtkYXRhLXRoZW1lPSJiZWFkcyJdIHsKICAtLXVpOiB1aS1yb3VuZGVkLCAiQXJpYWwgUm91bmRlZCBNVCBCb2xkIiwgIlBpbmdGYW5nIFNDIiwgIk1pY3Jvc29mdCBZYUhlaSBVSSIsICJNaWNyb3NvZnQgWWFIZWkiLCBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7CiAgLS1iZzogI2Y4ZjJlODsKICAtLWNocm9tZTogI2Y4ZjJlODsKICAtLXJpbmctYmc6ICNmOGYyZTg7CiAgLS1pbms6ICMyNTIyMzg7IC0taW5rMjogIzY2NWQ3ODsgLS1pbmszOiAjNmM2MzgwOwogIC0tbGluZTogIzI1MjIzODsgICAgICAgIC8qIHRoZSB0aGljayBvdXRsaW5lIG9mIGV2ZXJ5dGhpbmcgKi8KICAtLXNoYWRlOiAjMjUyMjM4OyAgICAgICAvKiBoYXJkLCB1bmJsdXJyZWQgc2hhZG93cyAqLwogIC0tdGlsZS1saW5lOiByZ2JhKDM3LCAzNCwgNTYsIC4zMyk7IC0tdGlsZS1zaGFkZTogcmdiYSgzNywgMzQsIDU2LCAuMik7CiAgLS1wYW5lbDogI2ZmZmRmODsgLS1wYW5lbC1saW5lOiAjMjUyMjM4OyAtLXBhbmVsLXNoYWRvdzogMnB4IDJweCAwICMyNTIyMzg7CiAgLS1maWVsZC1idzogM3B4OwogIC0tZmllbGQtYmc6ICNmZmZmZmY7IC0tZmllbGQtbGluZTogIzI1MjIzODsKICAtLWZpZWxkLXNoYWRvdzogbm9uZTsKICAtLWZpZWxkLWZvY3VzOiAzcHggM3B4IDAgI2ZmNmI2YjsKICAtLWZpZWxkLWxpbmUtZm9jdXM6ICMyNTIyMzg7CiAgLS1hY2NlbnQ6ICNmZjZiNmI7CiAgLS1idG4tYnc6IDNweDsKICAtLWJ0bi1oOiA1NHB4OwogIC0tYnRuLWJnOiBsaW5lYXItZ3JhZGllbnQoI2ZmZDE2NiwgI2ZmZDE2Nik7CiAgLS1idG4taW5rOiAjMjUyMjM4OyAtLWJ0bi1saW5lOiAjMjUyMjM4OwogIC0tYnRuLXNoYWRvdzogNHB4IDRweCAwICMyNTIyMzg7CiAgLS1idG4tZG93bjogMXB4IDFweCAwICMyNTIyMzg7CiAgLS1idG4tb2stYmc6IGxpbmVhci1ncmFkaWVudCgjNGVjZGM0LCAjNGVjZGM0KTsKICAtLXNlZy1iZzogI2ZmZmRmODsgLS1zZWctbGluZTogIzI1MjIzODsKICAtLXNlZy1vbi1iZzogI2ZmZDE2NjsgLS1zZWctb24taW5rOiAjMjUyMjM4OyAtLXNlZy1vbi1zaGFkb3c6IG5vbmU7CiAgLS1jaGlwLWJnOiAjZmZmZGY4OyAtLWNoaXAtaW5rOiAjMjUyMjM4OyAtLWNoaXAtbGluZTogIzI1MjIzODsKICAtLXN3LW9mZjogI2ZmZmZmZjsgLS1zdy1vbjogIzZjOGNmZjsgLS1zdy1rbm9iOiAjZmZmZmZmOwogIC0tb2s6ICMxODc5NGU7IC0tZXJyOiAjYjQyMzE4OyAtLXdhcm46ICM5YTViMDA7IC0tZXJyLWJnOiAjZmZmMWVmOwogIC0tc2hlZXQtYmc6ICNmOGYyZTg7IC0tc2NyaW06IHJnYmEoMzcsIDM0LCA1NiwgLjQ1KTsKICAtLWxvZ28tYmc6ICNmZmQxNjY7IC0tbG9nby1zaGFkb3c6IDJweCAycHggMCAjMjUyMjM4OwogIC0tZm9jdXMtb3V0bGluZTogIzZjOGNmZjsKICAtLXItbGc6IDEwcHg7IC0tci1tZDogMTBweDsKfQoKLyogLS0tLS0tLS0tLSBiZWFkcyAo5ou86LGGKTogZGFyayAtIHRoZSBzYW1lIHBhZ2UgYXQgbmlnaHQ6IGluayBwYXBlciwgY3JlYW0gb3V0bGluZXMgLS0tLS0tLS0tLSAqLwpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl1bZGF0YS1tb2RlPSJkYXJrIl0gewogIC0tYmc6ICMxZjFiMmU7CiAgLS1jaHJvbWU6ICMxZjFiMmU7CiAgLS1yaW5nLWJnOiAjMWYxYjJlOwogIC0taW5rOiAjZjhmMmU4OyAtLWluazI6ICNjZmM2ZGQ7IC0taW5rMzogI2I2YWNjODsKICAtLWxpbmU6ICNmOGYyZTg7CiAgLS1zaGFkZTogIzBiMDkxNDsKICAtLXRpbGUtbGluZTogcmdiYSgyNDgsIDI0MiwgMjMyLCAuMzgpOyAtLXRpbGUtc2hhZGU6IHJnYmEoMCwgMCwgMCwgLjU1KTsKICAtLXBhbmVsOiAjMmEyNTQwOyAtLXBhbmVsLWxpbmU6ICNmOGYyZTg7IC0tcGFuZWwtc2hhZG93OiAycHggMnB4IDAgIzBiMDkxNDsKICAtLWZpZWxkLWJnOiAjMmEyNTQwOyAtLWZpZWxkLWxpbmU6ICNmOGYyZTg7CiAgLS1maWVsZC1saW5lLWZvY3VzOiAjZjhmMmU4OwogIC0tYnRuLWxpbmU6ICNmOGYyZTg7CiAgLS1idG4tc2hhZG93OiA0cHggNHB4IDAgIzBiMDkxNDsKICAtLWJ0bi1kb3duOiAxcHggMXB4IDAgIzBiMDkxNDsKICAtLXNlZy1iZzogIzJhMjU0MDsgLS1zZWctbGluZTogI2Y4ZjJlODsKICAtLWNoaXAtYmc6ICMyYTI1NDA7IC0tY2hpcC1pbms6ICNmOGYyZTg7IC0tY2hpcC1saW5lOiAjZjhmMmU4OwogIC0tc3ctb2ZmOiAjMmEyNTQwOwogIC0tb2s6ICM2ZWU3Yjc7IC0tZXJyOiAjZmY4YTgwOyAtLXdhcm46ICNmYmJmMjQ7IC0tZXJyLWJnOiAjM2EyMDMwOwogIC0tc2hlZXQtYmc6ICMxZjFiMmU7IC0tc2NyaW06IHJnYmEoMCwgMCwgMCwgLjU1KTsKICAtLWxvZ28tc2hhZG93OiAycHggMnB4IDAgIzBiMDkxNDsKICAtLWZvY3VzLW91dGxpbmU6ICM4ZmE2ZmY7Cn0KCi8qIC0tLS0tLS0tLS0gYmFzZSAtLS0tLS0tLS0tICovCiosICo6OmJlZm9yZSwgKjo6YWZ0ZXIgeyBib3gtc2l6aW5nOiBib3JkZXItYm94OyAtd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3I6IHRyYW5zcGFyZW50OyB9Cmh0bWwgeyAtd2Via2l0LXRleHQtc2l6ZS1hZGp1c3Q6IDEwMCU7IHRleHQtc2l6ZS1hZGp1c3Q6IDEwMCU7IGNvbG9yLXNjaGVtZTogbGlnaHQ7IH0KaHRtbFtkYXRhLW1vZGU9ImRhcmsiXSB7IGNvbG9yLXNjaGVtZTogZGFyazsgfQpib2R5IHsKICBtYXJnaW46IDA7CiAgbWluLWhlaWdodDogMTAwdmg7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hyb21lKTsKICBjb2xvcjogdmFyKC0taW5rKTsKICBmb250OiAxNnB4LzEuNCB2YXIoLS11aSk7CiAgLXdlYmtpdC1mb250LXNtb290aGluZzogYW50aWFsaWFzZWQ7CiAgb3ZlcmZsb3cteDogaGlkZGVuOwp9CmJ1dHRvbiwgaW5wdXQsIHRleHRhcmVhIHsgZm9udDogaW5oZXJpdDsgY29sb3I6IGluaGVyaXQ7IH0KYnV0dG9uIHsgLXdlYmtpdC1hcHBlYXJhbmNlOiBub25lOyBhcHBlYXJhbmNlOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7IC13ZWJraXQtdXNlci1zZWxlY3Q6IG5vbmU7IHVzZXItc2VsZWN0OiBub25lOyB0b3VjaC1hY3Rpb246IG1hbmlwdWxhdGlvbjsgfQpbaGlkZGVuXSB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQo6OnNlbGVjdGlvbiB7IGJhY2tncm91bmQ6IHJnYmEoNDcsIDEwNywgMjQyLCAuMjUpOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSA6OnNlbGVjdGlvbiB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LCAyMDksIDEwMiwgLjU1KTsgfQo6Zm9jdXMtdmlzaWJsZSB7IG91dGxpbmU6IDNweCBzb2xpZCB2YXIoLS1mb2N1cy1vdXRsaW5lKTsgb3V0bGluZS1vZmZzZXQ6IDJweDsgfQoKLyogLS0tLS0tLS0tLSBiYWNrZHJvcCAtLS0tLS0tLS0tICovCi5iYWNrZHJvcCB7IHBvc2l0aW9uOiBmaXhlZDsgbGVmdDogMDsgdG9wOiAwOyByaWdodDogMDsgYm90dG9tOiAwOyB6LWluZGV4OiAwOyBwb2ludGVyLWV2ZW50czogbm9uZTsgYmFja2dyb3VuZDogdmFyKC0tYmcpOyB9CgovKiAtLS0tLS0tLS0tIGxheW91dCAtLS0tLS0tLS0tICovCi5hcHAgewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMTsKICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IHZhcigtLWdhcCk7CiAgd2lkdGg6IDEwMCU7IG1heC13aWR0aDogNzgwcHg7IG1hcmdpbjogMCBhdXRvOwogIG1pbi1oZWlnaHQ6IDEwMHZoOwogIG1pbi1oZWlnaHQ6IHZhcigtLXZ2aCwgMTAwZHZoKTsKICBwYWRkaW5nOiBjYWxjKDEwcHggKyBlbnYoc2FmZS1hcmVhLWluc2V0LXRvcCkpIGNhbGMoMTRweCArIGVudihzYWZlLWFyZWEtaW5zZXQtcmlnaHQpKSBjYWxjKDEycHggKyBlbnYoc2FmZS1hcmVhLWluc2V0LWJvdHRvbSkpIGNhbGMoMTRweCArIGVudihzYWZlLWFyZWEtaW5zZXQtbGVmdCkpOwp9CgovKiAtLS0tLS0tLS0tIHRvcCBiYXIgLS0tLS0tLS0tLSAqLwouYmFyIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBnYXA6IDEwcHg7IG1pbi1oZWlnaHQ6IDQ4cHg7IH0KLmJyYW5kIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMHB4OyBtaW4td2lkdGg6IDA7IH0KLmxvZ28gewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgZGlzcGxheTogZ3JpZDsgcGxhY2UtaXRlbXM6IGNlbnRlcjsgZmxleDogbm9uZTsKICB3aWR0aDogMzZweDsgaGVpZ2h0OiAzNnB4OyBib3JkZXItcmFkaXVzOiAxMXB4OyBjb2xvcjogI2ZmZjsKICBiYWNrZ3JvdW5kOiB2YXIoLS1sb2dvLWJnKTsgYm94LXNoYWRvdzogdmFyKC0tbG9nby1zaGFkb3cpOwp9Ci5jb25uLWRvdCB7CiAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogLTNweDsgYm90dG9tOiAtM3B4OyB3aWR0aDogMTJweDsgaGVpZ2h0OiAxMnB4OyBib3JkZXItcmFkaXVzOiA1MCU7CiAgYmFja2dyb3VuZDogIzk0YTNiODsgYm9yZGVyOiAyLjVweCBzb2xpZCB2YXIoLS1yaW5nLWJnKTsgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMjVzOwp9Ci5sb2dvW2RhdGEtY29ubj0ib2siXSAuY29ubi1kb3QgeyBiYWNrZ3JvdW5kOiAjMjJjNTVlOyB9Ci5sb2dvW2RhdGEtY29ubj0iYmFkIl0gLmNvbm4tZG90IHsgYmFja2dyb3VuZDogI2VmNDQ0NDsgfQouYnJhbmQtbmFtZSB7IGZvbnQ6IDgwMCAxOHB4LzEgdmFyKC0tdWkpOyBsZXR0ZXItc3BhY2luZzogLjJweDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLmxvZ28geyBjb2xvcjogIzI1MjIzODsgYm9yZGVyOiAzcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDEwcHg7IH0KLmJhci50aWdodCAuYnJhbmQtbmFtZSB7IGRpc3BsYXk6IG5vbmU7IH0gLyogc2V0IGJ5IGZpdEJhcigpIHdoZW4gdGhlIG5hbWUgd291bGQgcnVuIGludG8gdGhlIGNvbnRyb2xzICovCi5iYXItdG9vbHMgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDhweDsgZmxleDogbm9uZTsgfQoKLnNlZyB7CiAgZGlzcGxheTogaW5saW5lLWZsZXg7IGdhcDogMnB4OyBwYWRkaW5nOiAzcHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OwogIGJhY2tncm91bmQ6IHZhcigtLXNlZy1iZyk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLXNlZy1saW5lKTsKICAtd2Via2l0LWJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7IGJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7Cn0KLnNlZyBidXR0b24gewogIGJvcmRlcjogMDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IGNvbG9yOiB2YXIoLS1pbmsyKTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICBwYWRkaW5nOiAwIDE0cHg7IG1pbi1oZWlnaHQ6IDM0cHg7IGJvcmRlci1yYWRpdXM6IDk5OXB4OyBmb250OiA2NTAgMTRweC8xIHZhcigtLXVpKTsKICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xOHMsIGNvbG9yIC4xOHM7Cn0KLnNlZyBidXR0b25bYXJpYS1jaGVja2VkPSJ0cnVlIl0geyBiYWNrZ3JvdW5kOiB2YXIoLS1zZWctb24tYmcpOyBjb2xvcjogdmFyKC0tc2VnLW9uLWluayk7IGJveC1zaGFkb3c6IHZhcigtLXNlZy1vbi1zaGFkb3cpOyB9Ci5zZWcud2lkZSB7IGRpc3BsYXk6IGZsZXg7IH0KLnNlZy53aWRlIGJ1dHRvbiB7IGZsZXg6IDEgMSAwOyBtaW4taGVpZ2h0OiA0MnB4OyBmb250LXNpemU6IDE1cHg7IH0KCi5pY29uLWJ0biB7CiAgZGlzcGxheTogZ3JpZDsgcGxhY2UtaXRlbXM6IGNlbnRlcjsgZmxleDogbm9uZTsgd2lkdGg6IDQwcHg7IGhlaWdodDogNDBweDsgYm9yZGVyLXJhZGl1czogNTAlOwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLXBhbmVsLWxpbmUpOyBiYWNrZ3JvdW5kOiB2YXIoLS1wYW5lbCk7IGNvbG9yOiB2YXIoLS1pbmsyKTsgYm94LXNoYWRvdzogdmFyKC0tcGFuZWwtc2hhZG93KTsKICAtd2Via2l0LWJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7IGJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7Cn0KLmljb24tYnRuOmFjdGl2ZSB7IHRyYW5zZm9ybTogc2NhbGUoLjk0KTsgfQoKLyogLS0tLS0tLS0tLSB0aGUgc3RyaXAgb2YgYmVhZCB0aWxlcyAoYmVhZHMgb25seSksIGFzIG9uIHRoZSBvcmlnaW5hbCBwYWdlOiAxOCB4IDMsIHNpeCBicmlnaHQgY29sb3VycyAtLS0tLS0tLS0tICovCi5iZWFkc3RyaXAgeyBkaXNwbGF5OiBub25lOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuYmVhZHN0cmlwIHsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiByZXBlYXQoMTgsIDFmcik7IGdhcDogNXB4OyBwYWRkaW5nOiAycHggMnB4IDRweDsgfQouYmVhZHN0cmlwIGkgewogIGRpc3BsYXk6IGJsb2NrOyBoZWlnaHQ6IDEzcHg7IGJvcmRlci1yYWRpdXM6IDRweDsKICBib3JkZXI6IDJweCBzb2xpZCB2YXIoLS10aWxlLWxpbmUpOyBib3gtc2hhZG93OiAxcHggMnB4IDAgdmFyKC0tdGlsZS1zaGFkZSk7CiAgLyogYSBsaXR0bGUgc2hlZW4sIHNvIHRoZSB0aWxlcyByZWFkIGFzIGdsb3NzeSB0cmFuc2x1Y2VudCBiZWFkcyAqLwogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjBkZWcsIHJnYmEoMjU1LCAyNTUsIDI1NSwgLjUpIDAgMjQlLCByZ2JhKDI1NSwgMjU1LCAyNTUsIDApIDUyJSksIHZhcigtLWMpOwp9Ci5iZWFkc3RyaXAgaTpudGgtY2hpbGQoNm4rMSkgeyAtLWM6ICNmZjZiNmI7IH0KLmJlYWRzdHJpcCBpOm50aC1jaGlsZCg2bisyKSB7IC0tYzogI2ZmZDE2NjsgfQouYmVhZHN0cmlwIGk6bnRoLWNoaWxkKDZuKzMpIHsgLS1jOiAjNGVjZGM0OyB9Ci5iZWFkc3RyaXAgaTpudGgtY2hpbGQoNm4rNCkgeyAtLWM6ICM2YzhjZmY7IH0KLmJlYWRzdHJpcCBpOm50aC1jaGlsZCg2bis1KSB7IC0tYzogI2MwODRmYzsgfQouYmVhZHN0cmlwIGk6bnRoLWNoaWxkKDZuKSAgIHsgLS1jOiAjZjc4ZmIzOyB9CkBrZXlmcmFtZXMgYmVhZC1wb3AgewogIDAlICAgeyB0cmFuc2Zvcm06IG5vbmU7IH0KICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC01cHgpIHNjYWxlKDEuMjUpOyB9CiAgMTAwJSB7IHRyYW5zZm9ybTogbm9uZTsgfQp9Ci5iZWFkc3RyaXAud2F2ZSBpIHsgYW5pbWF0aW9uOiBiZWFkLXBvcCAuNTVzIGN1YmljLWJlemllciguMywgMS40LCAuNSwgMSkgYm90aDsgYW5pbWF0aW9uLWRlbGF5OiBjYWxjKHZhcigtLWkpICogMTJtcyk7IH0KLmhpbnQgeyBkaXNwbGF5OiBub25lOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuaGludCB7IGRpc3BsYXk6IGJsb2NrOyBtYXJnaW46IDAgMnB4IC00cHg7IGNvbG9yOiB2YXIoLS1pbmsyKTsgZm9udC1zaXplOiAxNHB4OyB9CgovKiAtLS0tLS0tLS0tIGJhbm5lcnMgLS0tLS0tLS0tLSAqLwouYmFubmVyIHsKICBwYWRkaW5nOiA5cHggMTRweDsgYm9yZGVyLXJhZGl1czogdmFyKC0tci1tZCk7IHRleHQtYWxpZ246IGNlbnRlcjsKICBmb250LXNpemU6IDEzLjVweDsgZm9udC13ZWlnaHQ6IDY1MDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgYmFja2dyb3VuZDogdmFyKC0tY2hpcC1iZyk7IGNvbG9yOiB2YXIoLS1jaGlwLWluayk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNoaXAtbGluZSk7CiAgLXdlYmtpdC1iYWNrZHJvcC1maWx0ZXI6IHZhcigtLWJsdXIpOyBiYWNrZHJvcC1maWx0ZXI6IHZhcigtLWJsdXIpOwp9Ci5iYW5uZXIuaXMtZXJyb3IgeyBjb2xvcjogdmFyKC0tZXJyKTsgYmFja2dyb3VuZDogdmFyKC0tZXJyLWJnKTsgYm9yZGVyLWNvbG9yOiBjdXJyZW50Q29sb3I7IH0KaHRtbFtkYXRhLXRoZW1lPSJiZWFkcyJdIC5iYW5uZXIgeyBib3JkZXI6IDIuNXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3gtc2hhZG93OiAzcHggM3B4IDAgdmFyKC0tc2hhZGUpOyBiYWNrZ3JvdW5kOiB2YXIoLS1wYW5lbCk7IGNvbG9yOiB2YXIoLS1pbmspOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuYmFubmVyLmlzLWVycm9yIHsgY29sb3I6IHZhcigtLWVycik7IGJhY2tncm91bmQ6IHZhcigtLWVyci1iZyk7IGJvcmRlci1jb2xvcjogY3VycmVudENvbG9yOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuc2VnIHsgYm9yZGVyLXdpZHRoOiAyLjVweDsgYm94LXNoYWRvdzogMnB4IDJweCAwIHZhcigtLXNoYWRlKTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnNlZyBidXR0b25bYXJpYS1jaGVja2VkPSJ0cnVlIl0geyBmb250LXdlaWdodDogODAwOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuaWNvbi1idG4geyBib3JkZXI6IDIuNXB4IHNvbGlkIHZhcigtLWxpbmUpOyBib3gtc2hhZG93OiAycHggMnB4IDAgdmFyKC0tc2hhZGUpOyBjb2xvcjogdmFyKC0taW5rKTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLmNoaXAgeyBib3JkZXItd2lkdGg6IDJweDsgZm9udC13ZWlnaHQ6IDgwMDsgfQouYmFubmVyLCAuc3RhdHVzIHsgdGV4dC13cmFwOiBiYWxhbmNlOyB9CgovKiAtLS0tLS0tLS0tIGNvbXBvc2VyOiB0aGUgYmlnIHRleHQgYm94IGFuZCB0aGUgc2VuZCByb3cgLS0tLS0tLS0tLSAqLwouY29tcG9zZXIgeyBmbGV4OiAxIDEgYXV0bzsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiB2YXIoLS1nYXApOyBtaW4taGVpZ2h0OiAwOyB9Ci5maWVsZCB7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBmbGV4OiAxIDEgYXV0bzsgZGlzcGxheTogZmxleDsgbWluLWhlaWdodDogdmFyKC0tdGEtbWluKTsKICBib3JkZXItcmFkaXVzOiB2YXIoLS1yLWxnKTsgYm9yZGVyOiB2YXIoLS1maWVsZC1idykgc29saWQgdmFyKC0tZmllbGQtbGluZSk7CiAgYmFja2dyb3VuZDogdmFyKC0tZmllbGQtYmcpOyBiYWNrZ3JvdW5kLWNsaXA6IHBhZGRpbmctYm94OyBib3gtc2hhZG93OiB2YXIoLS1maWVsZC1zaGFkb3cpOwogIC13ZWJraXQtYmFja2Ryb3AtZmlsdGVyOiB2YXIoLS1maWVsZC1ibHVyKTsgYmFja2Ryb3AtZmlsdGVyOiB2YXIoLS1maWVsZC1ibHVyKTsKICB0cmFuc2l0aW9uOiBib3gtc2hhZG93IC4xNXMsIGJvcmRlci1jb2xvciAuMTVzOwp9Ci5maWVsZDpmb2N1cy13aXRoaW4geyBib3gtc2hhZG93OiB2YXIoLS1maWVsZC1mb2N1cyk7IGJvcmRlci1jb2xvcjogdmFyKC0tZmllbGQtbGluZS1mb2N1cyk7IH0KI3RleHQgewogIGZsZXg6IDE7IHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiB2YXIoLS10YS1taW4pOwogIHBhZGRpbmc6IDE2cHggMTZweCA0OHB4OyBib3JkZXI6IDA7IG91dGxpbmU6IDA7IHJlc2l6ZTogbm9uZTsgYm9yZGVyLXJhZGl1czogaW5oZXJpdDsKICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLWluayk7IGNhcmV0LWNvbG9yOiB2YXIoLS1hY2NlbnQpOwogIGZvbnQ6IHZhcigtLXRhLXNpemUpLzEuNTUgdmFyKC0tdGV4dC1mb250KTsKICAtd2Via2l0LWFwcGVhcmFuY2U6IG5vbmU7IGFwcGVhcmFuY2U6IG5vbmU7Cn0KI3RleHQ6OnBsYWNlaG9sZGVyIHsgY29sb3I6IHZhcigtLWluazMpOyBvcGFjaXR5OiAuOTsgfQouZmllbGQtdG9vbHMgewogIHBvc2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMTZweDsgcmlnaHQ6IDEycHg7IGJvdHRvbTogMTBweDsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IHBvaW50ZXItZXZlbnRzOiBub25lOwp9Ci5maWVsZC10b29scyA+ICogeyBwb2ludGVyLWV2ZW50czogYXV0bzsgfQovKiB3aGVyZSB0aGUgZm9jdXMgd2FpdHMgZm9yIGEgbW9tZW50IGFmdGVyIFNlbmQsIHNvIHRoZSBrZXlib2FyZCBzdGFydHMgYSBuZXcgaW5wdXQgc2Vzc2lvbiAoc2VlIGFwcC5qcykgKi8KLnBhcmsgeyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IDA7IHRvcDogMDsgd2lkdGg6IDFweDsgaGVpZ2h0OiAxcHg7IHBhZGRpbmc6IDA7IGJvcmRlcjogMDsgb3BhY2l0eTogMDsgZm9udC1zaXplOiAxNnB4OyBwb2ludGVyLWV2ZW50czogbm9uZTsgfQouY291bnQgeyBmb250OiA2NTAgMTIuNXB4LzEgdmFyKC0tdWkpOyBjb2xvcjogdmFyKC0taW5rMyk7IGZvbnQtdmFyaWFudC1udW1lcmljOiB0YWJ1bGFyLW51bXM7IH0KLmNvdW50LmlzLXdhcm4geyBjb2xvcjogdmFyKC0td2Fybik7IH0KLmNoaXAgewogIG1pbi1oZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAgMTVweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY2hpcC1saW5lKTsgYmFja2dyb3VuZDogdmFyKC0tY2hpcC1iZyk7IGNvbG9yOiB2YXIoLS1jaGlwLWluayk7CiAgZm9udDogNjUwIDEzLjVweC8xIHZhcigtLXVpKTsKICAtd2Via2l0LWJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7IGJhY2tkcm9wLWZpbHRlcjogdmFyKC0tYmx1cik7Cn0KLmNoaXA6YWN0aXZlIHsgdHJhbnNmb3JtOiBzY2FsZSguOTUpOyB9CkBrZXlmcmFtZXMgc2hha2UgewogIDEwJSwgOTAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC0xcHgpOyB9IDIwJSwgODAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDJweCk7IH0KICAzMCUsIDUwJSwgNzAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC00cHgpOyB9IDQwJSwgNjAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKDRweCk7IH0KfQouZmllbGQuc2hha2UgeyBhbmltYXRpb246IHNoYWtlIC40czsgfQoKLmFjdGlvbnMgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDEwcHg7IH0KLnN3aXRjaCB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMnB4OyBtaW4taGVpZ2h0OiA0MHB4OyBwYWRkaW5nOiAwIDJweDsgY29sb3I6IHZhcigtLWluazIpOyBmb250LXNpemU6IDE1cHg7IGZvbnQtd2VpZ2h0OiA2MDA7IGN1cnNvcjogcG9pbnRlcjsgLXdlYmtpdC11c2VyLXNlbGVjdDogbm9uZTsgdXNlci1zZWxlY3Q6IG5vbmU7IH0KLnN3aXRjaCBpbnB1dCB7IHBvc2l0aW9uOiBhYnNvbHV0ZTsgb3BhY2l0eTogMDsgd2lkdGg6IDFweDsgaGVpZ2h0OiAxcHg7IHBvaW50ZXItZXZlbnRzOiBub25lOyB9Ci5zd2l0Y2gtdWkgewogIHBvc2l0aW9uOiByZWxhdGl2ZTsgZmxleDogbm9uZTsgd2lkdGg6IDQ4cHg7IGhlaWdodDogMjlweDsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGJhY2tncm91bmQ6IHZhcigtLXN3LW9mZik7CiAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMnM7IGJveC1zaGFkb3c6IGluc2V0IDAgMXB4IDNweCByZ2JhKDAsIDAsIDAsIC4xOCk7Cn0KLnN3aXRjaC11aTo6YWZ0ZXIgewogIGNvbnRlbnQ6ICIiOyBwb3NpdGlvbjogYWJzb2x1dGU7IGxlZnQ6IDNweDsgdG9wOiAzcHg7IHdpZHRoOiAyM3B4OyBoZWlnaHQ6IDIzcHg7IGJvcmRlci1yYWRpdXM6IDUwJTsKICBiYWNrZ3JvdW5kOiB2YXIoLS1zdy1rbm9iKTsgYm94LXNoYWRvdzogMCAycHggNXB4IHJnYmEoMCwgMCwgMCwgLjMpOyB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjMsIDEuNCwgLjUsIDEpOwp9Ci5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCArIC5zd2l0Y2gtdWkgeyBiYWNrZ3JvdW5kOiB2YXIoLS1zdy1vbik7IH0KLnN3aXRjaCBpbnB1dDpjaGVja2VkICsgLnN3aXRjaC11aTo6YWZ0ZXIgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTlweCk7IH0KLnN3aXRjaCBpbnB1dDpmb2N1cy12aXNpYmxlICsgLnN3aXRjaC11aSB7IG91dGxpbmU6IDNweCBzb2xpZCB2YXIoLS1mb2N1cy1vdXRsaW5lKTsgb3V0bGluZS1vZmZzZXQ6IDJweDsgfQovKiBiZWFkczogdGhlIG9yaWdpbmFsIHBhZ2UncyBibHVlIGNoZWNrIGJveCAqLwpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnN3aXRjaC11aSB7IHdpZHRoOiAyNHB4OyBoZWlnaHQ6IDI0cHg7IGJvcmRlci1yYWRpdXM6IDZweDsgYm9yZGVyOiAyLjVweCBzb2xpZCB2YXIoLS1saW5lKTsgYmFja2dyb3VuZDogdmFyKC0tcGFuZWwpOyBib3gtc2hhZG93OiAycHggMnB4IDAgdmFyKC0tc2hhZGUpOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuc3dpdGNoLXVpOjphZnRlciB7CiAgbGVmdDogNnB4OyB0b3A6IDFweDsgd2lkdGg6IDdweDsgaGVpZ2h0OiAxM3B4OyBib3JkZXItcmFkaXVzOiAwOyBiYWNrZ3JvdW5kOiBub25lOyBib3gtc2hhZG93OiBub25lOwogIGJvcmRlcjogc29saWQgI2ZmZmZmZjsgYm9yZGVyLXdpZHRoOiAwIDNweCAzcHggMDsgdHJhbnNmb3JtOiByb3RhdGUoNDVkZWcpIHNjYWxlKDApOyB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjE1czsKfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnN3aXRjaCBpbnB1dDpjaGVja2VkICsgLnN3aXRjaC11aSB7IGJhY2tncm91bmQ6IHZhcigtLXN3LW9uKTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnN3aXRjaCBpbnB1dDpjaGVja2VkICsgLnN3aXRjaC11aTo6YWZ0ZXIgeyB0cmFuc2Zvcm06IHJvdGF0ZSg0NWRlZykgc2NhbGUoMSk7IH0KCi5zZW5kIHsKICBwb3NpdGlvbjogcmVsYXRpdmU7IGlzb2xhdGlvbjogaXNvbGF0ZTsKICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZ2FwOiAxMHB4OwogIHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiB2YXIoLS1idG4taCk7IHBhZGRpbmc6IDAgMjJweDsKICBib3JkZXI6IHZhcigtLWJ0bi1idykgc29saWQgdmFyKC0tYnRuLWxpbmUpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yLWxnKTsKICBiYWNrZ3JvdW5kLWltYWdlOiB2YXIoLS1idG4tYmcpOyBiYWNrZ3JvdW5kLWNsaXA6IHBhZGRpbmctYm94OyBjb2xvcjogdmFyKC0tYnRuLWluayk7IGJveC1zaGFkb3c6IHZhcigtLWJ0bi1zaGFkb3cpOwogIGZvbnQ6IDc1MCAxOHB4LzEgdmFyKC0tdWkpOyBsZXR0ZXItc3BhY2luZzogLjNweDsKICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjA4cywgYm94LXNoYWRvdyAuMTJzOwp9Ci5zZW5kOmFjdGl2ZSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHNjYWxlKC45OSk7IGJveC1zaGFkb3c6IHZhcigtLWJ0bi1kb3duKTsgfQouc2VuZDpkaXNhYmxlZCB7IG9wYWNpdHk6IC43MjsgdHJhbnNmb3JtOiBub25lOyB9Ci5zZW5kIC5vay1pY29uLCAuc2VuZC5pcy1vayAuc2VuZC1pY29uIHsgZGlzcGxheTogbm9uZTsgfQouc2VuZC5pcy1vayAub2staWNvbiB7IGRpc3BsYXk6IGJsb2NrOyB9Ci5zZW5kLmlzLW9rIHsgYmFja2dyb3VuZC1pbWFnZTogdmFyKC0tYnRuLW9rLWJnKTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnNlbmQgeyBmb250LXdlaWdodDogODAwOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuc2VuZDphY3RpdmUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgzcHgsIDNweCk7IGJveC1zaGFkb3c6IHZhcigtLWJ0bi1kb3duKTsgfQoKLyogLS0tLS0tLS0tLSBzdGF0dXMgbGluZSBhbmQgZm9vdGVyIC0tLS0tLS0tLS0gKi8KLnN0YXR1cyB7IG1pbi1oZWlnaHQ6IDEuNWVtOyB0ZXh0LWFsaWduOiBjZW50ZXI7IGZvbnQtc2l6ZTogMTVweDsgZm9udC13ZWlnaHQ6IDY1MDsgY29sb3I6IHZhcigtLWluazIpOyB9Ci5zdGF0dXMub2sgeyBjb2xvcjogdmFyKC0tb2spOyB9Ci5zdGF0dXMuZXJyb3IgeyBjb2xvcjogdmFyKC0tZXJyKTsgfQoubm90aWNlIHsgdGV4dC1hbGlnbjogY2VudGVyOyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLWluazMpOyB9CgovKiAtLS0tLS0tLS0tIHNldHRpbmdzIHNoZWV0IC0tLS0tLS0tLS0gKi8KLnNoZWV0LWJhY2tkcm9wIHsKICBwb3NpdGlvbjogZml4ZWQ7IGxlZnQ6IDA7IHRvcDogMDsgcmlnaHQ6IDA7IGJvdHRvbTogMDsgei1pbmRleDogNDA7IGJhY2tncm91bmQ6IHZhcigtLXNjcmltKTsKICAtd2Via2l0LWJhY2tkcm9wLWZpbHRlcjogYmx1cigzcHgpOyBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoM3B4KTsgb3BhY2l0eTogMDsgdHJhbnNpdGlvbjogb3BhY2l0eSAuMjJzOwp9Ci5zaGVldC1iYWNrZHJvcC5vcGVuIHsgb3BhY2l0eTogMTsgfQouc2hlZXQgewogIHBvc2l0aW9uOiBmaXhlZDsgbGVmdDogNTAlOyBib3R0b206IDA7IHotaW5kZXg6IDQxOyB3aWR0aDogbWluKDU2MHB4LCAxMDAlKTsKICBtYXgtaGVpZ2h0OiA4OHZoOyBtYXgtaGVpZ2h0OiA4OGR2aDsgb3ZlcmZsb3cteTogYXV0bzsgb3ZlcnNjcm9sbC1iZWhhdmlvcjogY29udGFpbjsKICBwYWRkaW5nOiA4cHggMThweCBjYWxjKDE4cHggKyBlbnYoc2FmZS1hcmVhLWluc2V0LWJvdHRvbSkpOwogIGJvcmRlci1yYWRpdXM6IDI0cHggMjRweCAwIDA7IGJhY2tncm91bmQ6IHZhcigtLXNoZWV0LWJnKTsgY29sb3I6IHZhcigtLWluayk7CiAgLXdlYmtpdC1iYWNrZHJvcC1maWx0ZXI6IGJsdXIoMjRweCkgc2F0dXJhdGUoMS41KTsgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDI0cHgpIHNhdHVyYXRlKDEuNSk7CiAgYm94LXNoYWRvdzogMCAtMThweCA1MHB4IC0xNnB4IHJnYmEoMCwgMCwgMCwgLjQ1KSwgaW5zZXQgMCAxLjVweCAwIHJnYmEoMjU1LCAyNTUsIDI1NSwgLjUpOwogIHRyYW5zZm9ybTogdHJhbnNsYXRlKC01MCUsIDEwNCUpOyB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjI4cyBjdWJpYy1iZXppZXIoLjIsIC45LCAuMywgMSk7Cn0KLnNoZWV0Lm9wZW4geyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgtNTAlLCAwKTsgfQouc2hlZXQtZ3JhYiB7IHdpZHRoOiA0NHB4OyBoZWlnaHQ6IDVweDsgbWFyZ2luOiA0cHggYXV0byAxMHB4OyBib3JkZXItcmFkaXVzOiA5OXB4OyBiYWNrZ3JvdW5kOiB2YXIoLS1pbmszKTsgb3BhY2l0eTogLjQ7IH0KLnNoZWV0IGgyIHsgbWFyZ2luOiAwIDAgNnB4OyBmb250OiA4MDAgMjBweC8xLjMgdmFyKC0tdWkpOyB9Ci5zaGVldCBoMyB7IG1hcmdpbjogMTZweCAycHggOHB4OyBmb250OiA3MDAgMTNweC8xIHZhcigtLXVpKTsgbGV0dGVyLXNwYWNpbmc6IC42cHg7IGNvbG9yOiB2YXIoLS1pbmszKTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsgfQoudGhlbWUtY2FyZHMgeyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmciAxZnI7IGdhcDogMTJweDsgfQoudGhlbWUtY2FyZCB7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IHN0cmV0Y2g7IGdhcDogM3B4OyB0ZXh0LWFsaWduOiBsZWZ0OyBwYWRkaW5nOiA5cHggOXB4IDEycHg7CiAgYm9yZGVyLXJhZGl1czogMThweDsgYm9yZGVyOiAycHggc29saWQgdmFyKC0tY2hpcC1saW5lKTsgYmFja2dyb3VuZDogdmFyKC0tY2hpcC1iZyk7IGNvbG9yOiB2YXIoLS1pbmspOwp9Ci50aGVtZS1jYXJkW2FyaWEtY2hlY2tlZD0idHJ1ZSJdIHsgYm9yZGVyLWNvbG9yOiB2YXIoLS1hY2NlbnQpOyBib3gtc2hhZG93OiAwIDAgMCAzcHggY29sb3ItbWl4KGluIHNyZ2IsIHZhcigtLWFjY2VudCkgMjIlLCB0cmFuc3BhcmVudCk7IH0KLnRjLW5hbWUgeyBtYXJnaW4tdG9wOiA2cHg7IHBhZGRpbmc6IDAgM3B4OyBmb250OiA3NTAgMTZweC8xLjIgdmFyKC0tdWkpOyB9Ci50Yy1kZXNjIHsgcGFkZGluZzogMCAzcHg7IGZvbnQtc2l6ZTogMTIuNXB4OyBsaW5lLWhlaWdodDogMS4zNTsgY29sb3I6IHZhcigtLWluazIpOyB9Ci5ncm91cC1ub3RlIHsgbWFyZ2luOiA4cHggNHB4IDA7IGZvbnQtc2l6ZTogMTIuNXB4OyBsaW5lLWhlaWdodDogMS40OyBjb2xvcjogdmFyKC0taW5rMyk7IH0KLmFib3V0IHsgbWFyZ2luOiAxOHB4IDAgMDsgdGV4dC1hbGlnbjogY2VudGVyOyBmb250LXNpemU6IDEyLjVweDsgY29sb3I6IHZhcigtLWluazMpOyB9Ci5idG4tZG9uZSB7CiAgZGlzcGxheTogYmxvY2s7IHdpZHRoOiAxMDAlOyBtYXJnaW4tdG9wOiAxMnB4OyBtaW4taGVpZ2h0OiA1MnB4OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yLWxnKTsKICBib3JkZXI6IDEuNXB4IHNvbGlkIHZhcigtLWJ0bi1saW5lKTsgYmFja2dyb3VuZC1pbWFnZTogdmFyKC0tYnRuLWJnKTsgY29sb3I6IHZhcigtLWJ0bi1pbmspOyBib3gtc2hhZG93OiB2YXIoLS1idG4tc2hhZG93KTsKICBmb250OiA3NTAgMTdweC8xIHZhcigtLXVpKTsKfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnNoZWV0IHsgYm9yZGVyOiAzcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1ib3R0b206IDA7IGJvcmRlci1yYWRpdXM6IDE4cHggMThweCAwIDA7IGJveC1zaGFkb3c6IDAgLTRweCAwIHZhcigtLXNoYWRlKTsgLXdlYmtpdC1iYWNrZHJvcC1maWx0ZXI6IG5vbmU7IGJhY2tkcm9wLWZpbHRlcjogbm9uZTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnNoZWV0LWdyYWIgeyBvcGFjaXR5OiAxOyBiYWNrZ3JvdW5kOiB2YXIoLS1saW5lKTsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLnRoZW1lLWNhcmQgeyBib3JkZXI6IDNweCBzb2xpZCB2YXIoLS1saW5lKTsgYmFja2dyb3VuZDogdmFyKC0tcGFuZWwpOyBib3gtc2hhZG93OiAzcHggM3B4IDAgdmFyKC0tc2hhZGUpOyBib3JkZXItcmFkaXVzOiAxNHB4OyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAudGhlbWUtY2FyZFthcmlhLWNoZWNrZWQ9InRydWUiXSB7IGJveC1zaGFkb3c6IDNweCAzcHggMCB2YXIoLS1hY2NlbnQpOyB9Cmh0bWxbZGF0YS10aGVtZT0iYmVhZHMiXSAuYnRuLWRvbmUgeyBib3JkZXI6IDNweCBzb2xpZCB2YXIoLS1saW5lKTsgYm9yZGVyLXJhZGl1czogMTBweDsgZm9udC13ZWlnaHQ6IDgwMDsgfQpodG1sW2RhdGEtdGhlbWU9ImJlYWRzIl0gLmJ0bi1kb25lOmFjdGl2ZSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKDNweCwgM3B4KTsgYm94LXNoYWRvdzogdmFyKC0tYnRuLWRvd24pOyB9CgovKiBtaW5pYXR1cmUgcHJldmlld3Mgb2YgdGhlIHR3byBzdHlsZXMgLSBmaXhlZCBjb2xvdXJzLCB0aGV5IGRvIG5vdCBmb2xsb3cgdGhlIGN1cnJlbnQgc3R5bGUgKi8KLnByZXZpZXcgeyBwb3NpdGlvbjogcmVsYXRpdmU7IGRpc3BsYXk6IGJsb2NrOyBoZWlnaHQ6IDg2cHg7IGJvcmRlci1yYWRpdXM6IDEycHg7IG92ZXJmbG93OiBoaWRkZW47IH0KLnByZXZpZXcgPiBpLCAucHJldmlldyA+IGIgeyBwb3NpdGlvbjogYWJzb2x1dGU7IGRpc3BsYXk6IGJsb2NrOyB9Ci5wdi1idXNpbmVzcyB7IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNmOGZhZmQsICNlZWYyZjgpOyBib3JkZXI6IDFweCBzb2xpZCAjZDllMGVhOyB9Ci5wdi1idXNpbmVzcyAucHYtdGl0bGUgeyBsZWZ0OiA5cHg7IHRvcDogOXB4OyB3aWR0aDogMzQlOyBoZWlnaHQ6IDdweDsgYm9yZGVyLXJhZGl1czogNHB4OyBiYWNrZ3JvdW5kOiAjMGYxNzJhOyB9Ci5wdi1idXNpbmVzcyAucHYtZmllbGQgeyBsZWZ0OiA5cHg7IHJpZ2h0OiA5cHg7IHRvcDogMjRweDsgYm90dG9tOiAzM3B4OyBib3JkZXItcmFkaXVzOiA3cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMXB4IHNvbGlkICNjM2NkZGE7IH0KLnB2LWJ1c2luZXNzIC5wdi1idG4geyBsZWZ0OiA5cHg7IHJpZ2h0OiA5cHg7IGJvdHRvbTogOXB4OyBoZWlnaHQ6IDE3cHg7IGJvcmRlci1yYWRpdXM6IDdweDsgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE4MGRlZywgIzNiNzhmNywgIzI1NTlkOSk7IH0KLnB2LWJlYWRzIHsgYmFja2dyb3VuZDogI2Y4ZjJlODsgYm9yZGVyOiAxcHggc29saWQgI2U2ZGNjYjsgfQoucHYtYmVhZHMgLnB2LXN0cmlwIHsKICBsZWZ0OiA5cHg7IHJpZ2h0OiA5cHg7IHRvcDogOHB4OyBoZWlnaHQ6IDhweDsKICBiYWNrZ3JvdW5kOiByZXBlYXRpbmctbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjZmY2YjZiIDAgOHB4LCB0cmFuc3BhcmVudCA4cHggMTFweCwgI2ZmZDE2NiAxMXB4IDE5cHgsIHRyYW5zcGFyZW50IDE5cHggMjJweCwgIzRlY2RjNCAyMnB4IDMwcHgsCiAgICB0cmFuc3BhcmVudCAzMHB4IDMzcHgsICM2YzhjZmYgMzNweCA0MXB4LCB0cmFuc3BhcmVudCA0MXB4IDQ0cHgsICNjMDg0ZmMgNDRweCA1MnB4LCB0cmFuc3BhcmVudCA1MnB4IDU1cHgsICNmNzhmYjMgNTVweCA2M3B4LCB0cmFuc3BhcmVudCA2M3B4IDY2cHgpOwp9Ci5wdi1iZWFkcyAucHYtZmllbGQgeyBsZWZ0OiA5cHg7IHJpZ2h0OiA5cHg7IHRvcDogMjJweDsgYm90dG9tOiAzMnB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlcjogMnB4IHNvbGlkICMyNTIyMzg7IH0KLnB2LWJlYWRzIC5wdi1idG4geyBsZWZ0OiA5cHg7IHJpZ2h0OiAxMXB4OyBib3R0b206IDlweDsgaGVpZ2h0OiAxNnB4OyBib3JkZXItcmFkaXVzOiA2cHg7IGJhY2tncm91bmQ6ICNmZmQxNjY7IGJvcmRlcjogMnB4IHNvbGlkICMyNTIyMzg7IGJveC1zaGFkb3c6IDJweCAycHggMCAjMjUyMjM4OyB9CgovKiAtLS0tLS0tLS0tIHNtYWxsZXIgc2NyZWVuczogdGhlIGtleWJvYXJkIGlzIHVwLCBvciB0aGUgcGhvbmUgaXMgdGlueSAtLS0tLS0tLS0tICovCi8qIGNvbXBhY3QgPSB1bmRlciA1NjBweCBvZiB1c2FibGUgaGVpZ2h0LiBEZWNvcmF0aW9uIGdvZXMgZmlyc3Qgc28gdGhlIHRleHQgYm94IGFuZCB0aGUgc2VuZCBidXR0b24ga2VlcCB0aGUgcm9vbS4gKi8KaHRtbFtkYXRhLWNvbXBhY3Q9IjEiXSwgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSB7IC0tZ2FwOiA4cHg7IC0tYnRuLWg6IDU0cHg7IH0KaHRtbFtkYXRhLWNvbXBhY3Q9IjEiXSAubm90aWNlLCBodG1sW2RhdGEtY29tcGFjdD0iMiJdIC5ub3RpY2UsCmh0bWxbZGF0YS1jb21wYWN0PSIxIl0gLmJlYWRzdHJpcCwgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAuYmVhZHN0cmlwLApodG1sW2RhdGEtY29tcGFjdD0iMSJdIC5oaW50LCBodG1sW2RhdGEtY29tcGFjdD0iMiJdIC5oaW50IHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9Cmh0bWxbZGF0YS1jb21wYWN0PSIxIl0gLmFwcCwgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAuYXBwIHsgcGFkZGluZy10b3A6IGNhbGMoNnB4ICsgZW52KHNhZmUtYXJlYS1pbnNldC10b3ApKTsgcGFkZGluZy1ib3R0b206IGNhbGMoOHB4ICsgZW52KHNhZmUtYXJlYS1pbnNldC1ib3R0b20pKTsgfQpodG1sW2RhdGEtY29tcGFjdD0iMSJdIC5iYXIsIGh0bWxbZGF0YS1jb21wYWN0PSIyIl0gLmJhciB7IG1pbi1oZWlnaHQ6IDQycHg7IH0KaHRtbFtkYXRhLWNvbXBhY3Q9IjEiXSAubG9nbywgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAubG9nbyB7IHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7IGJvcmRlci1yYWRpdXM6IDEwcHg7IH0KaHRtbFtkYXRhLWNvbXBhY3Q9IjEiXSAuYWN0aW9ucywgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAuYWN0aW9ucyB7IGZsZXgtZGlyZWN0aW9uOiByb3c7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMTJweDsgfQpodG1sW2RhdGEtY29tcGFjdD0iMSJdIC5zZW5kLCBodG1sW2RhdGEtY29tcGFjdD0iMiJdIC5zZW5kIHsgZmxleDogMSAxIGF1dG87IHdpZHRoOiBhdXRvOyB9Cmh0bWxbZGF0YS1jb21wYWN0PSIxIl0gLnN3aXRjaC1sYWJlbCwgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAuc3dpdGNoLWxhYmVsIHsgbWF4LXdpZHRoOiA2LjZlbTsgZm9udC1zaXplOiAxNHB4OyBsaW5lLWhlaWdodDogMS4yOyB9Cmh0bWxbZGF0YS1jb21wYWN0PSIxIl0gLnN0YXR1czplbXB0eSwgaHRtbFtkYXRhLWNvbXBhY3Q9IjIiXSAuc3RhdHVzOmVtcHR5IHsgZGlzcGxheTogbm9uZTsgfQpodG1sW2RhdGEtY29tcGFjdD0iMiJdIHsgLS10YS1taW46IDE0MHB4OyB9CgpAbWVkaWEgKG1pbi13aWR0aDogNzAwcHgpIHsKICA6cm9vdCB7IC0tdGEtbWluOiAzMDBweDsgfQogIC5hcHAgeyBwYWRkaW5nLXRvcDogbWF4KDI2cHgsIGVudihzYWZlLWFyZWEtaW5zZXQtdG9wKSk7IHBhZGRpbmctYm90dG9tOiAyNnB4OyB9Cn0KQG1lZGlhIChvcmllbnRhdGlvbjogbGFuZHNjYXBlKSBhbmQgKG1heC1oZWlnaHQ6IDUyMHB4KSB7CiAgLmNvbXBvc2VyIHsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiBtaW5tYXgoMCwgMWZyKSAyNTBweDsgZ3JpZC1hdXRvLXJvd3M6IG1pbm1heCgwLCAxZnIpOyBnYXA6IDEycHg7IH0KICAuYWN0aW9ucyB7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KICAubm90aWNlLCAuYmVhZHN0cmlwLCAuaGludCB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQp9CgpAbWVkaWEgKHByZWZlcnMtcmVkdWNlZC1tb3Rpb246IHJlZHVjZSkgewogICosICo6OmJlZm9yZSwgKjo6YWZ0ZXIgeyBhbmltYXRpb24tZHVyYXRpb246IC4wMDFtcyAhaW1wb3J0YW50OyBhbmltYXRpb24taXRlcmF0aW9uLWNvdW50OiAxICFpbXBvcnRhbnQ7IHRyYW5zaXRpb24tZHVyYXRpb246IC4wMDFtcyAhaW1wb3J0YW50OyB9Cn0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPG5vc2NyaXB0PjxwIHN0eWxlPSJwYWRkaW5nOjI0cHg7Zm9udDoxNnB4IHN5c3RlbS11aSI+Vm9pY2VCZWFtIG5lZWRzIEphdmFTY3JpcHQuIOmcgOimgeW8gOWQryBKYXZhU2NyaXB044CCPC9wPjwvbm9zY3JpcHQ+Cgo8ZGl2IGNsYXNzPSJiYWNrZHJvcCIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgoKPG1haW4gY2xhc3M9ImFwcCI+CiAgPGhlYWRlciBjbGFzcz0iYmFyIj4KICAgIDxkaXYgY2xhc3M9ImJyYW5kIj4KICAgICAgPHNwYW4gY2xhc3M9ImxvZ28iIGlkPSJsb2dvIiBkYXRhLWNvbm49InVua25vd24iIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICA8c3ZnIGNsYXNzPSJsb2dvLW1pYyIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMjIiIGhlaWdodD0iMjIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHJlY3QgeD0iOSIgeT0iMyIgd2lkdGg9IjYiIGhlaWdodD0iMTEiIHJ4PSIzIiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik01LjUgMTEuNWE2LjUgNi41IDAgMCAwIDEzIDBNMTIgMTh2M005IDIxaDYiLz48L3N2Zz4KICAgICAgICA8aSBjbGFzcz0iY29ubi1kb3QiPjwvaT4KICAgICAgPC9zcGFuPgogICAgICA8c3BhbiBjbGFzcz0iYnJhbmQtbmFtZSI+Vm9pY2VCZWFtPC9zcGFuPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJiYXItdG9vbHMiPgogICAgICA8ZGl2IGNsYXNzPSJzZWciIHJvbGU9InJhZGlvZ3JvdXAiIGRhdGEtaTE4bi1hcmlhLWxhYmVsPSJ0aGVtZS5sYWJlbCIgYXJpYS1sYWJlbD0i6aOO5qC8Ij4KICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgcm9sZT0icmFkaW8iIGFyaWEtY2hlY2tlZD0iZmFsc2UiIGRhdGEtdGhlbWUtc2V0PSJidXNpbmVzcyIgZGF0YS1pMThuPSJ0aGVtZS5idXNpbmVzcyI+5ZWG5YqhPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIHJvbGU9InJhZGlvIiBhcmlhLWNoZWNrZWQ9InRydWUiIGRhdGEtdGhlbWUtc2V0PSJiZWFkcyIgZGF0YS1pMThuPSJ0aGVtZS5iZWFkcyI+5ou86LGGPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9Imljb24tYnRuIiBpZD0ib3BlblNldHRpbmdzIiBkYXRhLWkxOG4tYXJpYS1sYWJlbD0ic2V0dGluZ3Mub3BlbiIgYXJpYS1sYWJlbD0i5aSW6KeC5LiO6K6+572uIiBhcmlhLWhhc3BvcHVwPSJkaWFsb2ciPgogICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMjAiIGhlaWdodD0iMjAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik00IDdoOU0xNyA3aDNNNCAxN2gzTTExIDE3aDkiLz48Y2lyY2xlIGN4PSIxNSIgY3k9IjciIHI9IjIuMiIvPjxjaXJjbGUgY3g9IjkiIGN5PSIxNyIgcj0iMi4yIi8+PC9zdmc+CiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9oZWFkZXI+CgogIDxkaXYgY2xhc3M9ImJlYWRzdHJpcCIgaWQ9ImJlYWRzdHJpcCIgYXJpYS1oaWRkZW49InRydWUiPjwvZGl2PgoKICA8ZGl2IGNsYXNzPSJiYW5uZXIiIGlkPSJkZW1vQmFubmVyIiBkYXRhLWkxOG49ImRlbW9fYmFubmVyIiBoaWRkZW4+5ryU56S65qih5byP77ya5paH5a2X5LiN5Lya57KY6LS05Yiw55S16ISRPC9kaXY+CiAgPGRpdiBjbGFzcz0iYmFubmVyIGlzLWVycm9yIiBpZD0iY29ubkJhbm5lciIgcm9sZT0iYWxlcnQiIGhpZGRlbj48L2Rpdj4KCiAgPGZvcm0gaWQ9ImZvcm0iIGNsYXNzPSJjb21wb3NlciIgYXV0b2NvbXBsZXRlPSJvZmYiPgogICAgPHAgY2xhc3M9ImhpbnQiIGRhdGEtaTE4bj0iaGludCI+6L6T5YWl5paH5a2X77yM5Y+R6YCB5Yiw55S16ISR5b2T5YmN5YWJ5qCHPC9wPgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8dGV4dGFyZWEgaWQ9InRleHQiIGF1dG9mb2N1cyBzcGVsbGNoZWNrPSJmYWxzZSIgYXV0b2NvbXBsZXRlPSJvZmYiIGF1dG9jb3JyZWN0PSJvZmYiIGVudGVya2V5aGludD0iZW50ZXIiIGRhdGEtaTE4bi1wbGFjZWhvbGRlcj0icGxhY2Vob2xkZXIiIGRhdGEtaTE4bi1hcmlhLWxhYmVsPSJwbGFjZWhvbGRlciIgYXJpYS1sYWJlbD0i54K55Ye76L+Z6YeM77yM5L2/55So5omL5py66K+t6Z+z6L6T5YWlIiBwbGFjZWhvbGRlcj0i54K55Ye76L+Z6YeM77yM5L2/55So5omL5py66K+t6Z+z6L6T5YWlIj48L3RleHRhcmVhPgogICAgICA8aW5wdXQgaWQ9InBhcmsiIGNsYXNzPSJwYXJrIiB0eXBlPSJ0ZXh0IiB0YWJpbmRleD0iLTEiIGFyaWEtaGlkZGVuPSJ0cnVlIiBhdXRvY29tcGxldGU9Im9mZiIgYXV0b2NvcnJlY3Q9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZC10b29scyI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImNvdW50IiBpZD0iY291bnQiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L3NwYW4+CiAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzPSJjaGlwIiBpZD0iY2xlYXIiIGRhdGEtaTE4bj0iY2xlYXIiIGhpZGRlbj7muIXnqbo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhY3Rpb25zIj4KICAgICAgPGxhYmVsIGNsYXNzPSJzd2l0Y2giPgogICAgICAgIDxpbnB1dCBpZD0iZW50ZXIiIHR5cGU9ImNoZWNrYm94IiBjaGVja2VkPgogICAgICAgIDxzcGFuIGNsYXNzPSJzd2l0Y2gtdWkiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L3NwYW4+CiAgICAgICAgPHNwYW4gY2xhc3M9InN3aXRjaC1sYWJlbCIgZGF0YS1pMThuPSJlbnRlciI+5Y+R6YCB5ZCO5oyJ5Zue6L2mPC9zcGFuPgogICAgICA8L2xhYmVsPgogICAgICA8YnV0dG9uIGlkPSJzZW5kIiBjbGFzcz0ic2VuZCIgdHlwZT0ic3VibWl0Ij4KICAgICAgICA8c3ZnIGNsYXNzPSJzZW5kLWljb24iIHZpZXdCb3g9IjAgMCAyNCAyNCIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHBhdGggZmlsbD0iY3VycmVudENvbG9yIiBkPSJNMy40IDIwLjQgMjEuNSAxMiAzLjQgMy42bC0uMSA2LjVMMTUgMTIgMy4zIDEzLjl6Ii8+PC9zdmc+CiAgICAgICAgPHN2ZyBjbGFzcz0ib2staWNvbiIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMjAiIGhlaWdodD0iMjAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgYXJpYS1oaWRkZW49InRydWUiPjxwYXRoIGQ9Ik01IDEyLjVsNC42IDQuNkwxOSA3LjUiLz48L3N2Zz4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VuZC1sYWJlbCIgaWQ9InNlbmRMYWJlbCIgZGF0YS1pMThuPSJzZW5kIj7lj5HpgIHliLDnlLXohJE8L3NwYW4+CiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9mb3JtPgoKICA8ZGl2IGNsYXNzPSJzdGF0dXMiIGlkPSJzdGF0dXMiIHJvbGU9InN0YXR1cyIgYXJpYS1saXZlPSJwb2xpdGUiPjwvZGl2PgogIDxmb290ZXIgY2xhc3M9Im5vdGljZSIgZGF0YS1pMThuPSJub3RpY2UiPuS7hemAgueUqOS6juWPr+S/oeWxgOWfn+e9kSDCtyDkuI3kv53lrZjovpPlhaXlhoXlrrk8L2Zvb3Rlcj4KPC9tYWluPgoKPGRpdiBjbGFzcz0ic2hlZXQtYmFja2Ryb3AiIGlkPSJzaGVldEJhY2tkcm9wIiBoaWRkZW4+PC9kaXY+CjxzZWN0aW9uIGNsYXNzPSJzaGVldCIgaWQ9InNoZWV0IiByb2xlPSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiIGFyaWEtbGFiZWxsZWRieT0ic2hlZXRUaXRsZSIgaGlkZGVuPgogIDxkaXYgY2xhc3M9InNoZWV0LWdyYWIiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KICA8aDIgaWQ9InNoZWV0VGl0bGUiIGRhdGEtaTE4bj0ic2V0dGluZ3MudGl0bGUiPuWkluinguS4juiuvue9rjwvaDI+CgogIDxkaXYgY2xhc3M9Imdyb3VwIj4KICAgIDxoMyBkYXRhLWkxOG49InRoZW1lLmxhYmVsIj7po47moLw8L2gzPgogICAgPGRpdiBjbGFzcz0idGhlbWUtY2FyZHMiIHJvbGU9InJhZGlvZ3JvdXAiIGRhdGEtaTE4bi1hcmlhLWxhYmVsPSJ0aGVtZS5sYWJlbCIgYXJpYS1sYWJlbD0i6aOO5qC8Ij4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIHJvbGU9InJhZGlvIiBhcmlhLWNoZWNrZWQ9ImZhbHNlIiBjbGFzcz0idGhlbWUtY2FyZCIgZGF0YS10aGVtZS1zZXQ9ImJ1c2luZXNzIj4KICAgICAgICA8c3BhbiBjbGFzcz0icHJldmlldyBwdi1idXNpbmVzcyIgYXJpYS1oaWRkZW49InRydWUiPjxpIGNsYXNzPSJwdi10aXRsZSI+PC9pPjxpIGNsYXNzPSJwdi1maWVsZCI+PC9pPjxpIGNsYXNzPSJwdi1idG4iPjwvaT48L3NwYW4+CiAgICAgICAgPHNwYW4gY2xhc3M9InRjLW5hbWUiIGRhdGEtaTE4bj0idGhlbWUuYnVzaW5lc3MiPuWVhuWKoTwvc3Bhbj4KICAgICAgICA8c3BhbiBjbGFzcz0idGMtZGVzYyIgZGF0YS1pMThuPSJ0aGVtZS5idXNpbmVzcy5kZXNjIj48L3NwYW4+CiAgICAgIDwvYnV0dG9uPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgcm9sZT0icmFkaW8iIGFyaWEtY2hlY2tlZD0idHJ1ZSIgY2xhc3M9InRoZW1lLWNhcmQiIGRhdGEtdGhlbWUtc2V0PSJiZWFkcyI+CiAgICAgICAgPHNwYW4gY2xhc3M9InByZXZpZXcgcHYtYmVhZHMiIGFyaWEtaGlkZGVuPSJ0cnVlIj48aSBjbGFzcz0icHYtc3RyaXAiPjwvaT48aSBjbGFzcz0icHYtZmllbGQiPjwvaT48aSBjbGFzcz0icHYtYnRuIj48L2k+PC9zcGFuPgogICAgICAgIDxzcGFuIGNsYXNzPSJ0Yy1uYW1lIiBkYXRhLWkxOG49InRoZW1lLmJlYWRzIj7mi7zosYY8L3NwYW4+CiAgICAgICAgPHNwYW4gY2xhc3M9InRjLWRlc2MiIGRhdGEtaTE4bj0idGhlbWUuYmVhZHMuZGVzYyI+PC9zcGFuPgogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8ZGl2IGNsYXNzPSJncm91cCI+CiAgICA8aDMgZGF0YS1pMThuPSJzZXR0aW5ncy5tb2RlIj7mmI7mmpc8L2gzPgogICAgPGRpdiBjbGFzcz0ic2VnIHdpZGUiIHJvbGU9InJhZGlvZ3JvdXAiIGRhdGEtcHJlZj0ibW9kZSIgZGF0YS1pMThuLWFyaWEtbGFiZWw9InNldHRpbmdzLm1vZGUiIGFyaWEtbGFiZWw9IuaYjuaalyI+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiByb2xlPSJyYWRpbyIgYXJpYS1jaGVja2VkPSJ0cnVlIiBkYXRhLXZhbHVlPSJhdXRvIiBkYXRhLWkxOG49Im1vZGUuYXV0byI+6Lef6ZqP57O757ufPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiByb2xlPSJyYWRpbyIgYXJpYS1jaGVja2VkPSJmYWxzZSIgZGF0YS12YWx1ZT0ibGlnaHQiIGRhdGEtaTE4bj0ibW9kZS5saWdodCI+5rWF6ImyPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiByb2xlPSJyYWRpbyIgYXJpYS1jaGVja2VkPSJmYWxzZSIgZGF0YS12YWx1ZT0iZGFyayIgZGF0YS1pMThuPSJtb2RlLmRhcmsiPua3seiJsjwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDxkaXYgY2xhc3M9Imdyb3VwIj4KICAgIDxoMyBkYXRhLWkxOG49InNldHRpbmdzLnNpemUiPui+k+WFpeWtl+WPtzwvaDM+CiAgICA8ZGl2IGNsYXNzPSJzZWcgd2lkZSIgcm9sZT0icmFkaW9ncm91cCIgZGF0YS1wcmVmPSJzaXplIiBkYXRhLWkxOG4tYXJpYS1sYWJlbD0ic2V0dGluZ3Muc2l6ZSIgYXJpYS1sYWJlbD0i6L6T5YWl5a2X5Y+3Ij4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIHJvbGU9InJhZGlvIiBhcmlhLWNoZWNrZWQ9InRydWUiIGRhdGEtdmFsdWU9InN0ZCIgZGF0YS1pMThuPSJzaXplLnN0ZCI+5qCH5YeGPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiByb2xlPSJyYWRpbyIgYXJpYS1jaGVja2VkPSJmYWxzZSIgZGF0YS12YWx1ZT0ibGciIGRhdGEtaTE4bj0ic2l6ZS5sZyI+5aSnPC9idXR0b24+CiAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiByb2xlPSJyYWRpbyIgYXJpYS1jaGVja2VkPSJmYWxzZSIgZGF0YS12YWx1ZT0ieGwiIGRhdGEtaTE4bj0ic2l6ZS54bCI+54m55aSnPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iZ3JvdXAiPgogICAgPGgzIGRhdGEtaTE4bj0ic2V0dGluZ3MuYWZ0ZXIiPuWPkemAgeWQjjwvaDM+CiAgICA8ZGl2IGNsYXNzPSJzZWcgd2lkZSIgcm9sZT0icmFkaW9ncm91cCIgZGF0YS1wcmVmPSJhZnRlciIgZGF0YS1pMThuLWFyaWEtbGFiZWw9InNldHRpbmdzLmFmdGVyIiBhcmlhLWxhYmVsPSLlj5HpgIHlkI4iPgogICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgcm9sZT0icmFkaW8iIGFyaWEtY2hlY2tlZD0idHJ1ZSIgZGF0YS12YWx1ZT0ia2VlcCIgZGF0YS1pMThuPSJhZnRlci5rZWVwIj7plK7nm5jkv53mjIHmiZPlvIA8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIHJvbGU9InJhZGlvIiBhcmlhLWNoZWNrZWQ9ImZhbHNlIiBkYXRhLXZhbHVlPSJjbG9zZSIgZGF0YS1pMThuPSJhZnRlci5jbG9zZSI+5pS26LW36ZSu55uYPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxwIGNsYXNzPSJncm91cC1ub3RlIiBkYXRhLWkxOG49ImFmdGVyLm5vdGUiPuWmguaenOWPkemAgeWQjuivremfs+i+k+WFpei/mOWcqOe7p+e7reWQrOWGme+8jOivt+mAieKAnOaUtui1t+mUruebmOKAneOAgjwvcD4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iZ3JvdXAiPgogICAgPGgzIGRhdGEtaTE4bj0ic2V0dGluZ3MubGFuZyI+6K+t6KiAPC9oMz4KICAgIDxkaXYgY2xhc3M9InNlZyB3aWRlIiByb2xlPSJyYWRpb2dyb3VwIiBkYXRhLXByZWY9ImxhbmciIGlkPSJsYW5nU2VnIiBkYXRhLWkxOG4tYXJpYS1sYWJlbD0ic2V0dGluZ3MubGFuZyIgYXJpYS1sYWJlbD0i6K+t6KiAIj48L2Rpdj4KICA8L2Rpdj4KCiAgPHAgY2xhc3M9ImFib3V0IiBpZD0iYWJvdXQiPjwvcD4KICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgY2xhc3M9ImJ0bi1kb25lIiBpZD0ic2hlZXRDbG9zZSIgZGF0YS1pMThuPSJjbG9zZSI+5a6M5oiQPC9idXR0b24+Cjwvc2VjdGlvbj4KCjxzY3JpcHQ+LyogVm9pY2VCZWFtIHBhZ2UgbG9naWMuIFBsYWluIEVTMjAxNywgbm8gZGVwZW5kZW5jaWVzLCBhbmQgbm90aGluZyBldmVyIGxlYXZlcyB0aGUgbG9jYWwgbmV0d29yay4gKi8KKGZ1bmN0aW9uICgpIHsKICAndXNlIHN0cmljdCc7CgogIHZhciBDRkcgPSB3aW5kb3cuX19WQl9fIHx8IHt9OwogIHZhciBMT0NBTEVTID0gd2luZG93Ll9fVkJfTE9DQUxFU19fIHx8IHt9OwogIHZhciBNQVggPSBDRkcubWF4TGVuZ3RoIHx8IDE2Mzg0OwogIHZhciByb290ID0gZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50OwoKICBmdW5jdGlvbiAkKHNlbGVjdG9yLCBzY29wZSkgeyByZXR1cm4gKHNjb3BlIHx8IGRvY3VtZW50KS5xdWVyeVNlbGVjdG9yKHNlbGVjdG9yKTsgfQogIGZ1bmN0aW9uICRhbGwoc2VsZWN0b3IsIHNjb3BlKSB7IHJldHVybiBBcnJheS5wcm90b3R5cGUuc2xpY2UuY2FsbCgoc2NvcGUgfHwgZG9jdW1lbnQpLnF1ZXJ5U2VsZWN0b3JBbGwoc2VsZWN0b3IpKTsgfQoKICAvKiAtLS0tLS0tLS0tIHByZWZlcmVuY2VzIChzdG9yZWQgb24gdGhpcyBwaG9uZSBvbmx5KSAtLS0tLS0tLS0tICovCiAgdmFyIHN0b3JlID0gewogICAgZ2V0OiBmdW5jdGlvbiAoa2V5LCBmYWxsYmFjaykgewogICAgICB0cnkgeyB2YXIgdmFsdWUgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgndmIuJyArIGtleSk7IHJldHVybiB2YWx1ZSA9PT0gbnVsbCA/IGZhbGxiYWNrIDogdmFsdWU7IH0gY2F0Y2ggKGUpIHsgcmV0dXJuIGZhbGxiYWNrOyB9CiAgICB9LAogICAgc2V0OiBmdW5jdGlvbiAoa2V5LCB2YWx1ZSkgewogICAgICB0cnkgeyBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgndmIuJyArIGtleSwgdmFsdWUpOyB9IGNhdGNoIChlKSB7IC8qIHByaXZhdGUgbW9kZTogdGhlIGNob2ljZSBqdXN0IGRvZXMgbm90IHBlcnNpc3QgKi8gfQogICAgfQogIH07CiAgZnVuY3Rpb24gb25lT2YodmFsdWUsIGFsbG93ZWQsIGZhbGxiYWNrKSB7IHJldHVybiBhbGxvd2VkLmluZGV4T2YodmFsdWUpID49IDAgPyB2YWx1ZSA6IGZhbGxiYWNrOyB9CiAgdmFyIHByZWZzID0gewogICAgdGhlbWU6IG9uZU9mKHN0b3JlLmdldCgndGhlbWUnLCBDRkcudGhlbWUgfHwgJ2JlYWRzJyksIFsnYnVzaW5lc3MnLCAnYmVhZHMnXSwgQ0ZHLnRoZW1lIHx8ICdiZWFkcycpLAogICAgbW9kZTogb25lT2Yoc3RvcmUuZ2V0KCdtb2RlJywgJ2F1dG8nKSwgWydhdXRvJywgJ2xpZ2h0JywgJ2RhcmsnXSwgJ2F1dG8nKSwKICAgIHNpemU6IG9uZU9mKHN0b3JlLmdldCgnc2l6ZScsICdzdGQnKSwgWydzdGQnLCAnbGcnLCAneGwnXSwgJ3N0ZCcpLAogICAgbGFuZzogc3RvcmUuZ2V0KCdsYW5nJywgJ2F1dG8nKSwKICAgIGFmdGVyOiBvbmVPZihzdG9yZS5nZXQoJ2FmdGVyJywgJ2tlZXAnKSwgWydrZWVwJywgJ2Nsb3NlJ10sICdrZWVwJykgLyogd2hhdCB0aGUga2V5Ym9hcmQgZG9lcyBhZnRlciBTZW5kICovCiAgfTsKCiAgLyogLS0tLS0tLS0tLSBsYW5ndWFnZSAtLS0tLS0tLS0tICovCiAgdmFyIGxhbmcgPSAnZW4nOwogIGZ1bmN0aW9uIHBpY2tMYW5nKCkgewogICAgdmFyIGNvZGVzID0gT2JqZWN0LmtleXMoTE9DQUxFUyk7CiAgICBpZiAocHJlZnMubGFuZyAhPT0gJ2F1dG8nICYmIExPQ0FMRVNbcHJlZnMubGFuZ10pIHJldHVybiBwcmVmcy5sYW5nOwogICAgdmFyIHdhbnRlZCA9IG5hdmlnYXRvci5sYW5ndWFnZXMgJiYgbmF2aWdhdG9yLmxhbmd1YWdlcy5sZW5ndGggPyBuYXZpZ2F0b3IubGFuZ3VhZ2VzIDogW25hdmlnYXRvci5sYW5ndWFnZSB8fCAnZW4nXTsKICAgIGZvciAodmFyIGkgPSAwOyBpIDwgd2FudGVkLmxlbmd0aDsgaSsrKSB7CiAgICAgIHZhciBmdWxsID0gU3RyaW5nKHdhbnRlZFtpXSkudG9Mb3dlckNhc2UoKTsKICAgICAgdmFyIGJhc2UgPSBmdWxsLnNwbGl0KCctJylbMF07CiAgICAgIHZhciBqOwogICAgICBmb3IgKGogPSAwOyBqIDwgY29kZXMubGVuZ3RoOyBqKyspIGlmIChjb2Rlc1tqXS50b0xvd2VyQ2FzZSgpID09PSBmdWxsKSByZXR1cm4gY29kZXNbal07CiAgICAgIGZvciAoaiA9IDA7IGogPCBjb2Rlcy5sZW5ndGg7IGorKykgaWYgKGNvZGVzW2pdLnRvTG93ZXJDYXNlKCkuc3BsaXQoJy0nKVswXSA9PT0gYmFzZSkgcmV0dXJuIGNvZGVzW2pdOwogICAgfQogICAgcmV0dXJuIExPQ0FMRVMuZW4gPyAnZW4nIDogY29kZXNbMF07CiAgfQogIGZ1bmN0aW9uIGhhc0tleShrZXkpIHsKICAgIHJldHVybiAoTE9DQUxFU1tsYW5nXSAmJiBMT0NBTEVTW2xhbmddW2tleV0gIT09IHVuZGVmaW5lZCkgfHwgKExPQ0FMRVMuZW4gJiYgTE9DQUxFUy5lbltrZXldICE9PSB1bmRlZmluZWQpOwogIH0KICBmdW5jdGlvbiBUKGtleSwgcGFyYW1zKSB7CiAgICB2YXIgb3duID0gTE9DQUxFU1tsYW5nXSB8fCB7fTsKICAgIHZhciB0ZXh0ID0gb3duW2tleV0gIT09IHVuZGVmaW5lZCA/IG93bltrZXldIDogKExPQ0FMRVMuZW4gJiYgTE9DQUxFUy5lbltrZXldICE9PSB1bmRlZmluZWQgPyBMT0NBTEVTLmVuW2tleV0gOiBrZXkpOwogICAgaWYgKCFwYXJhbXMpIHJldHVybiB0ZXh0OwogICAgcmV0dXJuIHRleHQucmVwbGFjZSgvXHsoXHcrKVx9L2csIGZ1bmN0aW9uICh3aG9sZSwgbmFtZSkgeyByZXR1cm4gcGFyYW1zW25hbWVdICE9PSB1bmRlZmluZWQgPyBwYXJhbXNbbmFtZV0gOiB3aG9sZTsgfSk7CiAgfQogIGZ1bmN0aW9uIHRyYW5zbGF0ZSgpIHsKICAgIHJvb3Quc2V0QXR0cmlidXRlKCdsYW5nJywgbGFuZyk7CiAgICAkYWxsKCdbZGF0YS1pMThuXScpLmZvckVhY2goZnVuY3Rpb24gKGVsKSB7IGVsLnRleHRDb250ZW50ID0gVChlbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtaTE4bicpKTsgfSk7CiAgICAkYWxsKCdbZGF0YS1pMThuLXBsYWNlaG9sZGVyXScpLmZvckVhY2goZnVuY3Rpb24gKGVsKSB7IGVsLnNldEF0dHJpYnV0ZSgncGxhY2Vob2xkZXInLCBUKGVsLmdldEF0dHJpYnV0ZSgnZGF0YS1pMThuLXBsYWNlaG9sZGVyJykpKTsgfSk7CiAgICAkYWxsKCdbZGF0YS1pMThuLWFyaWEtbGFiZWxdJykuZm9yRWFjaChmdW5jdGlvbiAoZWwpIHsgZWwuc2V0QXR0cmlidXRlKCdhcmlhLWxhYmVsJywgVChlbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtaTE4bi1hcmlhLWxhYmVsJykpKTsgfSk7CiAgfQogIGZ1bmN0aW9uIGJ1aWxkTGFuZ3VhZ2VDaG9pY2VzKCkgewogICAgdmFyIGdyb3VwID0gJCgnI2xhbmdTZWcnKTsKICAgIGdyb3VwLnRleHRDb250ZW50ID0gJyc7CiAgICBbJ2F1dG8nXS5jb25jYXQoT2JqZWN0LmtleXMoTE9DQUxFUykpLmZvckVhY2goZnVuY3Rpb24gKGNvZGUpIHsKICAgICAgdmFyIGJ1dHRvbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICBidXR0b24udHlwZSA9ICdidXR0b24nOwogICAgICBidXR0b24uc2V0QXR0cmlidXRlKCdyb2xlJywgJ3JhZGlvJyk7CiAgICAgIGJ1dHRvbi5zZXRBdHRyaWJ1dGUoJ2RhdGEtdmFsdWUnLCBjb2RlKTsKICAgICAgaWYgKGNvZGUgPT09ICdhdXRvJykgYnV0dG9uLnNldEF0dHJpYnV0ZSgnZGF0YS1pMThuJywgJ2xhbmcuYXV0bycpOwogICAgICBlbHNlIGJ1dHRvbi50ZXh0Q29udGVudCA9IExPQ0FMRVNbY29kZV0uX25hbWUgfHwgY29kZTsKICAgICAgZ3JvdXAuYXBwZW5kQ2hpbGQoYnV0dG9uKTsKICAgIH0pOwogIH0KCiAgLyogLS0tLS0tLS0tLSBhcHBlYXJhbmNlIC0tLS0tLS0tLS0gKi8KICB2YXIgbWVkaWEgPSB3aW5kb3cubWF0Y2hNZWRpYSA/IHdpbmRvdy5tYXRjaE1lZGlhKCcocHJlZmVycy1jb2xvci1zY2hlbWU6IGRhcmspJykgOiBudWxsOwogIGZ1bmN0aW9uIHJlc29sdmVkTW9kZSgpIHsgcmV0dXJuIHByZWZzLm1vZGUgPT09ICdhdXRvJyA/IChtZWRpYSAmJiBtZWRpYS5tYXRjaGVzID8gJ2RhcmsnIDogJ2xpZ2h0JykgOiBwcmVmcy5tb2RlOyB9CiAgZnVuY3Rpb24gcGFpbnRDaG9pY2VzKCkgewogICAgJGFsbCgnW2RhdGEtdGhlbWUtc2V0XScpLmZvckVhY2goZnVuY3Rpb24gKGVsKSB7CiAgICAgIGVsLnNldEF0dHJpYnV0ZSgnYXJpYS1jaGVja2VkJywgU3RyaW5nKGVsLmdldEF0dHJpYnV0ZSgnZGF0YS10aGVtZS1zZXQnKSA9PT0gcHJlZnMudGhlbWUpKTsKICAgIH0pOwogICAgJGFsbCgnW2RhdGEtcHJlZl0nKS5mb3JFYWNoKGZ1bmN0aW9uIChncm91cCkgewogICAgICB2YXIga2V5ID0gZ3JvdXAuZ2V0QXR0cmlidXRlKCdkYXRhLXByZWYnKTsKICAgICAgJGFsbCgnYnV0dG9uJywgZ3JvdXApLmZvckVhY2goZnVuY3Rpb24gKGVsKSB7CiAgICAgICAgZWwuc2V0QXR0cmlidXRlKCdhcmlhLWNoZWNrZWQnLCBTdHJpbmcoZWwuZ2V0QXR0cmlidXRlKCdkYXRhLXZhbHVlJykgPT09IHByZWZzW2tleV0pKTsKICAgICAgfSk7CiAgICB9KTsKICB9CiAgZnVuY3Rpb24gYXBwbHlBcHBlYXJhbmNlKCkgewogICAgcm9vdC5zZXRBdHRyaWJ1dGUoJ2RhdGEtdGhlbWUnLCBwcmVmcy50aGVtZSk7CiAgICByb290LnNldEF0dHJpYnV0ZSgnZGF0YS1tb2RlJywgcmVzb2x2ZWRNb2RlKCkpOwogICAgcm9vdC5zZXRBdHRyaWJ1dGUoJ2RhdGEtc2l6ZScsIHByZWZzLnNpemUpOwogICAgcGFpbnRDaG9pY2VzKCk7CiAgICB2YXIgbWV0YSA9ICQoJ21ldGFbbmFtZT0idGhlbWUtY29sb3IiXScpOwogICAgdmFyIGNocm9tZSA9IGdldENvbXB1dGVkU3R5bGUocm9vdCkuZ2V0UHJvcGVydHlWYWx1ZSgnLS1jaHJvbWUnKS50cmltKCk7CiAgICBpZiAobWV0YSAmJiBjaHJvbWUpIG1ldGEuc2V0QXR0cmlidXRlKCdjb250ZW50JywgY2hyb21lKTsKICB9CiAgZnVuY3Rpb24gc2V0UHJlZihrZXksIHZhbHVlKSB7CiAgICBwcmVmc1trZXldID0gdmFsdWU7CiAgICBzdG9yZS5zZXQoa2V5LCB2YWx1ZSk7CiAgICBpZiAoa2V5ID09PSAnbGFuZycpIHsKICAgICAgbGFuZyA9IHBpY2tMYW5nKCk7CiAgICAgIHRyYW5zbGF0ZSgpOwogICAgICByZW5kZXJDb25uZWN0aW9uKCk7CiAgICAgIGZpdEJhcigpOwogICAgICBzYXkoJycpOwogICAgfQogICAgYXBwbHlBcHBlYXJhbmNlKCk7CiAgfQogIGlmIChtZWRpYSkgewogICAgaWYgKG1lZGlhLmFkZEV2ZW50TGlzdGVuZXIpIG1lZGlhLmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsIGFwcGx5QXBwZWFyYW5jZSk7CiAgICBlbHNlIGlmIChtZWRpYS5hZGRMaXN0ZW5lcikgbWVkaWEuYWRkTGlzdGVuZXIoYXBwbHlBcHBlYXJhbmNlKTsKICB9CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBmdW5jdGlvbiAoZXZlbnQpIHsKICAgIHZhciBidXR0b24gPSBldmVudC50YXJnZXQuY2xvc2VzdCA/IGV2ZW50LnRhcmdldC5jbG9zZXN0KCdidXR0b24nKSA6IG51bGw7CiAgICBpZiAoIWJ1dHRvbikgcmV0dXJuOwogICAgdmFyIHRoZW1lID0gYnV0dG9uLmdldEF0dHJpYnV0ZSgnZGF0YS10aGVtZS1zZXQnKTsKICAgIGlmICh0aGVtZSkgeyBzZXRQcmVmKCd0aGVtZScsIHRoZW1lKTsgcmV0dXJuOyB9CiAgICB2YXIgZ3JvdXAgPSBidXR0b24uY2xvc2VzdCgnW2RhdGEtcHJlZl0nKTsKICAgIGlmIChncm91cCkgc2V0UHJlZihncm91cC5nZXRBdHRyaWJ1dGUoJ2RhdGEtcHJlZicpLCBidXR0b24uZ2V0QXR0cmlidXRlKCdkYXRhLXZhbHVlJykpOwogIH0pOwoKICAvKiAtLS0tLS0tLS0tIGZpdCB0aGUgc2NyZWVuOiBmb2xsb3cgdGhlIHZpc2libGUgYXJlYSwgc28gdGhlIGtleWJvYXJkIG5ldmVyIGhpZGVzIHRoZSBzZW5kIGJ1dHRvbiAtLS0tLS0tLS0tICovCiAgdmFyIGxhc3RIZWlnaHQgPSAwOwogIGZ1bmN0aW9uIGZpdCgpIHsKICAgIHZhciB2aWV3cG9ydCA9IHdpbmRvdy52aXN1YWxWaWV3cG9ydDsKICAgIHZhciBoZWlnaHQgPSBNYXRoLnJvdW5kKHZpZXdwb3J0ID8gdmlld3BvcnQuaGVpZ2h0IDogd2luZG93LmlubmVySGVpZ2h0KTsKICAgIGlmIChoZWlnaHQgPT09IGxhc3RIZWlnaHQpIHJldHVybjsKICAgIGxhc3RIZWlnaHQgPSBoZWlnaHQ7CiAgICByb290LnN0eWxlLnNldFByb3BlcnR5KCctLXZ2aCcsIGhlaWdodCArICdweCcpOwogICAgLyogVW5kZXIgNTYwcHggKGtleWJvYXJkIG9wZW4sIG9yIGEgc21hbGwgcGhvbmUpIHRoZSBkZWNvcmF0aW9uIGdvZXMgZmlyc3Qgc28gdGhlIHRleHQgYm94IGtlZXBzIHRoZSByb29tLiAqLwogICAgcm9vdC5zZXRBdHRyaWJ1dGUoJ2RhdGEtY29tcGFjdCcsIGhlaWdodCA8IDQzMCA/ICcyJyA6IGhlaWdodCA8IDU2MCA/ICcxJyA6ICcwJyk7CiAgfQogIC8qIFRoZSBicmFuZCBuYW1lIGdpdmVzIHdheSB3aGVuIHRoZSBjb250cm9scyAod2hpY2ggYXJlIHdpZGVyIGluIHNvbWUgbGFuZ3VhZ2VzKSBsZWF2ZSBpdCBubyByb29tLiAqLwogIGZ1bmN0aW9uIGZpdEJhcigpIHsKICAgIHZhciBiYXIgPSAkKCcuYmFyJyk7CiAgICB2YXIgYnJhbmQgPSAkKCcuYnJhbmQnKTsKICAgIGJhci5jbGFzc0xpc3QucmVtb3ZlKCd0aWdodCcpOwogICAgaWYgKGJyYW5kLnNjcm9sbFdpZHRoID4gYnJhbmQuY2xpZW50V2lkdGggKyAxKSBiYXIuY2xhc3NMaXN0LmFkZCgndGlnaHQnKTsKICB9CiAgaWYgKHdpbmRvdy52aXN1YWxWaWV3cG9ydCkgewogICAgd2luZG93LnZpc3VhbFZpZXdwb3J0LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIGZpdCk7CiAgICB3aW5kb3cudmlzdWFsVmlld3BvcnQuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgZml0KTsKICB9CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIGZ1bmN0aW9uICgpIHsgZml0KCk7IGZpdEJhcigpOyB9KTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignb3JpZW50YXRpb25jaGFuZ2UnLCBmdW5jdGlvbiAoKSB7IGZpdCgpOyBmaXRCYXIoKTsgfSk7CgogIC8qIC0tLS0tLS0tLS0gZWxlbWVudHMgLS0tLS0tLS0tLSAqLwogIHZhciBmb3JtID0gJCgnI2Zvcm0nKTsKICB2YXIgZmllbGQgPSAkKCcuZmllbGQnKTsKICB2YXIgdGV4dEJveCA9ICQoJyN0ZXh0Jyk7CiAgdmFyIGNvdW50RWwgPSAkKCcjY291bnQnKTsKICB2YXIgY2xlYXJCdG4gPSAkKCcjY2xlYXInKTsKICB2YXIgZW50ZXJCb3ggPSAkKCcjZW50ZXInKTsKICB2YXIgc2VuZEJ0biA9ICQoJyNzZW5kJyk7CiAgdmFyIHNlbmRMYWJlbCA9ICQoJyNzZW5kTGFiZWwnKTsKICB2YXIgc3RhdHVzRWwgPSAkKCcjc3RhdHVzJyk7CgogIGZ1bmN0aW9uIHNheSh0ZXh0LCBraW5kLCBtcykgewogICAgY2xlYXJUaW1lb3V0KHNheS50aW1lcik7CiAgICBzdGF0dXNFbC50ZXh0Q29udGVudCA9IHRleHQgfHwgJyc7CiAgICBzdGF0dXNFbC5jbGFzc05hbWUgPSAnc3RhdHVzJyArIChraW5kID8gJyAnICsga2luZCA6ICcnKTsKICAgIGlmICh0ZXh0ICYmIG1zKSBzYXkudGltZXIgPSBzZXRUaW1lb3V0KGZ1bmN0aW9uICgpIHsgc2F5KCcnKTsgfSwgbXMpOwogIH0KICBmdW5jdGlvbiByZXN0YXJ0KGVsLCBjbGFzc05hbWUpIHsKICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoY2xhc3NOYW1lKTsKICAgIHZvaWQgZWwub2Zmc2V0V2lkdGg7IC8qIGZvcmNlIGEgcmVmbG93IHNvIHRoZSBhbmltYXRpb24gY2FuIHJ1biBhZ2FpbiAqLwogICAgZWwuY2xhc3NMaXN0LmFkZChjbGFzc05hbWUpOwogIH0KCiAgLyogLS0tLS0tLS0tLSB0aGUgc3RyaXAgb2YgYmVhZCB0aWxlcyAoYmVhZHMgc3R5bGUpLCBhcyBvbiB0aGUgb3JpZ2luYWwgcGFnZSAtLS0tLS0tLS0tICovCiAgdmFyIHN0cmlwID0gJCgnI2JlYWRzdHJpcCcpOwogIChmdW5jdGlvbiBmaWxsU3RyaXAoKSB7CiAgICB2YXIgdGlsZXMgPSAnJzsKICAgIGZvciAodmFyIGkgPSAwOyBpIDwgNTQ7IGkrKykgdGlsZXMgKz0gJzxpIHN0eWxlPSItLWk6JyArIGkgKyAnIj48L2k+JzsKICAgIHN0cmlwLmlubmVySFRNTCA9IHRpbGVzOwogIH0pKCk7CgogIGZ1bmN0aW9uIHVwZGF0ZUNvdW50KCkgewogICAgdmFyIGxlbmd0aCA9IHRleHRCb3gudmFsdWUubGVuZ3RoOwogICAgdmFyIG5lYXIgPSBsZW5ndGggPiBNQVggKiAwLjk7CiAgICBjb3VudEVsLnRleHRDb250ZW50ID0gbGVuZ3RoID8gKG5lYXIgPyBsZW5ndGggKyAnIC8gJyArIE1BWCA6IFN0cmluZyhsZW5ndGgpKSA6ICcnOwogICAgY291bnRFbC5jbGFzc0xpc3QudG9nZ2xlKCdpcy13YXJuJywgbmVhcik7CiAgICBjbGVhckJ0bi5oaWRkZW4gPSBsZW5ndGggPT09IDA7CiAgfQoKICAvKiAtLS0tLS0tLS0tIHRhbGtpbmcgdG8gdGhlIFBDIC0tLS0tLS0tLS0gKi8KICBmdW5jdGlvbiByZXF1ZXN0KHVybCwgb3B0aW9ucywgdGltZW91dE1zKSB7CiAgICBvcHRpb25zID0gb3B0aW9ucyB8fCB7fTsKICAgIHZhciBjb250cm9sbGVyID0gd2luZG93LkFib3J0Q29udHJvbGxlciA/IG5ldyBBYm9ydENvbnRyb2xsZXIoKSA6IG51bGw7CiAgICB2YXIgdGltZXIgPSAwOwogICAgaWYgKGNvbnRyb2xsZXIpIHsKICAgICAgb3B0aW9ucy5zaWduYWwgPSBjb250cm9sbGVyLnNpZ25hbDsKICAgICAgdGltZXIgPSBzZXRUaW1lb3V0KGZ1bmN0aW9uICgpIHsgY29udHJvbGxlci5hYm9ydCgpOyB9LCB0aW1lb3V0TXMpOwogICAgfQogICAgcmV0dXJuIGZldGNoKHVybCwgb3B0aW9ucykudGhlbigKICAgICAgZnVuY3Rpb24gKHJlc3BvbnNlKSB7IGNsZWFyVGltZW91dCh0aW1lcik7IHJldHVybiByZXNwb25zZTsgfSwKICAgICAgZnVuY3Rpb24gKGVycm9yKSB7IGNsZWFyVGltZW91dCh0aW1lcik7IHRocm93IGVycm9yOyB9CiAgICApOwogIH0KICBmdW5jdGlvbiBhcGlFcnJvcihib2R5LCBzdGF0dXMpIHsKICAgIHZhciBtZXNzYWdlOwogICAgaWYgKGJvZHkgJiYgYm9keS5jb2RlICYmIGhhc0tleSgnZXJyLicgKyBib2R5LmNvZGUpKSBtZXNzYWdlID0gVCgnZXJyLicgKyBib2R5LmNvZGUsIGJvZHkpOwogICAgZWxzZSBpZiAoYm9keSAmJiBib2R5LmVycm9yKSBtZXNzYWdlID0gU3RyaW5nKGJvZHkuZXJyb3IpOwogICAgZWxzZSBtZXNzYWdlID0gVCgnZXJyLmh0dHAnLCB7IHN0YXR1czogc3RhdHVzIH0pOwogICAgdmFyIGVycm9yID0gbmV3IEVycm9yKG1lc3NhZ2UpOwogICAgZXJyb3IuZnJvbVNlcnZlciA9IHRydWU7CiAgICByZXR1cm4gZXJyb3I7CiAgfQoKICB2YXIgY29ubmVjdGlvbiA9ICd1bmtub3duJzsKICB2YXIgZmFpbHVyZXMgPSAwOwogIGZ1bmN0aW9uIHJlbmRlckNvbm5lY3Rpb24oKSB7CiAgICB2YXIgYmFubmVyID0gJCgnI2Nvbm5CYW5uZXInKTsKICAgIGJhbm5lci5oaWRkZW4gPSBjb25uZWN0aW9uICE9PSAnYmFkJzsKICAgIGlmIChjb25uZWN0aW9uID09PSAnYmFkJykgYmFubmVyLnRleHRDb250ZW50ID0gVCgnY29ubi5iYWQnKTsKICAgICQoJyNsb2dvJykuc2V0QXR0cmlidXRlKCdkYXRhLWNvbm4nLCBjb25uZWN0aW9uKTsKICB9CiAgZnVuY3Rpb24gc2V0Q29ubmVjdGlvbihzdGF0ZSkgewogICAgY29ubmVjdGlvbiA9IHN0YXRlOwogICAgZmFpbHVyZXMgPSBzdGF0ZSA9PT0gJ29rJyA/IDAgOiBmYWlsdXJlczsKICAgIHJlbmRlckNvbm5lY3Rpb24oKTsKICB9CiAgYXN5bmMgZnVuY3Rpb24gcGluZygpIHsKICAgIHRyeSB7CiAgICAgIHZhciByZXNwb25zZSA9IGF3YWl0IHJlcXVlc3QoJy9hcGkvaGVhbHRoJywgeyBjYWNoZTogJ25vLXN0b3JlJyB9LCA0MDAwKTsKICAgICAgdmFyIGJvZHkgPSBhd2FpdCByZXNwb25zZS5qc29uKCk7CiAgICAgIGlmICghYm9keSB8fCAhYm9keS5vaykgdGhyb3cgbmV3IEVycm9yKCd1bmhlYWx0aHknKTsKICAgICAgc2V0Q29ubmVjdGlvbignb2snKTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAgIGZhaWx1cmVzICs9IDE7CiAgICAgIGlmIChmYWlsdXJlcyA+PSAyKSBzZXRDb25uZWN0aW9uKCdiYWQnKTsgLyogb25lIGxvc3QgcGFja2V0IGlzIG5vdCBhbiBvdXRhZ2UgKi8KICAgIH0KICB9CgogIHZhciBidXN5ID0gZmFsc2U7CiAgYXN5bmMgZnVuY3Rpb24gc3VibWl0KGV2ZW50KSB7CiAgICBpZiAoZXZlbnQpIGV2ZW50LnByZXZlbnREZWZhdWx0KCk7CiAgICBpZiAoYnVzeSkgcmV0dXJuOwogICAgdmFyIHZhbHVlID0gdGV4dEJveC52YWx1ZTsKICAgIGlmICghdmFsdWUudHJpbSgpKSB7CiAgICAgIHNheShUKCdlcnIuZW1wdHknKSwgJ2Vycm9yJywgMjUwMCk7CiAgICAgIHJlc3RhcnQoZmllbGQsICdzaGFrZScpOwogICAgICByZXR1cm47CiAgICB9CiAgICBlbmREaWN0YXRpb24oKTsKICAgIGJ1c3kgPSB0cnVlOwogICAgY2xlYXJUaW1lb3V0KHN1Ym1pdC5va1RpbWVyKTsKICAgIHNlbmRCdG4uY2xhc3NMaXN0LnJlbW92ZSgnaXMtb2snKTsKICAgIHNlbmRCdG4uZGlzYWJsZWQgPSB0cnVlOwogICAgc2VuZExhYmVsLnRleHRDb250ZW50ID0gVCgnc2VuZGluZycpOwogICAgc2F5KCcnKTsKICAgIHRyeSB7CiAgICAgIHZhciByZXNwb25zZSA9IGF3YWl0IHJlcXVlc3QoJy9hcGkvc2VuZCcsIHsKICAgICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgICBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSwKICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IHRleHQ6IHZhbHVlLCBhcHBlbmRfZW50ZXI6IGVudGVyQm94LmNoZWNrZWQgfSkKICAgICAgfSwgMTUwMDApOwogICAgICB2YXIgYm9keSA9IG51bGw7CiAgICAgIHRyeSB7IGJvZHkgPSBhd2FpdCByZXNwb25zZS5qc29uKCk7IH0gY2F0Y2ggKHBhcnNlRXJyb3IpIHsgLyogbm90IEpTT04gKi8gfQogICAgICBpZiAoIXJlc3BvbnNlLm9rIHx8ICFib2R5IHx8ICFib2R5Lm9rKSB0aHJvdyBhcGlFcnJvcihib2R5LCByZXNwb25zZS5zdGF0dXMpOwogICAgICB0ZXh0Qm94LnZhbHVlID0gJyc7CiAgICAgIHVwZGF0ZUNvdW50KCk7CiAgICAgIGNlbGVicmF0ZShlbnRlckJveC5jaGVja2VkKTsKICAgIH0gY2F0Y2ggKGVycm9yKSB7CiAgICAgIGlmIChlcnJvciAmJiBlcnJvci5mcm9tU2VydmVyKSB7CiAgICAgICAgc2F5KGVycm9yLm1lc3NhZ2UsICdlcnJvcicsIDcwMDApOwogICAgICB9IGVsc2UgewogICAgICAgIHNheShUKCdlcnIubmV0d29yaycpLCAnZXJyb3InLCA5MDAwKTsKICAgICAgICBmYWlsdXJlcyA9IDI7CiAgICAgICAgc2V0Q29ubmVjdGlvbignYmFkJyk7CiAgICAgIH0KICAgIH0gZmluYWxseSB7CiAgICAgIGJ1c3kgPSBmYWxzZTsKICAgICAgc2VuZEJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgICBpZiAoIXNlbmRCdG4uY2xhc3NMaXN0LmNvbnRhaW5zKCdpcy1vaycpKSBzZW5kTGFiZWwudGV4dENvbnRlbnQgPSBUKCdzZW5kJyk7CiAgICB9CiAgfQogIGZ1bmN0aW9uIGNlbGVicmF0ZSh3aXRoRW50ZXIpIHsKICAgIHNheShUKHdpdGhFbnRlciA/ICdzZW50X2VudGVyJyA6ICdzZW50JyksICdvaycsIDI1MDApOwogICAgc2VuZEJ0bi5jbGFzc0xpc3QuYWRkKCdpcy1vaycpOwogICAgc2VuZExhYmVsLnRleHRDb250ZW50ID0gVCgnc2VudCcpOwogICAgc3VibWl0Lm9rVGltZXIgPSBzZXRUaW1lb3V0KGZ1bmN0aW9uICgpIHsKICAgICAgc2VuZEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdpcy1vaycpOwogICAgICBpZiAoIWJ1c3kpIHNlbmRMYWJlbC50ZXh0Q29udGVudCA9IFQoJ3NlbmQnKTsKICAgIH0sIDEzMDApOwogICAgcmVzdGFydChzdHJpcCwgJ3dhdmUnKTsgLyogdGhlIGJlYWRzIHN0eWxlIHBvcHMgaXRzIGJlYWQgdGlsZXMgb25lIGFmdGVyIGFub3RoZXIgKi8KICAgIHNldENvbm5lY3Rpb24oJ29rJyk7CiAgfQoKICAvKiBBZnRlciBTZW5kIHRoZSBwaG9uZSdzIHZvaWNlIGlucHV0IG11c3Qgc3RvcCBpbnN0ZWFkIG9mIGxpc3RlbmluZyBvbiBpbnRvIHRoZSBlbXB0aWVkIGJveCwgYW5kIGl0CiAgICAgc3RhcnRzIGFnYWluIG9ubHkgd2hlbiB0aGUgdXNlciB0YXBzIHRoZSBtaWNyb3Bob25lIChvciB0aGUgYm94KSBhZ2Fpbi4gQSBwYWdlIGNhbm5vdCB0ZWxsIHRoZSBrZXlib2FyZAogICAgIGFwcCB0byBzdG9wLCBidXQgaXQgY2FuIGVuZCB0aGUga2V5Ym9hcmQncyBpbnB1dCBzZXNzaW9uOgogICAgICAga2VlcCAgLSB0aGUgZm9jdXMgd2FpdHMgaW4gYW4gaW52aXNpYmxlIGZpZWxkIGZvciBhIG1vbWVudCBhbmQgY29tZXMgYmFjazogdGhlIGtleWJvYXJkIHN0YXlzIHVwIGFuZAogICAgICAgICAgICAgICBzdGFydHMgYSBuZXcsIGlkbGUgc2Vzc2lvbiAobW9zdCBrZXlib2FyZHMgc3RvcCBkaWN0YXRpbmcgd2hlbiB0aGUgZmllbGQgdGhleSB0eXBlIGludG8gY2hhbmdlcyk7CiAgICAgICBjbG9zZSAtIHRoZSB0ZXh0IGJveCBsZXRzIGdvIGFuZCB0aGUga2V5Ym9hcmQgY2xvc2VzLCB3aGljaCBzdG9wcyBldmVyeSBrZXlib2FyZC4KICAgICBUaGUgcmV0dXJuIGhhcHBlbnMgd2l0aGluIGEgc2Vjb25kIG9mIHRoZSB0YXAsIHNvIGl0IHN0aWxsIGNvdW50cyBhcyB0aGUgdXNlcidzIG93biBhY3Rpb24gYW5kIHRoZQogICAgIHBob25lIGtlZXBzIHRoZSBrZXlib2FyZCBvcGVuLiAqLwogIHZhciBwYXJrID0gJCgnI3BhcmsnKTsKICBmdW5jdGlvbiBlbmREaWN0YXRpb24oKSB7CiAgICBpZiAocHJlZnMuYWZ0ZXIgPT09ICdjbG9zZScpIHsKICAgICAgdGV4dEJveC5ibHVyKCk7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHBhcmsuZm9jdXMoeyBwcmV2ZW50U2Nyb2xsOiB0cnVlIH0pOwogICAgc2V0VGltZW91dChmdW5jdGlvbiAoKSB7CiAgICAgIHBhcmsudmFsdWUgPSAnJzsgLyogd2hhdGV2ZXIgdGhlIGtleWJvYXJkIHN0aWxsIHR5cGVkIGFmdGVyIHRoZSB0YXAgd2FzIG5vdCBwYXJ0IG9mIHRoaXMgbWVzc2FnZSAqLwogICAgICB0ZXh0Qm94LmZvY3VzKHsgcHJldmVudFNjcm9sbDogdHJ1ZSB9KTsKICAgIH0sIDE4MCk7CiAgfQoKICBmb3JtLmFkZEV2ZW50TGlzdGVuZXIoJ3N1Ym1pdCcsIHN1Ym1pdCk7CiAgdGV4dEJveC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsIHVwZGF0ZUNvdW50KTsKICB0ZXh0Qm94LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBmdW5jdGlvbiAoZXZlbnQpIHsKICAgIGlmICgoZXZlbnQuY3RybEtleSB8fCBldmVudC5tZXRhS2V5KSAmJiBldmVudC5rZXkgPT09ICdFbnRlcicpIHN1Ym1pdChldmVudCk7CiAgfSk7CiAgY2xlYXJCdG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBmdW5jdGlvbiAoKSB7CiAgICB0ZXh0Qm94LnZhbHVlID0gJyc7CiAgICB1cGRhdGVDb3VudCgpOwogICAgc2F5KCcnKTsKICAgIHRleHRCb3guZm9jdXMoKTsKICB9KTsKICBlbnRlckJveC5jaGVja2VkID0gc3RvcmUuZ2V0KCdlbnRlcicsICcxJykgPT09ICcxJzsKICBlbnRlckJveC5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCBmdW5jdGlvbiAoKSB7IHN0b3JlLnNldCgnZW50ZXInLCBlbnRlckJveC5jaGVja2VkID8gJzEnIDogJzAnKTsgfSk7CgogIC8qIFRhcHBpbmcgU2VuZCwgQ2xlYXIgb3IgdGhlIEVudGVyIHN3aXRjaCBtdXN0IG5vdCB0YWtlIHRoZSBmb2N1cyBhd2F5IGZyb20gdGhlIHRleHQgYm94OiB0aGUga2V5Ym9hcmQKICAgICBzdGF5cyB3aGVyZSBpdCBpcyAoU2VuZCB0aGVuIGVuZHMgdGhlIGRpY3RhdGlvbiBvbiBpdHMgb3duIHRlcm1zLCBzZWUgZW5kRGljdGF0aW9uKS4gKi8KICBbc2VuZEJ0biwgY2xlYXJCdG4sICQoJy5zd2l0Y2gnKV0uZm9yRWFjaChmdW5jdGlvbiAoZWwpIHsKICAgIGZ1bmN0aW9uIGtlZXBGb2N1cyhldmVudCkgeyBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gdGV4dEJveCkgZXZlbnQucHJldmVudERlZmF1bHQoKTsgfQogICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywga2VlcEZvY3VzKTsKICAgIGVsLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJkb3duJywga2VlcEZvY3VzKTsKICB9KTsKCiAgLyogLS0tLS0tLS0tLSBzZXR0aW5ncyBzaGVldCAtLS0tLS0tLS0tICovCiAgdmFyIHNoZWV0ID0gJCgnI3NoZWV0Jyk7CiAgdmFyIHNjcmltID0gJCgnI3NoZWV0QmFja2Ryb3AnKTsKICB2YXIgb3BlbmVyID0gJCgnI29wZW5TZXR0aW5ncycpOwogIHZhciBoaWRlVGltZXIgPSAwOwogIGZ1bmN0aW9uIG9wZW5TaGVldCgpIHsKICAgIGNsZWFyVGltZW91dChoaWRlVGltZXIpOwogICAgc2NyaW0uaGlkZGVuID0gZmFsc2U7CiAgICBzaGVldC5oaWRkZW4gPSBmYWxzZTsKICAgIHZvaWQgc2hlZXQub2Zmc2V0V2lkdGg7CiAgICBzY3JpbS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICBzaGVldC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAkKCcjc2hlZXRDbG9zZScpLmZvY3VzKCk7CiAgfQogIGZ1bmN0aW9uIGNsb3NlU2hlZXQoKSB7CiAgICBzY3JpbS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICBzaGVldC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgICBoaWRlVGltZXIgPSBzZXRUaW1lb3V0KGZ1bmN0aW9uICgpIHsgc2hlZXQuaGlkZGVuID0gdHJ1ZTsgc2NyaW0uaGlkZGVuID0gdHJ1ZTsgfSwgMjkwKTsKICAgIG9wZW5lci5mb2N1cygpOwogIH0KICBvcGVuZXIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBvcGVuU2hlZXQpOwogICQoJyNzaGVldENsb3NlJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBjbG9zZVNoZWV0KTsKICBzY3JpbS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGNsb3NlU2hlZXQpOwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBmdW5jdGlvbiAoZXZlbnQpIHsKICAgIGlmIChzaGVldC5oaWRkZW4pIHJldHVybjsKICAgIGlmIChldmVudC5rZXkgPT09ICdFc2NhcGUnKSB7IGNsb3NlU2hlZXQoKTsgcmV0dXJuOyB9CiAgICBpZiAoZXZlbnQua2V5ICE9PSAnVGFiJykgcmV0dXJuOwogICAgdmFyIGZvY3VzYWJsZSA9ICRhbGwoJ2J1dHRvbicsIHNoZWV0KTsKICAgIHZhciBmaXJzdCA9IGZvY3VzYWJsZVswXTsKICAgIHZhciBsYXN0ID0gZm9jdXNhYmxlW2ZvY3VzYWJsZS5sZW5ndGggLSAxXTsKICAgIGlmIChldmVudC5zaGlmdEtleSAmJiBkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBmaXJzdCkgeyBldmVudC5wcmV2ZW50RGVmYXVsdCgpOyBsYXN0LmZvY3VzKCk7IH0KICAgIGVsc2UgaWYgKCFldmVudC5zaGlmdEtleSAmJiBkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBsYXN0KSB7IGV2ZW50LnByZXZlbnREZWZhdWx0KCk7IGZpcnN0LmZvY3VzKCk7IH0KICB9KTsKCiAgLyogLS0tLS0tLS0tLSBzdGFydCAtLS0tLS0tLS0tICovCiAgbGFuZyA9IHBpY2tMYW5nKCk7CiAgYnVpbGRMYW5ndWFnZUNob2ljZXMoKTsKICB0cmFuc2xhdGUoKTsKICBhcHBseUFwcGVhcmFuY2UoKTsKICBmaXQoKTsKICBmaXRCYXIoKTsKICBpZiAoZG9jdW1lbnQuZm9udHMgJiYgZG9jdW1lbnQuZm9udHMucmVhZHkpIGRvY3VtZW50LmZvbnRzLnJlYWR5LnRoZW4oZml0QmFyKTsKICB1cGRhdGVDb3VudCgpOwogICQoJyNkZW1vQmFubmVyJykuaGlkZGVuID0gIUNGRy5kZW1vOwogICQoJyNhYm91dCcpLnRleHRDb250ZW50ID0gJ1ZvaWNlQmVhbSAnICsgKENGRy52ZXJzaW9uIHx8ICcnKTsKICBwaW5nKCk7CiAgc2V0SW50ZXJ2YWwoZnVuY3Rpb24gKCkgeyBpZiAoZG9jdW1lbnQudmlzaWJpbGl0eVN0YXRlID09PSAndmlzaWJsZScpIHBpbmcoKTsgfSwgMTUwMDApOwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2UnLCBmdW5jdGlvbiAoKSB7IGlmIChkb2N1bWVudC52aXNpYmlsaXR5U3RhdGUgPT09ICd2aXNpYmxlJykgeyBmaXQoKTsgcGluZygpOyB9IH0pOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdvbmxpbmUnLCBwaW5nKTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignb2ZmbGluZScsIGZ1bmN0aW9uICgpIHsgZmFpbHVyZXMgPSAyOyBzZXRDb25uZWN0aW9uKCdiYWQnKTsgfSk7Cn0pKCk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K'))
$PageBytes = [System.Text.Encoding]::UTF8.GetBytes($PageHtml)
$Version = '0.1.0'
# Browsers send UTF-8, other clients may escape every character as \uXXXX (12 bytes for one emoji).
$MaxBody = $MaxLen * 12 + 256

$listener = $null
for ($p = $Port; $p -lt $Port + 10; $p++) {
    try {
        $candidate = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $p)
        $candidate.Start()
        $listener = $candidate
        $Port = $p
        break
    } catch {
        $listener = $null
    }
}
if (-not $listener) {
    Write-Host ("Could not bind any port in range {0}-{1}. Is another VoiceBeam already running?" -f $Port, ($Port + 9))
    exit 1
}

$ip = Get-LocalIP
$phoneUrl = "http://{0}:{1}/" -f $ip, $Port
Write-Host ''
Write-Host ('VoiceBeam {0}' -f $Version)
if ($Port -ne 8123) {
    Write-Host '(port 8123 was busy - is another VoiceBeam already running? - fell back to the port below)'
}
Show-PhoneQrCode $phoneUrl
Write-Host ("Phone URL: " + $phoneUrl)
Write-Host 'Put the phone and this computer on the same Wi-Fi. Press Ctrl+C to stop.'
Write-Host ''

try {
    while ($true) {
        # Poll instead of blocking in AcceptTcpClient(), so Ctrl+C is honoured at once.
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()

            $head = Read-RequestHead -Stream $stream
            if ([string]::IsNullOrEmpty($head)) { continue }
            $headLines = $head -split "`r`n"
            $reqParts = $headLines[0] -split ' '
            $method = $reqParts[0]
            $path = ''
            if ($reqParts.Length -gt 1) { $path = $reqParts[1] }
            $query = $path.IndexOf('?')
            if ($query -ge 0) { $path = $path.Substring(0, $query) }
            $headers = Get-HeaderTable -HeadLines $headLines

            if ($method -eq 'GET' -and $path -eq '/') {
                Write-RawResponse -Stream $stream -Status 200 -StatusText 'OK' -ContentType 'text/html; charset=utf-8' -Body $PageBytes
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/health') {
                Send-JsonResponse -Stream $stream -Status 200 -StatusText 'OK' -Obj @{ ok = $true; service = 'voicebeam'; version = $Version; demo = $false }
            }
            elseif ($method -eq 'GET' -and $path -eq '/favicon.ico') {
                Write-RawResponse -Stream $stream -Status 204 -StatusText 'No Content' -ContentType 'image/x-icon' -Body ([byte[]]@())
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/send') {
                Invoke-SendRequest -Stream $stream -Headers $headers
            }
            else {
                Send-ApiError $stream 404 'Not Found' 'not_found' 'not found'
            }
        } catch {
            Write-Host ('request error: ' + $_.Exception.Message)
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    Write-Host 'Stopped.'
}
