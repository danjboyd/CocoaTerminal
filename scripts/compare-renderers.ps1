# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Daniel Boyd
#
# Windows: runs demo scenarios with each renderer and puts 1:1 crops of their screenshots side by side in one PNG per
# scenario, for judging sharpness by eye (zoomed screenshots lie about subpixel rendering; look at these at 100%).
#
#   powershell -ExecutionPolicy Bypass -File scripts\compare-renderers.ps1 [-Build build-win] [-Out compare]
#       [-Scenarios "unicode-width ansi-colors line-drawing-inverse"] [-Width 640] [-Height 260]
#
# Needs MSYS2 (C:\msys64) for the scenario runner. The OpenGL rows need OpenGL 3.3: a GPU driver, or Mesa's
# opengl32.dll beside the demo with GALLIUM_DRIVER=llvmpipe.

param(
  [string]$Build = "build-win",
  [string]$Out = "compare",
  [string]$Scenarios = "unicode-width ansi-colors line-drawing-inverse vim",
  [int]$Width = 640,
  [int]$Height = 260
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$bash = "C:\msys64\usr\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "MSYS2 not found at $bash" }
$outDir = Join-Path $repo $Out
New-Item -ItemType Directory -Force $outDir | Out-Null

# Renderer, label, and the environment it runs with.
$renderers = @(
  @{ Name = "cairo";        Label = "Cairo (current)";          Env = @{ COCOATERMINAL_RENDERER = "" } },
  @{ Name = "gl-cleartype"; Label = "OpenGL, DirectWrite ClearType"; Env = @{ COCOATERMINAL_RENDERER = "gl"; COCOATERMINAL_GL_ANTIALIAS = "" } },
  @{ Name = "gl-grayscale"; Label = "OpenGL, DirectWrite grayscale"; Env = @{ COCOATERMINAL_RENDERER = "gl"; COCOATERMINAL_GL_ANTIALIAS = "grayscale" } },
  @{ Name = "gl-freetype";  Label = "OpenGL, FreeType LCD";      Env = @{ COCOATERMINAL_RENDERER = "gl"; COCOATERMINAL_GL_GLYPHS = "freetype" } }
)

$posixRepo = & $bash -lc "cygpath -u '$repo'"
foreach ($r in $renderers) {
  $dir = Join-Path $outDir $r.Name
  New-Item -ItemType Directory -Force $dir | Out-Null
  $exports = ($r.Env.GetEnumerator() | ForEach-Object { "export $($_.Key)='$($_.Value)'" }) -join "; "
  foreach ($s in $Scenarios.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
    # A folder per scenario: the runner empties its folder when it starts.
    $posixDir = & $bash -lc "cygpath -u '$(Join-Path $dir $s)'"
    # The Windows home variables: GNUstep can't find the home folder without them and crashes at launch.
    $cmd = "export PATH=/clang64/bin:/usr/bin:`$PATH USERPROFILE='$env:USERPROFILE' HOMEDRIVE='$env:HOMEDRIVE' " +
           "HOMEPATH='$env:HOMEPATH' COCOATERMINAL_BUILD_DIR='$posixRepo/$Build' COCOATERMINAL_SKIP_BUILD=1 " +
           "COCOATERMINAL_SCENARIOS=$s COCOATERMINAL_SCENARIO_DIR='$posixDir'; $exports; " +
           "sh '$posixRepo/scripts/test-demo-scenarios.sh' >/dev/null 2>&1"
    & $bash -lc $cmd
    $shot = Join-Path (Join-Path $dir $s) "$s.png"
    Write-Host ("{0,-14} {1,-22} {2}" -f $r.Name, $s, $(if (Test-Path $shot) { "ok" } else { "no screenshot" }))
  }
}

Add-Type -AssemblyName System.Drawing
$font = New-Object System.Drawing.Font("Segoe UI", 10)
foreach ($s in $Scenarios.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
  $label = 22
  $sheet = New-Object System.Drawing.Bitmap ($Width * 2 + 10), (($Height + $label) * 2 + 10)
  $g = [System.Drawing.Graphics]::FromImage($sheet)
  $g.Clear([System.Drawing.Color]::White)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  for ($i = 0; $i -lt $renderers.Count; $i++) {
    $x = ($i % 2) * ($Width + 10)
    $y = [Math]::Floor($i / 2) * ($Height + $label + 10)
    $g.DrawString($renderers[$i].Label, $font, [System.Drawing.Brushes]::Black, $x + 2, $y + 2)
    $png = Join-Path (Join-Path (Join-Path $outDir $renderers[$i].Name) $s) "$s.png"
    if (Test-Path $png) {
      $img = [System.Drawing.Image]::FromFile($png)
      $w = [Math]::Min($Width, $img.Width); $h = [Math]::Min($Height, $img.Height)
      $g.DrawImage($img, (New-Object System.Drawing.Rectangle $x, ($y + $label), $w, $h),
                   (New-Object System.Drawing.Rectangle 0, 0, $w, $h), [System.Drawing.GraphicsUnit]::Pixel)
      $img.Dispose()
    }
  }
  $target = Join-Path $outDir "$s.png"
  $sheet.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "wrote $target"
}
