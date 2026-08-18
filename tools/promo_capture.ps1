# Promo footage capture: runs one real battle and writes a lossless PNG frame
# sequence, then (unless -NoEncode) hands it to tools/promo_encode.ps1.
#
#   .\tools\promo_capture.ps1                                  # default matchup
#   .\tools\promo_capture.ps1 -Lineup all_races -Seconds 45
#   .\tools\promo_capture.ps1 -Lineup undead_vs_human -Landscape
#   .\tools\promo_capture.ps1 -Smoke                           # fast, low-res check
#
# Movie Maker needs a real rendering context, so --headless is not an option and
# a window will flash up while this runs. Same Godot limitation the VFX capture
# harness lives with.
#
# Disk: a 1080x1920 PNG runs 1-3 MB. At 60fps a 30 second battle is ~2000 frames,
# so budget several GB per take. The raw frames are deleted by promo_encode.ps1
# unless you pass -KeepFrames.

param(
    # battle = a full 3v3 fight; prep = the board/shop screen; menu = main menu.
    # Only battle ends on its own - the other two run for -Seconds.
    [ValidateSet("battle", "prep", "menu")]
    [string]$Scene = "battle",
    [string]$Lineup = "dark_vs_god",
    [int]$Round = 18,
    [int]$Seed = 20260807,
    [int]$Fps = 60,
    [int]$Mercs = 0,
    # Promo footage targets the international platforms, so English by default.
    [string]$Locale = "en",
    # Vertical reframing, see promo_capture.gd. Defaults are the values measured
    # to work for 9:16: the stock 16:9 camera leaves the fight in the top 60% of
    # a vertical frame, these put it at 19-70% and centre it. Landscape needs no
    # correction, so the defaults are zeroed for -Landscape below.
    [double]$CameraSize = 6.2,
    [double]$PanX = 0,
    [double]$PanZ = -1.0,
    # Safety ceiling only - the capture quits itself when the battle ends.
    [int]$Seconds = 120,
    # "game" (engine BGM/SFX), "none" (silent), or a path to an audio file.
    # See promo_encode.ps1 for why "none" is often the right pick.
    [string]$Audio = "game",
    [double]$AudioStart = 0,
    [switch]$Landscape,
    [switch]$Smoke,
    [switch]$NoEncode,
    [switch]$KeepFrames,
    [string]$Root = "C:\Users\Leno\Desktop\promote",
    [string]$Godot = "C:\Users\Leno\Desktop\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Godot)) {
    throw "Godot not found at $Godot - pass -Godot <path>"
}

# A quick shape check: quarter resolution, 30fps, 20s ceiling. Enough to confirm
# framing and that the matchup actually fights, without burning gigabytes.
if ($Smoke) {
    $Fps = 30
    $Seconds = 20
}

# Movie Maker records the root viewport, whose size comes from the project's
# display/window/size settings - NOT from --resolution, which only asks for a
# window size and leaves the recording at the project's 1600x720. The only way
# to record vertical is to override those settings, and override.cfg does it
# without touching the tracked project.godot.
if ($Landscape) {
    $movieW, $movieH = 1920, 1080
    # 16:9 is what the game's own camera constants were tuned against.
    if (-not $PSBoundParameters.ContainsKey('CameraSize')) { $CameraSize = 0 }
    if (-not $PSBoundParameters.ContainsKey('PanZ')) { $PanZ = 0 }
} else {
    $movieW, $movieH = 1080, 1920
}
if ($Smoke) {
    if ($Landscape) { $movieW, $movieH = 960, 540 } else { $movieW, $movieH = 540, 960 }
}

$orientation = if ($Landscape) { "landscape" } else { "vertical" }
$takeName = if ($Scene -eq "battle") {
    "{0}_r{1}_{2}" -f $Lineup, $Round, $orientation
} else {
    "{0}_{1}_{2}" -f $Scene, $Lineup, $orientation
}
if ($Smoke) { $takeName = "smoke_$takeName" }

# prep and menu run to the ceiling rather than ending themselves, so the ceiling
# is the actual clip length. 120s of main menu is not useful footage.
if ($Scene -ne "battle" -and -not $PSBoundParameters.ContainsKey('Seconds')) {
    $Seconds = 15
}

$framesDir = Join-Path $Root "raw\$takeName"
foreach ($dir in @($Root, (Join-Path $Root "raw"), (Join-Path $Root "clips"), (Join-Path $Root "posters"))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
# A frame sequence has to start from a clean directory or the previous take's
# leftover frames get encoded into this one.
if (Test-Path $framesDir) { Remove-Item -Recurse -Force $framesDir }
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

$userArgs = @(
    "--out", $framesDir,
    "--lineup", $Lineup,
    "--round", $Round,
    "--seed", $Seed,
    "--fps", $Fps,
    "--mercs", $Mercs,
    "--locale", $Locale,
    "--camera-size", $CameraSize,
    "--pan-x", $PanX,
    "--pan-z", $PanZ,
    "--scene", $Scene
)

$godotArgs = @(
    "--path", $project,
    "--script", "tools/promo_capture.gd",
    "--write-movie", (Join-Path $framesDir "frame.png"),
    "--fixed-fps", $Fps,
    # The window is only there because Movie Maker needs a render context; keep
    # it at half size so a 1080x1920 capture does not open a window taller than
    # the screen. The ASPECT still has to match the recording: the project
    # stretches with aspect="expand", so a window of a different shape makes the
    # root viewport grow to fit it and the recording comes out the wrong size.
    "--resolution", "$([int]($movieW / 2))x$([int]($movieH / 2))",
    "--quit-after", ($Seconds * $Fps),
    "--"
) + $userArgs

$overridePath = Join-Path $project "override.cfg"
$overrideBackup = "$overridePath.promo_backup"
if (Test-Path $overridePath) { Move-Item $overridePath $overrideBackup -Force }

Write-Host "capturing '$takeName' at ${movieW}x${movieH} / ${Fps}fps ($Locale) -> $framesDir"
try {
    # Must be written before Godot starts: project settings are read once at boot.
    #
    # ascii, not utf8: PowerShell 5.1 writes utf8 WITH a BOM, and Godot's config
    # parser does not strip it - the BOM lands inside the first section header,
    # the whole file silently fails to apply, and the capture comes out at the
    # project's default 1600x720 with no error anywhere. (The stray
    # "config_version" key in project.godot is the same bug, already committed.)
    $overrideText = "[display]`nwindow/size/viewport_width=$movieW`nwindow/size/viewport_height=$movieH`n"
    Set-Content -Path $overridePath -Value $overrideText -Encoding ascii -NoNewline
    & $Godot @godotArgs
    $godotExit = $LASTEXITCODE
} finally {
    # Always remove it. Left behind, it would silently change the resolution of
    # every normal run of the game from the editor or the console binary.
    Remove-Item $overridePath -Force -ErrorAction SilentlyContinue
    if (Test-Path $overrideBackup) { Move-Item $overrideBackup $overridePath -Force }
}
if ($godotExit -ne 0) { throw "godot exited with $godotExit" }

$frames = @(Get-ChildItem -Path $framesDir -Filter "frame*.png" -ErrorAction SilentlyContinue | Sort-Object Name)
Write-Host "captured $($frames.Count) frames"
if ($frames.Count -eq 0) {
    throw "no frames written - check that --headless was not in play and the movie writer had a render context"
}

# Verify the frames really came out at the requested size. Every way this has
# failed so far - a BOM in override.cfg, a window whose aspect does not match -
# fails SILENTLY, producing a landscape capture that looks fine until it is
# already encoded. Read the size straight out of the PNG header: width and
# height are big-endian int32 at offsets 16 and 20.
$header = [byte[]](Get-Content $frames[0].FullName -Encoding Byte -TotalCount 24)
$actualW = [int]$header[16] * 16777216 + [int]$header[17] * 65536 + [int]$header[18] * 256 + [int]$header[19]
$actualH = [int]$header[20] * 16777216 + [int]$header[21] * 65536 + [int]$header[22] * 256 + [int]$header[23]
if ($actualW -ne $movieW -or $actualH -ne $movieH) {
    throw "captured ${actualW}x${actualH} but asked for ${movieW}x${movieH} - override.cfg did not apply. Frames left in $framesDir"
}
Write-Host "verified frame size ${actualW}x${actualH}"

if ($NoEncode) {
    Write-Host "skipping encode (-NoEncode); frames left in $framesDir"
    return
}

$encodeArgs = @{ TakeName = $takeName; Root = $Root; Fps = $Fps; Audio = $Audio; AudioStart = $AudioStart }
if ($KeepFrames) { $encodeArgs["KeepFrames"] = $true }

& (Join-Path $PSScriptRoot "promo_encode.ps1") @encodeArgs
