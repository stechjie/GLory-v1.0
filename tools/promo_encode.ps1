# Turns a captured PNG frame sequence into a social-ready mp4 plus poster stills.
#
#   .\tools\promo_encode.ps1 -TakeName dark_vs_god_r18_vertical
#   .\tools\promo_encode.ps1 -TakeName dark_vs_god_r18_vertical -KeepFrames
#
# Normally invoked by tools/promo_capture.ps1; run it standalone to re-encode a
# take that was captured with -NoEncode, or to try different poster counts
# without re-shooting.
#
# The lead-in frames are dropped using start_frame from manifest.json - those are
# the model-building progress bar, before the fight starts.

param(
    [Parameter(Mandatory = $true)][string]$TakeName,
    [string]$Root = "C:\Users\Leno\Desktop\promote",
    [int]$Fps = 60,
    # Stills pulled evenly across the clip, for use as thumbnails and cover art.
    [int]$Posters = 6,
    [int]$Crf = 18,
    # Where the clip's audio comes from:
    #   game  - the engine's own BGM/SFX, which Movie Maker wrote next to the
    #           frames. In sync for free, but it is the in-game mix.
    #   none  - silent. The right choice when the track will be added on the
    #           platform: Instagram, TikTok and 小红书 all have licensed music
    #           libraries, and using their native audio also helps reach.
    #           Also fine for LinkedIn, where video is mostly watched muted.
    #   <path> - any audio file to lay over the clip instead.
    [string]$Audio = "game",
    # Seconds into the audio file to start from. Only used with a file path.
    # Music written for a trailer usually builds, so the opening seconds are
    # the quietest part of the track and a bad place to cut a short clip from.
    [double]$AudioStart = 0,
    # Fade the last seconds out. A clip cut from the middle of a track
    # otherwise ends on a hard chop.
    [double]$FadeOut = 1.5,
    [switch]$KeepFrames
)

$ErrorActionPreference = "Stop"

function Resolve-FFmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget installs a shim here, but PATH only picks it up in a fresh shell.
    $link = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe"
    if (Test-Path $link) { return $link }
    $pkg = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages") `
        -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    throw "ffmpeg not found. Install with: winget install Gyan.FFmpeg"
}

$ffmpeg = Resolve-FFmpeg

$framesDir = Join-Path $Root "raw\$TakeName"
if (-not (Test-Path $framesDir)) { throw "no such take: $framesDir" }

$manifestPath = Join-Path $framesDir "manifest.json"
$startFrame = 0
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $startFrame = [int]$manifest.start_frame
    if ($manifest.fps) { $Fps = [int]$manifest.fps }
    $vp = $manifest.viewport_3d
    Write-Host "manifest: scene=$($manifest.scene) start_frame=$startFrame fps=$Fps"
    # Only the battle screen has a 3D SubViewport to check; prep and menu report
    # 0x0 and that is not a problem worth warning about.
    if ($manifest.scene -eq "battle") {
        Write-Host "  3d_viewport=$($vp[0])x$($vp[1])"
        if ([int]$vp[1] -le 540) {
            Write-Warning "3D viewport was only $($vp[0])x$($vp[1]) - this footage is an upscale."
        }
    }
} else {
    Write-Warning "no manifest.json - encoding from frame 0, lead-in will be included"
}

$total = @(Get-ChildItem -Path $framesDir -Filter "frame*.png").Count
$usable = $total - $startFrame
if ($usable -le 0) { throw "nothing to encode: $total frames, start_frame=$startFrame" }
Write-Host "encoding $usable of $total frames ($([math]::Round($usable / $Fps, 1))s)"

$clipPath = Join-Path $Root "clips\$TakeName.mp4"
$pattern = Join-Path $framesDir "frame%08d.png"

# Movie Maker writes the game's own audio next to the frames. It covers the
# whole timeline from frame 0, so it has to be seeked by however much video was
# trimmed off the front or the BGM runs ahead of the picture.
$wavPath = Join-Path $framesDir "frame.wav"
$audioArgs = @()
switch ($Audio) {
    "none" {
        Write-Host "audio: none (silent clip)"
    }
    "game" {
        if (Test-Path $wavPath) {
            # frame.wav covers the whole timeline from frame 0, so it has to be
            # seeked by however much video was trimmed off the front or the BGM
            # runs ahead of the picture.
            $audioOffset = [math]::Round($startFrame / $Fps, 3)
            $audioArgs = @("-ss", $audioOffset, "-i", $wavPath, "-c:a", "aac", "-b:a", "192k", "-shortest")
            Write-Host "audio: game BGM/SFX (offset ${audioOffset}s)"
        } else {
            Write-Warning "no frame.wav - clip will be silent"
        }
    }
    default {
        if (-not (Test-Path $Audio)) { throw "audio file not found: $Audio" }
        # -ss before -i seeks the input, so the track starts at AudioStart.
        # -shortest stops at the end of the video even if the track is longer.
        $audioArgs = @("-ss", $AudioStart, "-i", $Audio, "-c:a", "aac", "-b:a", "192k", "-shortest")
        if ($FadeOut -gt 0) {
            $clipSeconds = $usable / $Fps
            $fadeAt = [math]::Max(0, $clipSeconds - $FadeOut)
            $audioArgs += @("-af", "afade=t=out:st=$([math]::Round($fadeAt,2)):d=$FadeOut")
        }
        Write-Host "audio: $Audio (from ${AudioStart}s, ${FadeOut}s fade-out)"
    }
}

# yuv420p and the /2*2 scale guard are what make this playable everywhere:
# Instagram and X both reject odd dimensions and non-4:2:0 chroma. faststart
# moves the index to the front so it plays before the whole file has loaded.
& $ffmpeg -y -loglevel error -stats `
    -framerate $Fps -start_number $startFrame -i $pattern `
    @audioArgs `
    -c:v libx264 -preset slow -crf $Crf -profile:v high -pix_fmt yuv420p `
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart `
    $clipPath
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed encoding the clip" }

$postersDir = Join-Path $Root "posters\$TakeName"
New-Item -ItemType Directory -Force -Path $postersDir | Out-Null
Get-ChildItem -Path $postersDir -Filter "*.png" -ErrorAction SilentlyContinue | Remove-Item -Force

# Evenly spaced stills, skipping the first and last few frames - the fight opens
# on units still walking in and closes on the result overlay, neither of which
# makes a good thumbnail.
$margin = [math]::Max(1, [int]($usable * 0.08))
$step = [math]::Max(1, [int](($usable - 2 * $margin) / [math]::Max(1, $Posters)))
for ($i = 0; $i -lt $Posters; $i++) {
    $frameIndex = $startFrame + $margin + ($i * $step)
    $src = Join-Path $framesDir ("frame{0:D8}.png" -f $frameIndex)
    if (-not (Test-Path $src)) { continue }
    Copy-Item $src (Join-Path $postersDir ("{0}_{1:D2}.png" -f $TakeName, $i)) -Force
}
$posterCount = @(Get-ChildItem -Path $postersDir -Filter "*.png").Count

$sizeMb = [math]::Round((Get-Item $clipPath).Length / 1MB, 1)
Write-Host ""
Write-Host "clip:    $clipPath ($sizeMb MB)"
Write-Host "posters: $postersDir ($posterCount stills)"

if (-not $KeepFrames) {
    Remove-Item -Recurse -Force $framesDir
    Write-Host "raw frames removed (pass -KeepFrames to keep them)"
} else {
    Write-Host "raw frames kept in $framesDir"
}
