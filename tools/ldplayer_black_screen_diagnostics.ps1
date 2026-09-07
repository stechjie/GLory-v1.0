# V12-11 雷电黑屏最小诊断包（Windows / PowerShell 5.1）。
# 只读取设备/宿主状态、冷启动应用并取证；不安装 APK、不改 renderer、不改模拟器配置。

[CmdletBinding()]
param(
    [string]$Serial = "",
    [string]$Package = "glory.beta001",
    [string]$Adb = "adb",
    [string]$Apk = "",
    [string]$OutputDir = "",
    [ValidateRange(5, 60)][int]$CaptureSeconds = 30,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Adb {
    param([string[]]$Arguments)
    $prefix = @()
    if (-not [string]::IsNullOrWhiteSpace($Serial)) { $prefix = @("-s", $Serial) }
    & $Adb @prefix @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $($Arguments -join ' ')" }
}

if ($ValidateOnly) {
    $required = @(
        "ro.product.cpu.abilist", "ro.build.version.release", "ro.hardware.egl",
        "SurfaceFlinger", "logcat", "GLORY_STARTUP", "screencap", "Get-FileHash"
    )
    $source = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    $missing = @($required | Where-Object { $source -notmatch [regex]::Escape($_) })
    if ($missing.Count -gt 0) {
        Write-Error "LDPLAYER_DIAGNOSTICS_CONTRACT status=FAIL missing=$($missing -join ',')"
        exit 1
    }
    Write-Output "LDPLAYER_DIAGNOSTICS_CONTRACT status=PASS checks=$($required.Count)"
    exit 0
}

$adbCommand = Get-Command $Adb -ErrorAction SilentlyContinue
if ($null -eq $adbCommand -and -not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    throw "adb not found: $Adb"
}
$adbExe = if ($null -ne $adbCommand) { $adbCommand.Source } else { [IO.Path]::GetFullPath($Adb) }

if ([string]::IsNullOrWhiteSpace($Serial)) {
    $deviceLines = @(& $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" })
    if ($deviceLines.Count -ne 1) {
        throw "Specify -Serial when connected device count is not exactly one. Found $($deviceLines.Count)."
    }
    $Serial = ($deviceLines[0] -split "`t")[0]
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputDir = Join-Path (Get-Location) "reports\ldplayer_$stamp"
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$deviceState = (& $Adb -s $Serial get-state 2>&1 | Out-String).Trim()
if ($deviceState -ne "device") { throw "Device $Serial is not ready: $deviceState" }

Invoke-Adb @("shell", "getprop") | Out-File (Join-Path $resolvedOutput "getprop.txt") -Encoding utf8
Invoke-Adb @("shell", "dumpsys", "SurfaceFlinger") | Out-File (Join-Path $resolvedOutput "surfaceflinger.txt") -Encoding utf8
Invoke-Adb @("shell", "dumpsys", "display") | Out-File (Join-Path $resolvedOutput "display.txt") -Encoding utf8
Invoke-Adb @("shell", "dumpsys", "package", $Package) | Out-File (Join-Path $resolvedOutput "package.txt") -Encoding utf8

$dxdiagPath = Join-Path $resolvedOutput "dxdiag.txt"
$dxdiag = Get-Command "dxdiag.exe" -ErrorAction SilentlyContinue
if ($null -ne $dxdiag) {
    $process = Start-Process -FilePath $dxdiag.Source -ArgumentList @("/whql:off", "/t", $dxdiagPath) -WindowStyle Hidden -PassThru -Wait
}

Invoke-Adb @("logcat", "-c") | Out-Null
$startOutput = Invoke-Adb @("shell", "am", "start", "-W", "-S", "-n", "$Package/com.godot.game.GodotApp")
$startOutput | Out-File (Join-Path $resolvedOutput "am_start.txt") -Encoding utf8
Start-Sleep -Seconds $CaptureSeconds
Invoke-Adb @("logcat", "-d", "-v", "threadtime") | Out-File (Join-Path $resolvedOutput "logcat_full.txt") -Encoding utf8

$screenshotPath = Join-Path $resolvedOutput "screen.png"
$prefix = @()
if (-not [string]::IsNullOrWhiteSpace($Serial)) { $prefix = @("-s", $Serial) }
# PowerShell 5.1 会把 `& adb exec-out` 的二进制 stdout 当文本重编码，PNG 会损坏；
# 用进程级重定向保留原始字节。
$screenArgs = @($prefix + @("exec-out", "screencap", "-p"))
$screenProcess = Start-Process -FilePath $adbExe -ArgumentList $screenArgs `
    -RedirectStandardOutput $screenshotPath -WindowStyle Hidden -PassThru -Wait
if ($screenProcess.ExitCode -ne 0) { throw "adb screencap failed with exit $($screenProcess.ExitCode)" }

$props = Get-Content (Join-Path $resolvedOutput "getprop.txt") -Raw -Encoding UTF8
$logcat = Get-Content (Join-Path $resolvedOutput "logcat_full.txt") -Raw -Encoding UTF8
$summary = [ordered]@{
    schema = 1
    captured_utc = [DateTime]::UtcNow.ToString("o")
    serial = $Serial
    package = $Package
    capture_seconds = $CaptureSeconds
    abi_list = if ($props -match '\[ro\.product\.cpu\.abilist\]: \[([^\]]*)\]') { $Matches[1] } else { "" }
    android_release = if ($props -match '\[ro\.build\.version\.release\]: \[([^\]]*)\]') { $Matches[1] } else { "" }
    hardware_egl = if ($props -match '\[ro\.hardware\.egl\]: \[([^\]]*)\]') { $Matches[1] } else { "" }
    glory_startup_mark_count = ([regex]::Matches($logcat, "GLORY_STARTUP")).Count
    engine_init_seen = $logcat.Contains('"mark":"t0_trace_ready"')
    data_loaded_seen = $logcat.Contains('"mark":"data_registry_loaded"')
    fatal_exception_count = ([regex]::Matches($logcat, "FATAL EXCEPTION")).Count
    script_error_count = ([regex]::Matches($logcat, "SCRIPT ERROR")).Count
    apk_sha256 = ""
}
if (-not [string]::IsNullOrWhiteSpace($Apk)) {
    $resolvedApk = [IO.Path]::GetFullPath($Apk)
    if (-not (Test-Path -LiteralPath $resolvedApk -PathType Leaf)) { throw "APK not found: $resolvedApk" }
    $summary.apk_sha256 = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
}
$summary | ConvertTo-Json -Depth 5 | Out-File (Join-Path $resolvedOutput "summary.json") -Encoding utf8
Write-Output "LDPLAYER_DIAGNOSTICS status=CAPTURED output=$resolvedOutput startup_marks=$($summary.glory_startup_mark_count) fatal=$($summary.fatal_exception_count) script_errors=$($summary.script_error_count)"
