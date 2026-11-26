# 跑一组门禁（默认：观战相关 3 项）。给拆 NetworkService 用的基线/回归入口。
#
# 用法：
#   powershell -File tools/run_gates.ps1                         观战 3 项
#   powershell -File tools/run_gates.ps1 -Names a_check,b_check   指定
#
# Godot 的查找顺序和 make_server_zip.ps1 一样：-Godot 参数 > 环境变量 GLORY_GODOT >
# tools\godot_path.txt（里面写 console exe 的完整路径）> 自动扫 Downloads / 桌面 / Program Files。
param(
    [string[]]$Names = @("spectator_check", "spectator_lobby_check", "spectator_match_check"),
    [string]$Godot = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Find-Godot([string]$explicit) {
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    if ($env:GLORY_GODOT -and (Test-Path $env:GLORY_GODOT)) { return $env:GLORY_GODOT }
    $pin = Join-Path $root "tools\godot_path.txt"
    if (Test-Path $pin) {
        $p = (Get-Content $pin -Raw -Encoding UTF8).Trim()
        if ($p -and (Test-Path $p)) { return $p }
    }
    $roots = @(
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "OneDrive\桌面"),
        (Join-Path $env:USERPROFILE "OneDrive\Desktop"),
        "C:\Program Files", "C:\Program Files (x86)"
    ) | Where-Object { $_ -and (Test-Path $_) }
    $found = @()
    foreach ($r in $roots) {
        $found += Get-ChildItem -Path $r -Filter "Godot*console*.exe" -File -Depth 2 -ErrorAction SilentlyContinue
    }
    if (-not $found) { return "" }
    $best = $found | Sort-Object @{ Expression = { if ($_.Name -match "v4\.7") { 1 } else { 0 } }; Descending = $true },
                                 @{ Expression = { $_.Name }; Descending = $true } | Select-Object -First 1
    return $best.FullName
}

$godot = Find-Godot $Godot
if (-not $godot) {
    Write-Host "!! 找不到 Godot console 版（Godot_v4.7-stable_win64_console.exe）。" -ForegroundColor Red
    Write-Host "   把它的完整路径写进 tools\godot_path.txt 再跑一次。" -ForegroundColor Red
    exit 2
}
Write-Host "[gates] Godot: $godot"
Write-Host "[gates] 检查: $($Names -join ', ')"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\run_check.ps1") -Name ($Names -join ",") -GodotConsole $godot
$code = $LASTEXITCODE
Write-Host ""
Write-Host "[gates] 退出码 $code。汇总: reports\checks\summary.json；每项日志: reports\checks\<名字>.stdout.log"
exit $code
