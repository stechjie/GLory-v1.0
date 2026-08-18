# Captures a full set of promo material in one go. Each take is independent, so
# a failure in one does not lose the others - failures are collected and
# reported at the end.
#
#   .\tools\promo_batch.ps1
#
# Roughly 4 minutes per take. Movie Maker renders far slower than real time
# (~4-20% of realtime), which is the price of never dropping a frame.
#
# Orientation per scene is deliberate, not a default:
#   battle -> both. The 3D camera can be re-aimed, so 9:16 works (see the
#             CameraSize/PanZ defaults in promo_capture.ps1).
#   prep, menu -> landscape only. Those screens are 2D layouts built for the
#             project's 1600x720 viewport and they do NOT reflow; in a vertical
#             frame they just stretch, leaving the controls stranded around a
#             large empty middle.

param(
    [string]$Root = "C:\Users\Leno\Desktop\promote",
    [int]$Fps = 30
)

$ErrorActionPreference = "Continue"
$capture = Join-Path $PSScriptRoot "promo_capture.ps1"

$takes = @(
    @{ Scene = "menu";   Landscape = $true;  Seconds = 12 }
    @{ Scene = "prep";   Landscape = $true;  Seconds = 15; Lineup = "dark_vs_god" }
    @{ Scene = "prep";   Landscape = $true;  Seconds = 15; Lineup = "all_races" }
    @{ Scene = "battle"; Landscape = $true;  Lineup = "all_races" }
    @{ Scene = "battle"; Landscape = $true;  Lineup = "undead_vs_human" }
    @{ Scene = "battle"; Landscape = $false; Lineup = "all_races" }
    @{ Scene = "battle"; Landscape = $false; Lineup = "undead_vs_human" }
)

$failed = @()
$index = 0
foreach ($take in $takes) {
    $index++
    $label = "$($take.Scene)/$(if ($take.Lineup) { $take.Lineup } else { '-' })/$(if ($take.Landscape) { '16:9' } else { '9:16' })"
    Write-Host ""
    Write-Host "=== [$index/$($takes.Count)] $label ==="
    $splat = @{ Scene = $take.Scene; Root = $Root; Fps = $Fps }
    if ($take.Lineup) { $splat["Lineup"] = $take.Lineup }
    if ($take.Seconds) { $splat["Seconds"] = $take.Seconds }
    if ($take.Landscape) { $splat["Landscape"] = $true }
    try {
        & $capture @splat
        if ($LASTEXITCODE -ne 0) { throw "capture exited $LASTEXITCODE" }
    } catch {
        Write-Warning "FAILED: $label - $_"
        $failed += $label
    }
}

Write-Host ""
Write-Host "=== batch done: $($takes.Count - $failed.Count)/$($takes.Count) succeeded ==="
if ($failed.Count -gt 0) {
    Write-Host "failed takes:"
    $failed | ForEach-Object { Write-Host "  $_" }
}
Get-ChildItem -Path (Join-Path $Root "clips") -Filter "*.mp4" | ForEach-Object {
    Write-Host ("  {0}  ({1} MB)" -f $_.Name, [math]::Round($_.Length / 1MB, 1))
}
