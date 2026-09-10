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
    # **留空 = 自动查找**（见 Resolve-Godot）。
    [string]$Godot = "",
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

# Godot console 版的位置：**按优先级找，不写死路径。**
#
# 这里原来写死的是 "C:\Users\Leno\Desktop\godot\..."。换一台机器（或者换个人）
# 之后双击 make_server_zip.bat 必然失败，报的还是「找不到 Godot 可执行文件」——
# 于是「打包」变成了必须问别人才会做的事。
#
# 优先级，越靠前越优先：
#   1. -Godot 参数           明确指定，永远最高
#   2. GLORY_GODOT 环境变量   CI / 想固定某个版本时用
#   3. tools\godot_path.txt   本机设一次就不用再管（已进 .gitignore）
#   4. 自动扫描常见位置        桌面 / 下载 / Program Files
#
# 必须是 **console 版**：普通版在 Windows 上不把日志写到 stdout，
# 冒烟测试会收到空输出，然后把「起服成功」误判成失败。
function Resolve-Godot([string]$explicit, [string]$srcRoot) {
    if ($explicit) {
        if (-not (Test-Path $explicit)) { throw "-Godot 指定的文件不存在: $explicit" }
        return $explicit
    }
    if ($env:GLORY_GODOT -and (Test-Path $env:GLORY_GODOT)) { return $env:GLORY_GODOT }

    $pinFile = Join-Path $srcRoot "tools\godot_path.txt"
    if (Test-Path $pinFile) {
        $pinned = (Get-Content $pinFile -Raw -Encoding UTF8).Trim()
        if ($pinned -and (Test-Path $pinned)) { return $pinned }
        if ($pinned) {
            Write-Host "    tools\godot_path.txt 指向的文件不存在，改用自动扫描: $pinned" -ForegroundColor Yellow
        }
    }

    $roots = @(
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "OneDrive\桌面"),
        (Join-Path $env:USERPROFILE "OneDrive\Desktop"),
        "C:\Program Files",
        "C:\Program Files (x86)"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $found = @()
    foreach ($root in $roots) {
        # 深度限制 2 层：Godot 官方 zip 解出来就是 <目录>\Godot_...exe，
        # 再深就是在扫整个用户目录，慢且没必要。
        $found += Get-ChildItem -Path $root -Filter "Godot*console*.exe" -File -Depth 2 -ErrorAction SilentlyContinue
    }
    if (-not $found) { return "" }

    # 优先 4.7.x（project.godot 的 config/features 写的是 4.7），同版本取最新。
    $best = $found |
        Sort-Object @{ Expression = { if ($_.Name -match "v4\.7") { 1 } else { 0 } }; Descending = $true },
                    @{ Expression = { $_.Name }; Descending = $true } |
        Select-Object -First 1
    return $best.FullName
}


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

    if (-not $SkipSmoke) {
        $Godot = Resolve-Godot $Godot $src
        if ($Godot) { Write-Host "    Godot: $Godot" -ForegroundColor DarkGray }
    }

    Write-Host "[2/6] 准备临时目录..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $stage | Out-Null

    Write-Host "[3/6] 复制服务器需要的文件(脚本/场景/特效/数据/工具)..." -ForegroundColor Cyan
    # ui 是 2026-09-09 加的。此前没有它，而 project.godot 里有三个 autoload
    # 就住在 ui/ 下面（ModalStack / DialogService / AsyncActionController），
    # TutorialMode 还 preload 了 ui/components/GloryConfirmDialog.gd，
    # boot_splash 也指向 ui/branding/。于是服务器每次启动都刷 5 条 SCRIPT ERROR
    # 和一条 boot splash 失败 —— 服务器不用这些东西所以照常跑，但那堆固定噪音会把
    # 真正的错误盖住，而且下面那道 SCRIPT ERROR 门禁一开就会被它顶红。
    # ui/ 一共 171 KB / 28 个文件，相对 4.7 MB 的包可以忽略。
    # 比起从 project.godot 里摘掉那几个 autoload，直接打进去更稳：以后再加 UI
    # autoload 不会又一次静默地把服务器打回这个状态。
    foreach ($d in @("scripts", "scenes", "effects", "data", "tools", "ui")) {
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
    # 打包与冒烟解压都要它，所以提到这里加载一次。
    # **两个程序集都要加载**：ZipFile / ZipFileExtensions 在 .FileSystem 里，
    # 而 ZipArchive / ZipArchiveMode 在 System.IO.Compression 里。
    # 只加载前者的话，报的是 "Unable to find type [ZipArchiveMode]"。
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # **不用 Compress-Archive，也不用 ZipFile::CreateFromDirectory。**
    #
    # 两者在 Windows PowerShell 5.1（.NET Framework 4.x）上都会把 zip 条目里的
    # 路径分隔符写成**反斜杠**，而 ZIP 规范要求正斜杠。后果是服务器上解压时报
    #   warning: ... appears to use backslashes as path separators
    # Info-ZIP 会自己纠正，所以一直没出事 —— 但换个不纠正的解压工具，就会解出
    # 一堆文件名里带反斜杠的**平铺**文件，而症状同样只是"服务器起不来"。
    # （CreateFromDirectory 在 .NET Core / .NET 5+ 才修好，5.1 上没得用。）
    #
    # 所以逐个文件建条目，自己把相对路径里的 \ 换成 /。多几行，但结果确定。
    # 实测门禁：打完包会断言 zip 里带反斜杠的条目数为 0，不为 0 直接打包失败。
    $zip = [System.IO.Compression.ZipFile]::Open($tmpZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $baseLen = ((Resolve-Path $stage).Path.TrimEnd('\') + '\').Length
        foreach ($f in (Get-ChildItem -Path $stage -Recurse -File)) {
            $rel = $f.FullName.Substring($baseLen).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
        }
    } finally { $zip.Dispose() }

    # 断言：一个反斜杠条目都不许有。没有这条，上面那段写错了也没人会发现 ——
    # 因为 Info-ZIP 照样能解开，症状要等换工具或换平台才浮出来。
    $check = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
    $backslashEntries = @($check.Entries | Where-Object { $_.FullName.Contains('\') }).Count
    $check.Dispose()
    if ($backslashEntries -gt 0) {
        throw "zip 里有 $backslashEntries 个条目用反斜杠当路径分隔符，不符合 ZIP 规范"
    }

    Write-Host "[5/6] 冷启动冒烟测试(空目录解压 + headless 起服)..." -ForegroundColor Cyan
    if ($SkipSmoke) {
        Write-Host "    !! 已跳过冒烟测试 —— 这个包**没有**冷启动证据，不可作为发布候选" -ForegroundColor Yellow
    } elseif (-not (Test-Path $Godot)) {
        throw ("自动找不到 Godot console 版。三种解法任选一种：`n" +
            "  1. 在项目根目录建 tools\godot_path.txt，写一行 Godot_v4.7.x_console.exe 的完整路径（推荐，设一次就好）`n" +
            "  2. 运行时加 -Godot ""<完整路径>""`n" +
            "  3. 加 -SkipSmoke 明确放弃冷启动验证（那种包没有冷启动证据，不可作为发布候选）")
    } else {
        New-Item -ItemType Directory -Force $smokeDir | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $smokeDir)
        $so = "$env:TEMP\glory_smoke_out_$stamp.txt"
        # stderr 必须单独收。**此前只收了 stdout，而 Godot 把 SCRIPT ERROR 打到
        # stderr** —— 于是下面那句 `if ($log -match "SCRIPT ERROR")` 从来没有可能
        # 触发过，是一道从写下就失效的门禁（2026-09-09 实测：一次刷了 5 条
        # SCRIPT ERROR，打包照样报成功）。
        # 两个流不能重定向到同一个文件，PowerShell 会直接报错，所以是两个文件。
        $se = "$env:TEMP\glory_smoke_err_$stamp.txt"
        # --port=N 必须是等号形式：NetworkService._cmdline_int() 只认 "--port=" 前缀，
        # 空格形式会被静默忽略然后回落到 SERVER_PORT+shard=8080。之前这里写的是空格
        # 形式，于是冒烟测试名义上用 8199、实际去抢 8080 —— 本机只要有别的东西占着
        # 8080，打包就会以"冷启动失败"告终，而报错里一个字都不会提到端口。
        #
        # 注意：下面那行以反引号续行，中间不能插注释行 —— 一插 -ArgumentList 就断成
        # 独立语句，Godot 变成无参启动、弹出项目管理器 GUI，然后永远挂在那里。
        $proc = Start-Process -FilePath $Godot -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se `
            -ArgumentList @("--headless", "--path", $smokeDir, "res://scenes/server/ServerMain.tscn",
                            "--server", "--port=$smokePort")
        Start-Sleep -Seconds 15
        if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        $log = ""
        if (Test-Path $so) { $log = Get-Content $so -Raw }
        $errlog = ""
        if (Test-Path $se) { $errlog = Get-Content $se -Raw }
        Remove-Item -Recurse -Force $smokeDir -ErrorAction SilentlyContinue
        Remove-Item -Force $so, $se -ErrorAction SilentlyContinue
        if ($log -notmatch "server started protocol=$protocol") {
            Write-Host "---- 冒烟测试输出 ----" -ForegroundColor Yellow
            Write-Host $log
            throw "冷启动失败：没等到 'server started protocol=$protocol'。这个包传上去只会静默挂住。"
        }
        # 判据在 **stderr** 上。两条都是"服务器要用的东西没加载起来"的明确信号，
        # 健康启动时一条都不该出现：
        #   SCRIPT ERROR                      脚本没编译过（"静默挂住"就是这么来的）
        #   Failed to instantiate an autoload  autoload 没起来
        # 刻意**不**拿裸 "ERROR:" 当判据：Godot 用它报很多无害的事，
        # 那样会让打包因为噪音变红，然后所有人学会无视它 —— 比没有门禁更糟。
        $fatalPatterns = @("SCRIPT ERROR", "Failed to instantiate an autoload")
        $hits = @()
        foreach ($pat in $fatalPatterns) {
            if ($errlog -match [regex]::Escape($pat)) { $hits += $pat }
        }
        if ($hits.Count -gt 0) {
            Write-Host "---- 冒烟测试 stderr ----" -ForegroundColor Yellow
            Write-Host $errlog
            throw "冷启动 stderr 里出现了 $($hits -join ' / ') —— 不能当作可发布产物"
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
