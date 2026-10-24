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
$PageHtml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('@@PAGE_BASE64@@'))
$PageBytes = [System.Text.Encoding]::UTF8.GetBytes($PageHtml)
$Version = '@@VERSION@@'
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
