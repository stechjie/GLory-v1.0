# Steam fest promo shots: runs tools/fest_capture.gd under Movie Maker, then
# encodes the PNG frames into a GIF (store page / announcements) and an MP4.
#
#   .\tools\fest_capture.ps1 -Shot cards
#   .\tools\fest_capture.ps1 -Shot fourstar
#   .\tools\fest_capture.ps1 -Shot treasure
#   .\tools\fest_capture.ps1 -Shot battle     # final-round 3v3 (tools/fest_battle.gd), MJPEG
#   .\tools\fest_capture.ps1 -Shot cards -Crop "760:820:580:20" -NoCapture   # re-encode only
#
# Same Movie Maker constraints as promo_capture.ps1 (window flashes up, no
# --headless, resolution via an ASCII override.cfg that is always removed).

param(
    [ValidateSet("cards", "fourstar", "treasure", "battle")]
    [string]$Shot = "cards",
    [int]$Fps = 30,
    [string]$Locale = "en",
    # The game's own 20:9 layout (1600x720) scaled up, so nothing is re-laid out.
    [int]$Width = 1920,
    [int]$Height = 864,
    # ffmpeg crop "w:h:x:y" in capture pixels; empty = full frame.
    [string]$Crop = "",
    [string]$Segments = "",
    [int]$GifWidth = 616,
    [int]$GifFps = 15,
    [switch]$NoCapture,
    [string]$Root = "C:\Users\Leno\Desktop\promote\fest",
    [string]$Godot = "C:\Users\Leno\Desktop\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
$framesDir = Join-Path $Root "raw\$Shot"
$outDir = Join-Path $Root "out"
New-Item -ItemType Directory -Force -Path $framesDir, $outDir | Out-Null

# The battle is a real 3v3 replay played by BattleScreen (tools/fest_battle.gd on
# top of promo_capture.gd). Two differences from the prep shots:
#   - 16:9, because BattleArena's camera is tuned against 16:9;
#   - MJPEG .avi instead of PNG: PNG costs ~0.5 s/frame and the battle's render
#     warm-up has a 90 s wall-clock limit (BattleRenderWarmup.MAX_TOTAL_MSEC) -
#     at PNG speed the fight gets skipped as render_warmup_timeout.
$isBattle = $Shot -eq "battle"
if ($isBattle) {
    if (-not $PSBoundParameters.ContainsKey('Height')) { $Height = 1080 }
}

if (-not $NoCapture) {
    if (-not (Test-Path $Godot)) { throw "Godot not found at $Godot" }
    Remove-Item -Recurse -Force $framesDir
    New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
    $movie = if ($isBattle) { Join-Path $framesDir "take.avi" } else { Join-Path $framesDir "frame.png" }
    $script = if ($isBattle) { "tools/fest_battle.gd" } else { "tools/fest_capture.gd" }
    $userArgs = if ($isBattle) {
        @("--out", $framesDir, "--fps", $Fps, "--locale", $Locale, "--scene", "battle", "--star", 3)
    } else {
        @("--out", $framesDir, "--shot", $Shot, "--fps", $Fps, "--locale", $Locale)
    }
    $quitSec = if ($isBattle) { 150 } else { 60 }
    $godotArgs = @(
        "--path", $project,
        "--script", $script,
        "--write-movie", $movie,
        "--fixed-fps", $Fps,
        "--resolution", "$([int]($Width / 2))x$([int]($Height / 2))",
        "--quit-after", ($quitSec * $Fps),
        "--"
    ) + $userArgs
    $overridePath = Join-Path $project "override.cfg"
    $overrideBackup = "$overridePath.fest_backup"
    if (Test-Path $overridePath) {
        # A run killed mid-capture never reaches the finally below and leaves its
        # own override.cfg behind; backing that up and restoring it would make the
        # capture resolution stick for every normal run. Ours only ever contains
        # the viewport size (+ mjpeg quality), so anything that looks like that is
        # stale and goes; anything else is the user's and is preserved.
        $existing = (Get-Content $overridePath -Raw) -replace "`r", ""
        if ($existing -match '^\[display\]\nwindow/size/viewport_width=\d+\nwindow/size/viewport_height=\d+\n(\n\[editor\]\nmovie_writer/mjpeg_quality=[\d.]+\n)?$') {
            Remove-Item $overridePath -Force
        } else {
            Move-Item $overridePath $overrideBackup -Force
        }
    }
    try {
        # ascii: a UTF-8 BOM makes Godot silently ignore the whole file.
        $overrideText = "[display]`nwindow/size/viewport_width=$Width`nwindow/size/viewport_height=$Height`n"
        if ($isBattle) { $overrideText += "`n[editor]`nmovie_writer/mjpeg_quality=1.0`n" }
        Set-Content -Path $overridePath -Encoding ascii -NoNewline -Value $overrideText
        # Godot logs to stderr; under "Stop" PowerShell turns the first stderr
        # line into a terminating error when the caller redirects streams.
        $ErrorActionPreference = "Continue"
        & $Godot @godotArgs 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch 'EffekseerSystem|breakpad' } | Out-Host
        $godotExit = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
    } finally {
        Remove-Item $overridePath -Force -ErrorAction SilentlyContinue
        if (Test-Path $overrideBackup) { Move-Item $overrideBackup $overridePath -Force }
    }
    if ($godotExit -ne 0) { throw "godot exited with $godotExit" }
}

$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg) {
    $ffmpeg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ffmpeg) { throw "ffmpeg not found" }

# Battle: unpack the .avi into the same PNG sequence the prep shots use, starting
# at the frame where the board finished building (manifest start_frame), so the
# model-loading bar never reaches the clip and -Segments times are battle time.
if ($isBattle -and -not $NoCapture) {
    $manifest = Get-Content (Join-Path $framesDir "manifest.json") -Raw | ConvertFrom-Json
    $skip = [double]$manifest.start_frame / $Fps
    Write-Host ("battle starts at frame {0} ({1:N1}s), finished at frame {2}" -f $manifest.start_frame, $skip, $manifest.finished_frame)
    & $ffmpeg -y -loglevel error -ss $skip -i (Join-Path $framesDir "take.avi") -start_number 0 (Join-Path $framesDir "frame%08d.png")
    if ($LASTEXITCODE -ne 0) { throw "avi unpack failed" }
}

$frames = @(Get-ChildItem -Path $framesDir -Filter "frame*.png" | Sort-Object Name)
if ($frames.Count -eq 0) { throw "no frames in $framesDir" }
Write-Host "frames: $($frames.Count) in $framesDir"

# The first frames are the model-loading lead-in; the timeline's first action
# is at 2s, so start the clip 1s in (board already built, nothing popped yet).
$start = if ($isBattle) { 0.0 } else { 1.0 }
$cropFilter = if ($Crop) { "crop=$Crop," } else { "" }
$inArgs = @("-y", "-loglevel", "error", "-framerate", $Fps, "-start_number", 0,
    "-i", (Join-Path $framesDir "frame%08d.png"), "-ss", $start)

# -Segments "start-end@w:h:x:y;start-end@w:h:x:y" cuts the clip into pieces with
# their own crop and joins them (hard cuts) - e.g. full UI, then a close-up on
# the board for the 4-star impact. All pieces are scaled to the first one's size.
if (-not $Segments -and $Shot -eq "fourstar") {
    # The camp/card part is 16:9 around the centred panel; the card closes at
    # 9.6s and the clip cuts to the Human King (board row 3, centre) for the
    # lightning, burst and star pop.
    $Segments = "1.5-9.6@1536:864:192:0;9.6-12.8@704:396:632:210"
}
if (-not $Segments -and $Shot -eq "cards") {
    # Store unit page: header + race tabs + both unit columns + the pop-up card,
    # without the empty strips of page background on either side.
    $Segments = "1.0-19.7@1344:756:288:0"
}
if (-not $Segments -and $Shot -eq "treasure") {
    # Full frame throughout: the user wants no zoom-in when the set completes.
    $Segments = "1.5-12.0@1536:864:192:0"
}
$outW = 1920; $outH = 1080
$segFilter = ""
if ($Segments) {
    $parts = $Segments.Split(";")
    $first = $parts[0].Split("@")[1].Split(":")
    $aspect = [double]$first[0] / [double]$first[1]
    $outH = [int]([math]::Round($outW / $aspect / 2) * 2)
    $labels = ""
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $range, $c = $parts[$i].Split("@")
        $s, $e = $range.Split("-")
        $segFilter += "[0:v]trim=start=${s}:end=${e},setpts=PTS-STARTPTS,crop=$c,scale=${outW}:${outH}:flags=lanczos,setsar=1[s$i];"
        $labels += "[s$i]"
    }
    $segFilter += "${labels}concat=n=$($parts.Count):v=1:a=0[cut]"
    $inArgs = @("-y", "-loglevel", "error", "-framerate", $Fps, "-start_number", 0,
        "-i", (Join-Path $framesDir "frame%08d.png"))
}

$mp4 = Join-Path $outDir "$Shot.mp4"
if ($Segments) {
    & $ffmpeg @inArgs -filter_complex "$segFilter" -map "[cut]" -c:v libx264 -pix_fmt yuv420p -crf 16 -preset slow $mp4
} else {
    & $ffmpeg @inArgs -vf "${cropFilter}scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -pix_fmt yuv420p -crf 16 -preset slow $mp4
}
if ($LASTEXITCODE -ne 0) { throw "mp4 encode failed" }

# Two-pass palette GIF: one palette for the whole clip keeps colours stable
# between frames (per-frame palettes flicker on the parchment gradients).
$gif = Join-Path $outDir "$Shot.gif"
# bayer, not sierra: error-diffusion noise changes every frame and defeats GIF's
# inter-frame compression (fourstar: 11 MB sierra vs 3.8 MB bayer at 616px/15fps).
$palette = "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
if ($Segments) {
    & $ffmpeg @inArgs -filter_complex "$segFilter;[cut]fps=$GifFps,scale=${GifWidth}:-1:flags=lanczos,$palette" -loop 0 $gif
} else {
    & $ffmpeg @inArgs -vf "${cropFilter}fps=$GifFps,scale=${GifWidth}:-1:flags=lanczos,$palette" -loop 0 $gif
}
if ($LASTEXITCODE -ne 0) { throw "gif encode failed" }

foreach ($f in @($mp4, $gif)) {
    Write-Host ("{0}  {1:N1} MB" -f $f, ((Get-Item $f).Length / 1MB))
}
