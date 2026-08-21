# ============================================================
#  Glory 服务器包一键打包脚本
#  推荐用法：双击同目录的 make_server_zip.bat（最稳）
#  也可在 PowerShell 里执行： .\make_server_zip.ps1
#
#  输出文件名带协议号：glory_server_p<N>.zip，N 由本脚本**从 NetworkConfig.gd 实读**。
#
#  2026-08-21 改：此前固定叫 glory_server_upload.zip，理由是"杜绝传了 v4 解压了 v5"。
#  实战里它造出了相反的事故：服务器家目录里躺着一个同名的昨天的包，名字一模一样，
#  人看不出区别，差点就把 protocol 16 的旧包当成新包解压了。名字里带上协议号之后，
#  p16 和 p17 一眼就能分开，上传后也不会静默覆盖掉另一个版本。
#
#  名字是从源码自动生成的，**不要手写**：手写的版本号会和内容漂移，
#  而自动生成的名字永远不会擒谎。最终以服务器启动日志
#  （journalctl -u glory-server）里 "server starting protocol=N" 为准。
#
#  2026-07-28 修：此前脚本"打包成功"只代表**文件复制完了**，不代表包能跑。
#  实测上一个包在空目录里根本起不来（没有 assets/，UI 主场景 preload 失败 ->
#  进程既不报错也不退出更不监听，静默挂住）。现在结尾会做一次**真正的冷启动
#  冒烟测试**：解压到空目录 -> headless 起服 -> 必须打印 server started。
#  测试不过 = 打包失败（退出码非 0），不留下能冒充新产物的 ZIP。
# ============================================================

param(
    [string]$Src = $PSScriptRoot,
    # 留空 = 自动命名为 glory_server_p<协议号>.zip（协议号从源码实读）
    [string]$Out = "",
    # 冷启动冒烟测试用的 Godot。找不到就跳过测试并**降级为失败**（不能默默放过）。
    [string]$Godot = "C:\Users\Leno\Desktop\godot\Godot_v4.7-stable_win64_console.exe",
    [switch]$SkipSmoke,
    [switch]$NoPause
)
$ErrorActionPreference = "Stop"
$src   = $Src
$out   = $Out
$stamp = Get-Date -Format 'HHmmss'
$stage = "$env:TEMP\glory_server_stage_$stamp"
# 先写唯一临时 ZIP，全部检查通过之后才原子替换正式文件 ——
# 否则任何一步失败都会留下一个"看起来是新包"的旧文件名产物。
$tmpZip = "$env:TEMP\glory_server_$stamp.zip"
# 冷启动测试目录必须**短**：包里 effects 下有几层很深的第三方参考包，
# 放在长路径下解压会撞 Windows MAX_PATH（实测过）。
$smokeDir = "C:\_glory_smoke_$stamp"
$smokePort = 8199

function Fail($msg) {
    Write-Host ""
    Write-Host "!! 打包失败: $msg" -ForegroundColor Red
    Write-Host "   请把这行红字截图发给我。" -ForegroundColor Red
    if (-not $NoPause) { try { Read-Host "按回车键关闭本窗口" } catch {} }
    exit 1
}

try {
    Write-Host "[1/6] 检查项目目录..." -ForegroundColor Cyan
    if (-not (Test-Path $src)) { throw "找不到项目目录: $src" }
    if (-not (Test-Path "$src\scenes\server\ServerMain.tscn")) {
        throw "缺少专服入口场景 scenes/server/ServerMain.tscn（没有它服务器会去加载 UI 主场景然后静默挂住）"
    }

    Write-Host "[2/6] 准备临时目录..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $stage | Out-Null

    Write-Host "[3/6] 复制服务器需要的文件(脚本/场景/特效/数据/工具)..." -ForegroundColor Cyan
    foreach ($d in @("scripts", "scenes", "effects", "data", "tools")) {
        if (-not (Test-Path "$src\$d")) { throw "缺少文件夹: $src\$d" }
        Copy-Item -Recurse -Force "$src\$d" "$stage\$d"
    }
    # 备份/临时文件不上服务器（BattleSimulator.gd.bak 一个就 112KB，且是过期实现，
    # 混在包里会让人误读为现行代码）。
    # 注意 `.bak_20260101` 这种带后缀的名字**不匹配** `*.bak`——之前 18 个残留就是这么来的。
    Get-ChildItem -Path $stage -Recurse -File -Include *.bak, *.tmp, *.orig, *~ |
        ForEach-Object { Remove-Item -Force $_.FullName }
    Get-ChildItem -Path $stage -Recurse -File | Where-Object { $_.Name -match '\.(bak|tmp|orig)_' } |
        ForEach-Object { Remove-Item -Force $_.FullName }
    # 第三方参考包：服务器一个字节都用不到，却贡献了大部分体积和最深的路径
    # （深到在 Windows 上解压会失败）。
    Get-ChildItem -Path $stage -Recurse -Directory -Filter "reference_packages" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

    Copy-Item -Force "$src\project.godot" "$stage\project.godot"
    New-Item -ItemType Directory -Force "$stage\.godot" | Out-Null
    if (-not (Test-Path "$src\.godot\global_script_class_cache.cfg")) {
        throw "缺少 .godot\global_script_class_cache.cfg。新增 class_name 后必须先重建：godot --headless --editor --quit --path ."
    }
    Copy-Item -Force "$src\.godot\global_script_class_cache.cfg" "$stage\.godot\"

    # 读取协议号 + 写入出厂信息（跟着包走，服务器上 cat build_info.txt 可查）
    $protoMatch = Select-String -Path "$stage\scripts\multiplayer\NetworkConfig.gd" -Pattern 'NETWORK_PROTOCOL_VERSION := (\d+)'
    if (-not $protoMatch) { throw "读不到 NETWORK_PROTOCOL_VERSION —— 不能写成 '?' 然后当作成功继续" }
    $protocol = $protoMatch.Matches[0].Groups[1].Value
    # 名字跟着实读到的协议号走，不接受手写 —— 手写会和内容漂移。
    if (-not $out) { $out = Join-Path $PSScriptRoot "glory_server_p$protocol.zip" }
    $buildTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $gitSha = ""
    try { $gitSha = (& git -C $src rev-parse HEAD 2>$null) } catch {}
    $gitDirty = ""
    try { if (& git -C $src status --porcelain 2>$null) { $gitDirty = "true" } else { $gitDirty = "false" } } catch {}
    "built: $buildTime`r`nprotocol: $protocol`r`ngit: $gitSha`r`ndirty: $gitDirty" |
        Out-File -Encoding utf8 "$stage\build_info.txt"

    Write-Host "[4/6] 打包成临时 zip..." -ForegroundColor Cyan
    Compress-Archive -Path "$stage\*" -DestinationPath $tmpZip -Force

    Write-Host "[5/6] 冷启动冒烟测试(空目录解压 + headless 起服)..." -ForegroundColor Cyan
    if ($SkipSmoke) {
        Write-Host "    !! 已跳过冒烟测试 —— 这个包**没有**冷启动证据，不可作为发布候选" -ForegroundColor Yellow
    } elseif (-not (Test-Path $Godot)) {
        throw "找不到 Godot 可执行文件: $Godot（用 -Godot 指定，或 -SkipSmoke 明确放弃验证）"
    } else {
        New-Item -ItemType Directory -Force $smokeDir | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $smokeDir)
        $so = "$env:TEMP\glory_smoke_out_$stamp.txt"
        # --port=N 必须是等号形式：NetworkService._cmdline_int() 只认 "--port=" 前缀，
        # 空格形式会被静默忽略然后回落到 SERVER_PORT+shard=8080。之前这里写的是空格
        # 形式，于是冒烟测试名义上用 8199、实际去抢 8080 —— 本机只要有别的东西占着
        # 8080，打包就会以"冷启动失败"告终，而报错里一个字都不会提到端口。
        #
        # 注意：下面那行以反引号续行，中间不能插注释行 —— 一插 -ArgumentList 就断成
        # 独立语句，Godot 变成无参启动、弹出项目管理器 GUI，然后永远挂在那里。
        $proc = Start-Process -FilePath $Godot -PassThru -NoNewWindow -RedirectStandardOutput $so `
            -ArgumentList @("--headless", "--path", $smokeDir, "res://scenes/server/ServerMain.tscn",
                            "--server", "--port=$smokePort")
        Start-Sleep -Seconds 15
        if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        $log = ""
        if (Test-Path $so) { $log = Get-Content $so -Raw }
        Remove-Item -Recurse -Force $smokeDir -ErrorAction SilentlyContinue
        Remove-Item -Force $so -ErrorAction SilentlyContinue
        if ($log -notmatch "server started protocol=$protocol") {
            Write-Host "---- 冒烟测试输出 ----" -ForegroundColor Yellow
            Write-Host $log
            throw "冷启动失败：没等到 'server started protocol=$protocol'。这个包传上去只会静默挂住。"
        }
        if ($log -match "SCRIPT ERROR") {
            Write-Host "---- 冒烟测试输出 ----" -ForegroundColor Yellow
            Write-Host $log
            throw "冷启动过程中有 SCRIPT ERROR —— 不能当作可发布产物"
        }
        Write-Host "    冷启动 OK：server started protocol=$protocol" -ForegroundColor Green
    }

    Write-Host "[6/6] 替换正式文件..." -ForegroundColor Cyan
    $outDir = Split-Path $out
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    Move-Item -Force $tmpZip $out

    $item  = Get-Item $out
    $files = (Get-ChildItem -Recurse -File $stage).Count
    $sha   = (Get-FileHash $out -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host " 打包成功（含冷启动验证）" -ForegroundColor Green
    Write-Host " 文件: $out"
    Write-Host " 大小: $($item.Length) 字节 | 文件数: $files"
    Write-Host " SHA-256: $sha"
    Write-Host " 打包时间: $buildTime"
    Write-Host " Git: $gitSha (dirty=$gitDirty)"
    Write-Host " 协议版本: $protocol   <- 服务器启动日志里必须显示同样的数字" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host " 接下来在服务器 SSH 里执行：" -ForegroundColor Cyan
    $zipName = Split-Path $out -Leaf
    Write-Host "   1. UPLOAD FILE 上传 $zipName"
    Write-Host "   2. unzip -q ~/$zipName -d ~/Glory/`"Beta 0.04`""
    Write-Host "   3. sudo systemctl restart glory-server"
    Write-Host "   4. journalctl -u glory-server -n 5 --no-pager"
    Write-Host "      ^ 看到 server starting protocol=$protocol 才算部署成功" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " !! systemd 的 ExecStart 必须带上入口场景，否则会去加载 UI 主场景然后静默挂住：" -ForegroundColor Yellow
    Write-Host "    godot --headless --path <目录> res://scenes/server/ServerMain.tscn --server --port=8080" -ForegroundColor Yellow
    Write-Host "    ^ --port 必须用等号形式；写成 '--port 8080' 会被静默忽略并回落到 8080（多分片时就会撞车）" -ForegroundColor Yellow
}
catch {
    Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $smokeDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    Fail $_.Exception.Message
}

Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
Write-Host ""
if (-not $NoPause) { try { Read-Host "按回车键关闭本窗口" } catch {} }
exit 0
