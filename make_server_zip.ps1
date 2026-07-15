# ============================================================
#  Glory 服务器包一键打包脚本
#  推荐用法：双击同目录的 make_server_zip.bat（最稳）
#  也可在 PowerShell 里执行： .\make_server_zip.ps1
#
#  输出文件名固定不带版本号（每次覆盖），杜绝"传了 v4 解压了 v5"的事故。
#  版本核对一律看协议号和打包时间：本脚本结尾会打印，服务器启动日志
#  （journalctl -u glory-server）里 "server starting protocol=N" 必须和它一致。
# ============================================================

$src   = "C:\Users\Leno\Desktop\test toon\Beta 0.04"     # 游戏项目目录
$out   = "D:\Glory android\glory_server_upload.zip"      # 输出的服务器包（固定名）
$stage = "$env:TEMP\glory_server_stage_$(Get-Date -Format 'HHmmss')"  # 临时目录

try {
    Write-Host "[1/5] 检查项目目录..." -ForegroundColor Cyan
    if (-not (Test-Path $src)) { throw "找不到项目目录: $src" }

    Write-Host "[2/5] 准备临时目录..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $stage | Out-Null

    Write-Host "[3/5] 复制服务器需要的文件(脚本/场景/特效/数据/工具)..." -ForegroundColor Cyan
    foreach ($d in @("scripts", "scenes", "effects", "data", "tools")) {
        if (-not (Test-Path "$src\$d")) { throw "缺少文件夹: $src\$d" }
        Copy-Item -Recurse -Force "$src\$d" "$stage\$d"
    }
    Copy-Item -Force "$src\project.godot" "$stage\project.godot"
    New-Item -ItemType Directory -Force "$stage\.godot" | Out-Null
    if (Test-Path "$src\.godot\global_script_class_cache.cfg") {
        Copy-Item -Force "$src\.godot\global_script_class_cache.cfg" "$stage\.godot\"
    }

    # 读取协议号 + 写入出厂信息（跟着包走，服务器上 cat build_info.txt 可查）
    $protoMatch = Select-String -Path "$stage\scripts\multiplayer\NetworkConfig.gd" -Pattern 'NETWORK_PROTOCOL_VERSION := (\d+)'
    $protocol = if ($protoMatch) { $protoMatch.Matches[0].Groups[1].Value } else { "?" }
    $buildTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "built: $buildTime`r`nprotocol: $protocol" | Out-File -Encoding utf8 "$stage\build_info.txt"

    Write-Host "[4/5] 打包成 zip: $out" -ForegroundColor Cyan
    $outDir = Split-Path $out
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    Compress-Archive -Path "$stage\*" -DestinationPath $out -Force

    Write-Host "[5/5] 完成，自检中..." -ForegroundColor Cyan
    $item  = Get-Item $out
    $files = (Get-ChildItem -Recurse -File $stage).Count

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host " 打包成功！" -ForegroundColor Green
    Write-Host " 文件: $out"
    Write-Host " 大小: $($item.Length) 字节 | 文件数: $files"
    Write-Host " 打包时间: $buildTime"
    Write-Host " 协议版本: $protocol   <- 服务器启动日志里必须显示同样的数字" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host " 接下来在服务器 SSH 里执行（每次都一样，可收藏）：" -ForegroundColor Cyan
    Write-Host "   1. UPLOAD FILE 上传 glory_server_upload.zip"
    Write-Host '   2. unzip -o ~/glory_server_upload.zip -d ~/Glory/"Beta 0.04"'
    Write-Host "   3. sudo systemctl restart glory-server"
    Write-Host "   4. journalctl -u glory-server -n 3 --no-pager"
    Write-Host "      ^ 看到 server starting protocol=$protocol 才算部署成功" -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "!! 打包失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   请把这行红字截图发给我。" -ForegroundColor Red
}

Write-Host ""
Read-Host "按回车键关闭本窗口"
