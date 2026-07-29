# Generates the 1200x630 Open Graph card for claude-statusline-tokens.
# Re-run after changing the sample status line so the card stays truthful.
Add-Type -AssemblyName System.Drawing

$W = 1200; $H = 630
$out = "C:\Users\Gabriel-Dalton\Documents\GitHub\claude-statusline-tokens\docs\img\og-card.png"

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'ClearTypeGridFit'
$g.InterpolationMode = 'HighQualityBicubic'

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Brush([string]$hex) { New-Object System.Drawing.SolidBrush((C $hex)) }

# --- background -----------------------------------------------------------
$g.FillRectangle((Brush '#0a0a0a'), 0, 0, $W, $H)

# warm glow behind the headline, so the card isn't a flat black rectangle
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(-260, -320, 1100, 720)
$gb = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
$gb.CenterColor = [System.Drawing.Color]::FromArgb(38, 234, 88, 12)
$gb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 10, 10, 10))
$g.FillPath($gb, $glow)

# top accent rule
$g.FillRectangle((Brush '#ea580c'), 0, 0, $W, 6)

# --- wordmark -------------------------------------------------------------
$fMonoBold = New-Object System.Drawing.Font('Consolas', 30, [System.Drawing.FontStyle]::Bold)
$g.DrawString('>', $fMonoBold, (Brush '#f59e0b'), 74, 74)
$g.DrawString('statusline-tokens', $fMonoBold, (Brush '#e5e5e5'), 105, 74)

# --- headline -------------------------------------------------------------
$fH1 = New-Object System.Drawing.Font('Segoe UI Semibold', 47, [System.Drawing.FontStyle]::Bold)
$g.DrawString('Every Claude Code session,', $fH1, (Brush '#ffffff'), 70, 150)
$g.DrawString('priced in real time.', $fH1, (Brush '#fdba74'), 70, 215)

# --- subhead --------------------------------------------------------------
$fSub = New-Object System.Drawing.Font('Segoe UI', 21)
$g.DrawString('Token totals, API-rate cost and reset countdowns on the 5h + 7d limits.',
    $fSub, (Brush '#a3a3a3'), 74, 296)

# --- terminal strip -------------------------------------------------------
$stripY = 366; $stripH = 128
$g.FillRectangle((Brush '#111111'), 70, $stripY, $W - 140, $stripH)
$pen = New-Object System.Drawing.Pen((C '#2a2a2a'), 1)
$g.DrawRectangle($pen, 70, $stripY, $W - 140, $stripH)

# window dots
$dots = @('#ef4444', '#eab308', '#22c55e')
for ($i = 0; $i -lt 3; $i++) {
    $g.FillEllipse((Brush $dots[$i]), (96 + $i * 22), ($stripY + 24), 11, 11)
}
$fTiny = New-Object System.Drawing.Font('Consolas', 12)
$g.DrawString('claude-code  powershell', $fTiny, (Brush '#525252'), 178, ($stripY + 22))

# the status line itself, segment by segment, in its real colors.
# GenericTypographic measures without the padding DrawString adds, which is
# what lets consecutive segments sit flush the way a real terminal renders.
$fmt = [System.Drawing.StringFormat]::GenericTypographic
# `gap` is an explicit pen advance in ems, applied after the segment is drawn.
# Padding the strings themselves doesn't work: GenericTypographic trims
# trailing whitespace out of both the draw AND the measurement, which is what
# collapsed the line into "5h82%" and "|main|Opus 5".
$segs = @(
    @{ t = 'my-project'; c = '#fdba74'; gap = 0.55 }
    @{ t = '|';         c = '#525252'; gap = 0.55 }
    @{ t = 'main';      c = '#d6c193'; gap = 0.55 }
    @{ t = '|';         c = '#525252'; gap = 0.55 }
    @{ t = 'Opus 5';    c = '#c4b5fd'; gap = 0.55 }
    @{ t = '|';         c = '#525252'; gap = 0.55 }
    @{ t = '5h';        c = '#67e8f9'; gap = 0.45 }
    @{ t = '82%';       c = '#f87171'; gap = 0.6 }
    @{ t = '(103.8M tok, $100, resets 47m @ 1:50pm)'; c = '#67e8f9'; gap = 0.55 }
    @{ t = '|';         c = '#525252'; gap = 0.55 }
    @{ t = '7d';        c = '#86efac'; gap = 0.45 }
    @{ t = '25%';       c = '#4ade80'; gap = 0.6 }
    @{ t = '(149.7M tok, $152)'; c = '#86efac'; gap = 0 }
)

# Auto-fit: shrink until the whole line clears the strip's inner width, so a
# longer sample can never silently run off the right edge again.
$padX = 26
$avail = ($W - 140) - ($padX * 2)
$size = 17.0
do {
    $fMono = New-Object System.Drawing.Font('Consolas', $size)
    $em = $g.MeasureString('M', $fMono, [int]::MaxValue, $fmt).Width
    $total = 0.0
    foreach ($s in $segs) {
        $total += $g.MeasureString($s.t, $fMono, [int]::MaxValue, $fmt).Width + ($s.gap * $em)
    }
    if ($total -le $avail) { break }
    $fMono.Dispose()
    $size -= 0.5
} while ($size -gt 8)

# Center the finished line in the strip rather than left-pinning it.
$x = 70.0 + (($W - 140) - $total) / 2.0
$y = $stripY + 70
foreach ($s in $segs) {
    $g.DrawString($s.t, $fMono, (Brush $s.c), $x, $y, $fmt)
    $x += $g.MeasureString($s.t, $fMono, [int]::MaxValue, $fmt).Width + ($s.gap * $em)
}

# --- footer ---------------------------------------------------------------
$fFoot = New-Object System.Drawing.Font('Consolas', 15)
$g.DrawString('github.com/Gabriel-Dalton/claude-statusline-tokens', $fFoot, (Brush '#737373'), 74, 552)
# Right-align via a layout rectangle. Measuring the string and subtracting is
# fragile once the text contains a middle dot - the measured width came back
# wider than the card and pushed the badge off the left edge.
$fFootR = New-Object System.Drawing.Font('Segoe UI', 15)
$fmtRight = New-Object System.Drawing.StringFormat
$fmtRight.Alignment = [System.Drawing.StringAlignment]::Far
$fmtRight.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
$footRect = New-Object System.Drawing.RectangleF(600, 552, ($W - 74 - 600), 28)
# Middle dot built at runtime: PS 5.1 reads a .ps1 without a BOM using the
# system ANSI codepage, so a literal U+00B7 in the source renders as mojibake.
$dot = [string][char]0x00B7
$g.DrawString("MIT  $dot  PowerShell  $dot  no dependencies", $fFootR, (Brush '#525252'), $footRect, $fmtRight)

$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "wrote $out"
