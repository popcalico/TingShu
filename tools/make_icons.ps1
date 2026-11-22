Add-Type -AssemblyName System.Drawing

function New-RoundedRect {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc([float]$X, [float]$Y, [float]$d, [float]$d, 180, 90)
    $p.AddArc([float]($X + $W - $d), [float]$Y, [float]$d, [float]$d, 270, 90)
    $p.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d, 0, 90)
    $p.AddArc([float]$X, [float]($Y + $H - $d), [float]$d, [float]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Icon {
    param([int]$Size, [string]$Path, [double]$Content = 0.72, [bool]$Rounded = $true)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    if ($Rounded) {
        $r = [double]$Size * 0.23
        $bgPath = New-RoundedRect 0 0 $Size $Size $r
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(217, 119, 6))
        $g.FillPath($bgBrush, $bgPath)
        $bgBrush.Dispose()
        $bgPath.Dispose()
    } else {
        # 自适应图标的前景层必须是透明底，底色由 background 层负责
        $g.Clear([System.Drawing.Color]::Transparent)
    }

    $cw = [double]$Size * $Content
    $cx = [double]$Size / 2
    $cy = [double]$Size / 2
    $left = $cx - $cw / 2
    $top = $cy - $cw / 2

    function P([double]$nx, [double]$ny) {
        return New-Object System.Drawing.PointF([float]($left + $nx * $cw), [float]($top + $ny * $cw))
    }

    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $pts = @(
        (P 0.06 0.36), (P 0.24 0.36), (P 0.48 0.14),
        (P 0.48 0.86), (P 0.24 0.64), (P 0.06 0.64)
    )
    $g.FillPolygon($white, [System.Drawing.PointF[]]$pts)

    $penW = [float]($cw * 0.075)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $penW)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    $arcCx = $left + 0.46 * $cw
    $arcCy = $top + 0.50 * $cw
    foreach ($rad in @(0.17, 0.32)) {
        $rr = $rad * $cw
        $ap = New-Object System.Drawing.Drawing2D.GraphicsPath
        $ap.AddArc(
            [float]($arcCx - $rr), [float]($arcCy - $rr),
            [float]($rr * 2), [float]($rr * 2),
            -55, 110
        )
        $g.DrawPath($pen, $ap)
        $ap.Dispose()
    }

    $pen.Dispose()
    $white.Dispose()
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$res = "E:\pingshu\android\app\src\main\res"

$legacy = @{ "mipmap-mdpi" = 48; "mipmap-hdpi" = 72; "mipmap-xhdpi" = 96; "mipmap-xxhdpi" = 144; "mipmap-xxxhdpi" = 192 }
foreach ($k in $legacy.Keys) {
    New-Icon -Size $legacy[$k] -Path "$res\$k\ic_launcher.png" -Content 0.74 -Rounded $true
}

$fg = @{ "mipmap-mdpi" = 108; "mipmap-hdpi" = 162; "mipmap-xhdpi" = 216; "mipmap-xxhdpi" = 324; "mipmap-xxxhdpi" = 432 }
foreach ($k in $fg.Keys) {
    New-Icon -Size $fg[$k] -Path "$res\$k\ic_launcher_foreground.png" -Content 0.46 -Rounded $false
}

New-Icon -Size 512 -Path "E:\pingshu\assets\logo.png" -Content 0.72 -Rounded $true

Write-Output "icons generated"
Get-ChildItem "$res\mipmap-xxxhdpi\ic_launcher*.png" | Select-Object Name, Length
