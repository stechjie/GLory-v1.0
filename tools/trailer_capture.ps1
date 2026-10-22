# 宣传片长镜录制：跑一条编排好的连续战斗，写出无损 PNG 序列，
# 然后（除非 -NoEncode）交给 tools/promo_encode.ps1 压成 mp4 + 海报图。
#
#   .\tools\trailer_capture.ps1                 # 默认横版 1920x1080 / 60fps
#   .\tools\trailer_capture.ps1 -Smoke          # 快速低清check，只看构图
#   .\tools\trailer_capture.ps1 -Vertical       # 竖版 1080x1920
#   .\tools\trailer_capture.ps1 -Realtime -Vertical # 按游戏实时运行并抓取竖版窗口
#   .\tools\trailer_capture.ps1 -Hud            # 保留游戏原生 HUD
#
# 编排内容（波次、升星、宝藏、神王、Boss 的时间点）写在 tools/trailer_capture.gd
# 的 BEATS 表里，要调节奏改那张表，不用动这个脚本。
#
# 实时模式抓 Godot 原生窗口；Movie Maker 模式也需要真实渲染上下文。
# 两种模式都不能加 --headless。
#
# 磁盘：1920x1080 的 PNG 一张 1~3 MB，60fps 跑 60 秒就是 ~3600 张，按几 GB 一条备着。
# 原始帧由 promo_encode.ps1 删掉，除非传 -KeepFrames。

param(
    # 阵容版本，见 trailer_capture.gd 的 VARIANTS：god = 极光射手版，dark = 暗族版。
    [ValidateSet("god", "dark")]
    [string]$Variant = "god",
    [int]$Fps = 60,
    # --quit-after 的安全上限。编排约 55 秒，模型预热和收尾需另留余量。
    # 前导帧会按 manifest 的 start_frame 裁掉。
    [int]$Seconds = 85,
    [int]$Seed = 20261020,
    # 素材面向国际平台，默认英文。
    [string]$Locale = "en",
    # 小怪种类。默认挑最脆的那只：两个射手要打出「一直在清」的观感，
    # 肉怪会让它们看起来打不动（详见 trailer_capture.gd 里 _monster_id 的注释）。
    [string]$Monster = "",
    [string]$Boss = "",
    # 默认完全按游戏原相机取景，棋子大小和场地边界保持原样。
    # 仅显式传入时才调整相机。
    [double]$CameraSize = 0,
    [double]$PanX = 0,
    [double]$PanZ = 0,
    [string]$Audio = "game",
    [double]$AudioStart = 0,
    # 竖版。保持游戏原相机，避免放大棋子或裁掉场地边缘。
    [switch]$Vertical,
    # 按游戏实时帧运行，使用 FFmpeg 捕获窗口；仍由本脚本启动和收尾。
    [switch]$Realtime,
    # 保留游戏原生 HUD（Skip 按钮、血条、单位名、半场提示）。默认全关。
    [switch]$Hud,
    [switch]$Smoke,
    # mjpeg = Godot 自带的 MJPEG .avi（画质 1.0），录完直接用 ffmpeg 转 mp4。**高清必须用它**：
    #   PNG 序列在 1920x1080 下每帧压缩约 0.65 秒，开战前的特效预热要渲染的帧一多，
    #   就撞上 BattleRenderWarmup 写死的 90 秒墙钟上限（MAX_TOTAL_MSEC），
    #   战斗被判 render_warmup_timeout 直接跳过 —— 第一次录高清就是这样只录到 3 秒。
    #   MJPEG 每帧只要十几毫秒，预热进得去，整条也从一个多小时降到几分钟。
    # png  = 无损 PNG 序列，交给 promo_encode.ps1。只适合 -Smoke 这种小画幅，用来逐帧核对。
    [ValidateSet("mjpeg", "png")]
    [string]$Format = "mjpeg",
    [switch]$NoEncode,
    [switch]$KeepFrames,
    # 实时模式可复用一次同编排 Movie Maker 录制的游戏音轨。
    [string]$AudioSource = "",
    [string]$Root = "C:\Users\Leno\Desktop\promote",
    [string]$Godot = "C:\Users\Leno\Desktop\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot

# 同 promo_encode.ps1：winget 装的 ffmpeg 要开新 shell 才进 PATH，这里自己找。
function Resolve-FFmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $link = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe"
    if (Test-Path $link) { return $link }
    $pkg = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages") `
        -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    throw "找不到 ffmpeg。安装：winget install Gyan.FFmpeg"
}

if (-not (Test-Path $Godot)) {
    throw "找不到 Godot：$Godot —— 用 -Godot <路径> 指定"
}

# 形状check默认四分之一分辨率、10fps；显式指定 -Fps 可用低分辨率检查流畅度。
if ($Smoke -and -not $PSBoundParameters.ContainsKey('Fps')) { $Fps = 10 }

# BattleScreen 的回放每 0.1 秒更新一次位置。片子按 60fps 输出时，
# 不插值就会连续 6 帧停住，再跳到下一格。只平滑显示节点，不改战斗模拟。
# 两种画幅都保留游戏原相机；需要特殊取景时由调用者显式传参。

# Movie Maker 录的是**根视口**，它的尺寸来自工程的 display/window/size 设置 ——
# **不是** --resolution。--resolution 只要一个窗口大小，录制照旧按工程的 1600x720。
# 想改录制尺寸只能覆盖那两个设置，override.cfg 可以做到且不动被纳入版本管理的
# project.godot。（这条是 promo_capture.ps1 先踩出来的，这里沿用同一套。）
if ($Vertical) { $movieW, $movieH = 1080, 1920 } else { $movieW, $movieH = 1920, 1080 }
if ($Smoke) {
    if ($Vertical) { $movieW, $movieH = 540, 960 } else { $movieW, $movieH = 960, 540 }
}

$orientation = if ($Vertical) { "vertical" } else { "landscape" }
# 神族版保持原来的文件名（已经发出去的片子都叫这个），其余版本带上版本名。
$takeName = if ($Variant -eq "god") { "trailer_waves_$orientation" } else { "trailer_${Variant}_$orientation" }
if ($Smoke) { $takeName = "smoke_$takeName" }
if ($Realtime) { $takeName = "realtime_$takeName" }

$framesDir = Join-Path $Root "raw\$takeName"
foreach ($dir in @($Root, (Join-Path $Root "raw"), (Join-Path $Root "clips"), (Join-Path $Root "posters"))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
# 帧序列必须从干净目录开始，否则上一条的残帧会被一起编码进这一条。
if (Test-Path $framesDir) { Remove-Item -Recurse -Force $framesDir }
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

$userArgs = @(
    "--out", $framesDir,
    "--variant", $Variant,
    "--seed", $Seed,
    "--fps", $Fps,
    "--locale", $Locale,
    "--camera-size", $CameraSize,
    "--pan-x", $PanX,
    "--pan-z", $PanZ,
    "--smooth"
)
if ($Monster -ne "") { $userArgs += @("--monster", $Monster) }
if ($Boss -ne "") { $userArgs += @("--boss", $Boss) }
if ($Hud) { $userArgs += "--hud" }

if ($Realtime) {
    $ffmpeg = Resolve-FFmpeg
    $userArgs += "--realtime"
    $godotArgs = @(
        "--path", $project,
        "--script", "tools/trailer_capture.gd",
        "--windowed",
        "--resolution", "${movieW}x${movieH}",
        "--position", "0,0",
        "--quit-after", ($Seconds * $Fps),
        "--"
    ) + $userArgs
    $overridePath = Join-Path $project "override.cfg"
    $overrideBackup = "$overridePath.trailer_backup"
    if (Test-Path $overridePath) { Move-Item $overridePath $overrideBackup -Force }
    $godotProcess = $null
    $captureProcess = $null
    $captureStartMs = 0
    $capturePath = Join-Path $framesDir "live.mkv"
    try {
        $overrideText = "[display]`nwindow/size/viewport_width=$movieW`nwindow/size/viewport_height=$movieH`n"
        Set-Content -Path $overridePath -Value $overrideText -Encoding ascii -NoNewline
        $godotInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $godotInfo.FileName = $Godot
        $godotInfo.UseShellExecute = $false
        # 实时窗口捕获需要可见的游戏窗口；隐藏启动会使 gdigrab 找不到它。
        $godotInfo.CreateNoWindow = $false
        $godotInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
        foreach ($arg in $godotArgs) { [void]$godotInfo.ArgumentList.Add([string]$arg) }
        $godotProcess = [System.Diagnostics.Process]::Start($godotInfo)
        if ($null -eq $godotProcess) { throw "Godot 实时进程启动失败" }

        # 等窗口可被 GDI 捕获，避免把启动桌面录进素材。
        $windowReady = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            Start-Sleep -Milliseconds 500
            & $ffmpeg -nostdin -loglevel quiet -f gdigrab -framerate 1 -draw_mouse 0 `
                -i 'title=GLory Trailer Capture' -frames:v 1 -f null NUL
            if ($LASTEXITCODE -eq 0) { $windowReady = $true; break }
            if ($godotProcess.HasExited) { break }
        }
        if (-not $windowReady) { throw "找不到 Godot 宣传片窗口，无法实时录制" }

        $captureInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $captureInfo.FileName = $ffmpeg
        $captureInfo.UseShellExecute = $false
        $captureInfo.CreateNoWindow = $true
        $captureInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $captureInfo.RedirectStandardInput = $true
        $captureArgs = @(
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "gfxcapture=window_title=GLory Trailer Capture:capture_cursor=0:capture_border=0:max_framerate=$Fps",
            "-t", $Seconds,
            "-vf", "hwdownload,format=bgra,format=yuv420p",
            "-c:v", "h264_nvenc", "-preset", "p5", "-cq", "14",
            "-pix_fmt", "yuv420p", $capturePath
        )
        foreach ($arg in $captureArgs) { [void]$captureInfo.ArgumentList.Add([string]$arg) }
        $captureStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $captureProcess = [System.Diagnostics.Process]::Start($captureInfo)
        if ($null -eq $captureProcess) { throw "FFmpeg 实时捕获启动失败" }
        Write-Host "实时录制 '$takeName' @ ${movieW}x${movieH} / ${Fps}fps -> $capturePath"
        if (-not $godotProcess.WaitForExit(($Seconds + 30) * 1000)) {
            throw "Godot 实时运行超过安全时限"
        }
        if (-not $captureProcess.HasExited) {
            $captureProcess.StandardInput.WriteLine("q")
            if (-not $captureProcess.WaitForExit(10000)) { throw "FFmpeg 未能正常结束实时捕获" }
        }
        if ($godotProcess.ExitCode -ne 0 -or $captureProcess.ExitCode -ne 0) {
            throw "实时录制失败：Godot=$($godotProcess.ExitCode)，FFmpeg=$($captureProcess.ExitCode)"
        }
    } finally {
        if ($captureProcess -ne $null -and -not $captureProcess.HasExited) { $captureProcess.Kill() }
        if ($godotProcess -ne $null -and -not $godotProcess.HasExited) { $godotProcess.Kill() }
        Remove-Item $overridePath -Force -ErrorAction SilentlyContinue
        if (Test-Path $overrideBackup) { Move-Item $overrideBackup $overridePath -Force }
    }
    $manifestPath = Join-Path $framesDir "manifest.json"
    if (-not (Test-Path $manifestPath)) { throw "实时录制没有写出 manifest" }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ([int64]$manifest.start_unix_msec -le 0) { throw "战斗未开始，实时录制作废" }
    $startSec = [math]::Max(0.0, ([double]$manifest.start_unix_msec - $captureStartMs) / 1000.0)
    $durationSec = if ([int64]$manifest.finished_unix_msec -gt [int64]$manifest.start_unix_msec) {
        ([double]$manifest.finished_unix_msec - [double]$manifest.start_unix_msec) / 1000.0 + 0.75
    } else { [math]::Max(1.0, $Seconds - $startSec) }
    $clipPath = Join-Path $Root "clips\$takeName.mp4"
    $encodeArgs = @("-y", "-loglevel", "error", "-ss", $startSec, "-i", $capturePath)
    if ($AudioSource -ne "") {
        $encodeArgs += @("-i", $AudioSource, "-map", "0:v:0", "-map", "1:a:0", "-c:a", "aac", "-b:a", "192k")
    } else {
        $encodeArgs += @("-an")
    }
    $encodeArgs += @("-t", $durationSec, "-vf", "scale=${movieW}:${movieH}:flags=lanczos", "-c:v", "libx264", "-preset", "slow", "-crf", "15", "-pix_fmt", "yuv420p", "-movflags", "+faststart", $clipPath)
    & $ffmpeg @encodeArgs
    if ($LASTEXITCODE -ne 0) { throw "实时视频编码失败" }
    Write-Host "clip: $clipPath"
    if (-not $KeepFrames) { Remove-Item $capturePath -Force }
    return
}

$moviePath = if ($Format -eq "mjpeg") { Join-Path $framesDir "take.avi" } else { Join-Path $framesDir "frame.png" }
$godotArgs = @(
    "--path", $project,
    "--script", "tools/trailer_capture.gd",
    "--write-movie", $moviePath,
    "--fixed-fps", $Fps,
    # 窗口只是因为 Movie Maker 需要渲染上下文才开的，取一半大小，
    # 免得 1080x1920 开出一个比屏幕还高的窗。但**长宽比必须和录制一致**：
    # 工程用 aspect="expand" 拉伸，窗口形状不同会把根视口撑成别的尺寸，
    # 录出来就是错的画幅（我这次就是这么录出三条横版的）。
    "--resolution", "$([int]($movieW / 2))x$([int]($movieH / 2))",
    "--quit-after", ($Seconds * $Fps),
    "--"
) + $userArgs

$overridePath = Join-Path $project "override.cfg"
$overrideBackup = "$overridePath.trailer_backup"
if (Test-Path $overridePath) { Move-Item $overridePath $overrideBackup -Force }

Write-Host "录制 '$takeName' @ ${movieW}x${movieH} / ${Fps}fps ($Locale) -> $framesDir"
try {
    # 必须在 Godot 启动前写好：工程设置只在启动时读一次。
    #
    # 用 ascii 不用 utf8：PowerShell 5.1 写 utf8 **带 BOM**，而 Godot 的配置解析器
    # 不会剥掉它 —— BOM 会落进第一个段名里，整个文件静默失效，录制回落到工程默认的
    # 1600x720，而且**任何地方都不报错**。
    $overrideText = "[display]`nwindow/size/viewport_width=$movieW`nwindow/size/viewport_height=$movieH`n"
    # MJPEG 画质默认 0.75，拉满到 1.0。
    if ($Format -eq "mjpeg") { $overrideText += "`n[editor]`nmovie_writer/mjpeg_quality=1.0`n" }
    Set-Content -Path $overridePath -Value $overrideText -Encoding ascii -NoNewline
    & $Godot @godotArgs
    $godotExit = $LASTEXITCODE
} finally {
    # 一定要删掉。留着的话，之后从编辑器或 console 二进制正常跑游戏，
    # 分辨率会被它悄悄改掉。
    Remove-Item $overridePath -Force -ErrorAction SilentlyContinue
    if (Test-Path $overrideBackup) { Move-Item $overrideBackup $overridePath -Force }
}
if ($godotExit -ne 0) { throw "godot 退出码 $godotExit" }

if ($Format -eq "png") {
    $frames = @(Get-ChildItem -Path $framesDir -Filter "frame*.png" -ErrorAction SilentlyContinue | Sort-Object Name)
    Write-Host "录到 $($frames.Count) 帧"
    if ($frames.Count -eq 0) { throw "一帧都没录到，检查上面的 Godot 输出" }
} elseif (-not (Test-Path $moviePath)) {
    throw "没录出 $moviePath，检查上面的 Godot 输出"
}

$manifestPath = Join-Path $framesDir "manifest.json"
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Write-Host ("战斗起始帧 {0}，模拟 {1} 帧，宝藏提示 {2} 个" -f `
        $manifest.start_frame, $manifest.replay_frames, $manifest.treasure_cues.Count)
}

# 战斗没真正开始就结束 = 这条废了（准备 / 预热超时之类）。别把 3 秒加载画面当成片交出去。
if ((Test-Path $manifestPath) -and ([int]$manifest.start_frame -le 0)) {
    throw "战斗没有开始（manifest.start_frame=0），这条录制作废。看上面 Godot 输出里的超时 / 报错。"
}

if ($NoEncode) {
    Write-Host "跳过编码（-NoEncode）。素材在 $framesDir"
    return
}

if ($Format -eq "mjpeg") {
    $ffmpeg = Resolve-FFmpeg
    $clipPath = Join-Path $Root "clips\$takeName.mp4"
    # Movie Maker 从第 0 帧开始写，manifest 的 start_frame 之前是模型加载的进度条。
    # MJPEG 每帧都是关键帧，-ss 放在 -i 前面也是逐帧精确的。
    # 画质拉满（用户要「最大功率」）：crf 12 + slower。仍用 yuv420p / high profile，
    # 手机硬解都认；yuv444 画质再高一点，但不少手机直接放不出来。
    $startSec = [double]$manifest.start_frame / [double]$Fps
    $audioArgs = if ($Audio -eq "none") { @("-an") } else { @("-c:a", "aac", "-b:a", "192k") }
    Write-Host ("编码 -> {0}（从 {1:N2}s 开始）" -f $clipPath, $startSec)
    & $ffmpeg -y -loglevel error -stats -ss $startSec -i $moviePath `
        -c:v libx264 -preset slower -crf 12 -profile:v high -pix_fmt yuv420p -movflags +faststart @audioArgs $clipPath
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg 编码失败" }
    Write-Host ("clip: {0} ({1:N1} MB)" -f $clipPath, ((Get-Item $clipPath).Length / 1MB))
    if (-not $KeepFrames) { Remove-Item $moviePath -Force }
    return
}

$encodeArgs = @{ TakeName = $takeName; Root = $Root; Fps = $Fps; Audio = $Audio; AudioStart = $AudioStart }
if ($KeepFrames) { $encodeArgs.KeepFrames = $true }
& (Join-Path $PSScriptRoot "promo_encode.ps1") @encodeArgs
