# 技能特效截帧。
#
#   .\tools\vfx_capture.ps1 -Out captures\baseline
#   .\tools\vfx_capture.ps1 -Out captures\after -Skills "arrow_rain,black_hole"
#   .\tools\vfx_capture.ps1 -Out captures\low -Tier low
#
# 然后比对：
#   python tools/vfx_diff.py captures/baseline captures/after
#
# 注意：Movie Maker 模式需要真实的渲染上下文，不能加 --headless，
# 会短暂弹出一个窗口。这是 Godot 的限制，不是脚本的问题。

param(
    [string]$Out = "captures/run",
    [string]$Skills = "",
    [string]$Tier = "",
    [int]$Fps = 12,
    [int]$MaxFrames = 4000,
    [string]$Godot = "C:\Users\Leno\Desktop\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Godot)) {
    throw "Godot not found at $Godot - pass -Godot <path>"
}

$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $project $Out }
if (Test-Path $outPath) {
    # 帧序列必须从干净目录开始，否则上一次的残帧会混进比对。
    Remove-Item -Recurse -Force $outPath
}
New-Item -ItemType Directory -Force -Path $outPath | Out-Null

$userArgs = @("--out", $outPath)
if ($Skills) { $userArgs += @("--skills", $Skills) }
if ($Tier)   { $userArgs += @("--tier", $Tier) }

$godotArgs = @(
    "--path", $project,
    "--script", "tools/vfx_capture.gd",
    "--write-movie", (Join-Path $outPath "frame.png"),
    "--fixed-fps", $Fps,
    "--quit-after", $MaxFrames,
    "--"
) + $userArgs

Write-Host "capturing to $outPath ..."
& $Godot @godotArgs
if ($LASTEXITCODE -ne 0) { throw "godot exited with $LASTEXITCODE" }

$frames = @(Get-ChildItem -Path $outPath -Filter "frame*.png" -ErrorAction SilentlyContinue)
Write-Host "done: $($frames.Count) frames in $outPath"
if ($frames.Count -eq 0) {
    Write-Warning "no frames written - check that --headless was not in play and the movie writer had a render context"
}
