# Regenerates tools/fixtures/voice_adpcm_golden.json from the Android plugin's own
# ADPCM codec (see tools/voice_golden/AdpcmGolden.java for why it exists).
#
# Run it after changing android_plugins/glory_voice/src/com/glory/voice/AdpcmCodec.java:
#   powershell -File tools/voice_adpcm_golden.ps1
#
# Like build_aar.ps1, every Java tool works on copies under the ASCII temp dir: on a
# machine whose ANSI code page cannot represent the project path (this repo lives under
# a Chinese-named folder), javac / java reject it.

param(
    [string]$JdkBin = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($JdkBin)) {
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { $JdkBin = Join-Path $env:JAVA_HOME "bin" }
    else { $JdkBin = "C:\Program Files\app\JDK17\bin" }
}
$javac = Join-Path $JdkBin "javac.exe"
$java = Join-Path $JdkBin "java.exe"
foreach ($tool in @($javac, $java)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "missing $tool (pass -JdkBin <jdk>\bin)" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "glory_voice_adpcm_golden"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$src = Join-Path $work "src"
$out = Join-Path $work "out"
New-Item -ItemType Directory -Force -Path (Join-Path $src "com\glory\voice") | Out-Null
New-Item -ItemType Directory -Force -Path $out | Out-Null

Copy-Item -LiteralPath (Join-Path $root "android_plugins\glory_voice\src\com\glory\voice\AdpcmCodec.java") `
    -Destination (Join-Path $src "com\glory\voice\AdpcmCodec.java")
Copy-Item -LiteralPath (Join-Path $root "tools\voice_golden\AdpcmGolden.java") `
    -Destination (Join-Path $src "AdpcmGolden.java")

& $javac -encoding UTF-8 -d $out (Join-Path $src "com\glory\voice\AdpcmCodec.java") (Join-Path $src "AdpcmGolden.java")
if ($LASTEXITCODE -ne 0) { throw "javac failed ($LASTEXITCODE)" }

$json = & $java -cp $out AdpcmGolden
if ($LASTEXITCODE -ne 0) { throw "AdpcmGolden failed ($LASTEXITCODE)" }

$dest = Join-Path $root "tools\fixtures\voice_adpcm_golden.json"
$text = ($json -join "`n") + "`n"
[IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[voice_adpcm_golden] wrote " + $dest)
