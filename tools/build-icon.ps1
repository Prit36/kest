# Rebuild PNG/ICO and the native glyph from the same simple SVG polygons.
# Requires only Windows PowerShell and System.Drawing. No image downloads.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $project 'assets/kest.svg'
[xml]$svg = Get-Content -LiteralPath $source -Raw
$ns = New-Object Xml.XmlNamespaceManager($svg.NameTable)
$ns.AddNamespace('s', 'http://www.w3.org/2000/svg')
$shapes = @($svg.SelectNodes('/s:svg/s:g/s:polygon', $ns))
$background = $svg.SelectSingleNode('/s:svg/s:rect', $ns)
$ink = $svg.SelectSingleNode('/s:svg/s:g', $ns).GetAttribute('fill')
$culture = [Globalization.CultureInfo]::InvariantCulture
$zig = [Collections.Generic.List[string]]::new()
$zig.Add('//! Generated from assets/kest.svg by tools/build-icon.ps1.')
$zig.Add('pub const polygons = [_][4][2]f32{')
foreach ($shape in $shapes) {
    $coords = @($shape.GetAttribute('points').Split(' ') | Where-Object { $_ })
    if ($coords.Count -ne 4) { throw 'The native mark requires convex quadrilaterals.' }
    $points = foreach ($pair in $coords) {
        $xy = $pair.Split(',')
        '.{ ' + $xy[0] + ', ' + $xy[1] + ' }'
    }
    $zig.Add('    .{ ' + ($points -join ', ') + ' },')
}
$zig.Add('};')
[IO.File]::WriteAllText((Join-Path $project 'src/ui/brand_geometry.zig'), ($zig -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

$images = [Collections.Generic.List[byte[]]]::new()
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
foreach ($size in $sizes) {
    # Supersample small icons so diagonals remain clean at taskbar sizes.
    $factor = 4
    $large = [Drawing.Bitmap]::new($size * $factor, $size * $factor)
    $g = [Drawing.Graphics]::FromImage($large)
    try {
        $g.Clear([Drawing.Color]::Transparent)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.ScaleTransform($size * $factor / 32.0, $size * $factor / 32.0)
        $bg = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($background.GetAttribute('fill')))
        $fg = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($ink))
        $path = [Drawing.Drawing2D.GraphicsPath]::new()
        try {
            $path.AddArc(0, 0, 14, 14, 180, 90)
            $path.AddArc(18, 0, 14, 14, 270, 90)
            $path.AddArc(18, 18, 14, 14, 0, 90)
            $path.AddArc(0, 18, 14, 14, 90, 90)
            $path.CloseFigure()
            $g.FillPath($bg, $path)
            foreach ($shape in $shapes) {
                $points = [Drawing.PointF[]]@($shape.GetAttribute('points').Split(' ') | Where-Object { $_ } | ForEach-Object {
                    $xy = $_.Split(',')
                    [Drawing.PointF]::new([single]::Parse($xy[0], $culture), [single]::Parse($xy[1], $culture))
                })
                $g.FillPolygon($fg, $points)
            }
        } finally { $path.Dispose(); $fg.Dispose(); $bg.Dispose() }
    } finally { $g.Dispose() }
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $small = [Drawing.Graphics]::FromImage($bitmap)
    $stream = [IO.MemoryStream]::new()
    try {
        $small.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $small.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $small.DrawImage($large, [Drawing.Rectangle]::new(0, 0, $size, $size))
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $stream.ToArray()
        $images.Add($bytes)
        if ($size -eq 256) { [IO.File]::WriteAllBytes((Join-Path $project 'assets/kest.png'), $bytes) }
    } finally { $stream.Dispose(); $small.Dispose(); $bitmap.Dispose(); $large.Dispose() }
}
$file = [IO.File]::Create((Join-Path $project 'assets/kest.ico'))
$writer = [IO.BinaryWriter]::new($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($bytes in $images) { $writer.Write($bytes) }
} finally { $writer.Dispose() }
Write-Output 'Generated assets/kest.png, assets/kest.ico and src/ui/brand_geometry.zig'
