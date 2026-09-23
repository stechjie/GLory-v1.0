param(
    [string]$SourceRoot = "C:\Users\Leno\Desktop\vfx 1.0",
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

$outputRoot = Join-Path $ProjectRoot "assets\vfx\oga"
foreach ($directory in @($outputRoot, "$outputRoot\projectiles", "$outputRoot\impacts", "$outputRoot\melee", "$outputRoot\skills")) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
$manifest = [System.Collections.Generic.List[object]]::new()

function New-NumberedNames {
    param([string]$Prefix, [int]$First, [int]$Last, [int]$Digits = 2, [string]$Suffix = ".png")
    $result = @()
    for ($index = $First; $index -le $Last; $index++) {
        $result += $Prefix + $index.ToString("D$Digits") + $Suffix
    }
    return $result
}

function Read-ZipFrames {
    param([string]$ZipRelativePath, [string[]]$EntryNames)
    $zipPath = Join-Path $SourceRoot $ZipRelativePath
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $frames = [System.Collections.Generic.List[System.Drawing.Bitmap]]::new()
    try {
        foreach ($entryName in $EntryNames) {
            $entry = $archive.GetEntry($entryName)
            if ($null -eq $entry) { throw "Missing ZIP entry: $ZipRelativePath :: $entryName" }
            $stream = $entry.Open()
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try { $frames.Add([System.Drawing.Bitmap]::new($image)) }
                finally { $image.Dispose() }
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    return ,$frames.ToArray()
}

function Save-Atlas {
    param(
        [string]$Id, [System.Drawing.Bitmap[]]$Frames, [string]$RelativeOutput,
        [int]$Columns, [int]$CellWidth, [int]$CellHeight, [string]$SourcePack,
        [string[]]$SourceEntries, [string]$Use = "preview"
    )
    if ($Frames.Count -eq 0) { throw "Atlas $Id has no frames" }
    $frameCount = $Frames.Count
    $rows = [int][Math]::Ceiling($frameCount / [double]$Columns)
    $atlas = [System.Drawing.Bitmap]::new($Columns * $CellWidth, $rows * $CellHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($atlas)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        for ($index = 0; $index -lt $frameCount; $index++) {
            $frame = $Frames[$index]
            $scale = [Math]::Min(($CellWidth - 8.0) / $frame.Width, ($CellHeight - 8.0) / $frame.Height)
            $width = [Math]::Max(1, [int][Math]::Round($frame.Width * $scale))
            $height = [Math]::Max(1, [int][Math]::Round($frame.Height * $scale))
            $column = $index % $Columns
            $row = [int][Math]::Floor($index / [double]$Columns)
            $x = $column * $CellWidth + [int](($CellWidth - $width) / 2)
            $y = $row * $CellHeight + [int](($CellHeight - $height) / 2)
            $graphics.DrawImage($frame, $x, $y, $width, $height)
        }
        $destination = Join-Path $outputRoot $RelativeOutput
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $atlas.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $atlas.Dispose()
        foreach ($frame in $Frames) { $frame.Dispose() }
    }
    $manifest.Add([ordered]@{
        id = $Id
        path = "res://assets/vfx/oga/" + ($RelativeOutput -replace "\\", "/")
        columns = $Columns
        rows = $rows
        frame_count = $frameCount
        cell = @($CellWidth, $CellHeight)
        source_pack = $SourcePack
        source_entries = $SourceEntries
        license = "CC0"
        attribution_required = $false
        integration = $Use
    })
}

function Save-ZipAtlas {
    param(
        [string]$Id, [string]$ZipRelativePath, [string[]]$EntryNames,
        [string]$RelativeOutput, [int]$Columns, [int]$CellWidth, [int]$CellHeight,
        [string]$SourcePack, [string]$Use = "preview"
    )
    $frames = Read-ZipFrames -ZipRelativePath $ZipRelativePath -EntryNames $EntryNames
    Save-Atlas -Id $Id -Frames $frames -RelativeOutput $RelativeOutput -Columns $Columns `
        -CellWidth $CellWidth -CellHeight $CellHeight -SourcePack $SourcePack `
        -SourceEntries $EntryNames -Use $Use
}

function Save-AtlasFile {
    param(
        [string]$Id, [string]$ZipRelativePath, [string]$EntryName,
        [string]$RelativeOutput, [int]$Columns, [int]$Rows,
        [int]$TargetWidth, [int]$TargetHeight, [string]$SourcePack, [string]$Use = "preview"
    )
    $frames = Read-ZipFrames -ZipRelativePath $ZipRelativePath -EntryNames @($EntryName)
    $source = $frames[0]
    $atlas = [System.Drawing.Bitmap]::new($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($atlas)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.DrawImage($source, 0, 0, $TargetWidth, $TargetHeight)
        $destination = Join-Path $outputRoot $RelativeOutput
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $atlas.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $atlas.Dispose()
        $source.Dispose()
    }
    $manifest.Add([ordered]@{
        id = $Id
        path = "res://assets/vfx/oga/" + ($RelativeOutput -replace "\\", "/")
        columns = $Columns
        rows = $Rows
        frame_count = $Columns * $Rows
        cell = @([int]($TargetWidth / $Columns), [int]($TargetHeight / $Rows))
        source_pack = $SourcePack
        source_entries = @($EntryName)
        license = "CC0"
        attribution_required = $false
        integration = $Use
    })
}

$lightZip = "04_light_magic\LightEffects.zip"
$pureZip = "09_pure_projectile\Pure Projectile Effect.zip"
$cosmicZip = "11_cosmic_time\Cosmic Time - Magic Effect.zip"
$earthZip = "12_earth_impact\Earth Impact - Magic Effect.zip"
$effects70Zip = "16_70_animated_effects\70_Effects.zip"
$bloodZip = "17_blood_magic\Blood - Magic Effect.zip"
$arcaneZip = "18_arcane_magic\Arcane_Effect.zip"
$natureZip = "19_nature_magic\Nature Magic Effect.zip"
$slashZip = "10_weapon_slash\Everything.zip"

# Twelve ranged pieces, twelve genuinely different source sequences.
Save-ZipAtlas "god_priest_star_lance" $lightZip (New-NumberedNames "LightEffect_" 21 25) "projectiles\god_priest_star_lance.png" 5 192 192 "Light - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_priestess_halo_disc" $lightZip (New-NumberedNames "LightEffect_" 16 20) "projectiles\god_priestess_halo_disc.png" 5 192 192 "Light - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_angel_wing" $pureZip (New-NumberedNames "Files/Pure_" 16 20) "projectiles\god_angel_wing.png" 5 192 192 "Pure Projectile - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_archangel_seraph_orb" $lightZip (New-NumberedNames "LightEffect_" 1 5) "projectiles\god_archangel_seraph_orb.png" 5 192 192 "Light - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_aurora_light_spear" $pureZip (New-NumberedNames "Files/Pure_" 11 15) "projectiles\god_aurora_light_spear.png" 5 192 192 "Pure Projectile - Magic Effect" "isolated_preview"
Save-ZipAtlas "dark_mage_arcane_skull" $arcaneZip (New-NumberedNames "04/Arcane_Effect_" 1 7 1) "projectiles\dark_mage_arcane_skull.png" 7 160 160 "Arcane Magic Effect" "isolated_preview"
Save-ZipAtlas "dark_queen_blood_thorn" $bloodZip (New-NumberedNames "Blood-Magic-Effect_" 6 10) "projectiles\dark_queen_blood_thorn.png" 5 192 192 "Blood - Magic Effect" "isolated_preview"
Save-ZipAtlas "human_archer_blue_wind_arrow" $slashZip (New-NumberedNames "Alternative 2/4/Alternative_2_" 19 24) "projectiles\human_archer_blue_wind_arrow.png" 6 160 176 "Weapon Slash - Effect" "isolated_preview"
Save-ZipAtlas "human_cleric_nature_seed" $natureZip (New-NumberedNames "3-" 1 5 1) "projectiles\human_cleric_nature_seed.png" 5 224 192 "Nature - Magic Effect" "isolated_preview"
Save-ZipAtlas "human_mage_arcane_satellites" $arcaneZip (New-NumberedNames "03/Arcane_Effect_" 1 7 1) "projectiles\human_mage_arcane_satellites.png" 7 160 160 "Arcane Magic Effect" "isolated_preview"
Save-ZipAtlas "undead_spike_bone_fan" $pureZip (New-NumberedNames "Files/Pure_" 6 10) "projectiles\undead_spike_bone_fan.png" 5 192 192 "Pure Projectile - Magic Effect" "isolated_preview"
Save-ZipAtlas "undead_mother_blood_lance" $bloodZip (New-NumberedNames "Blood-Magic-Effect_" 21 25) "projectiles\undead_mother_blood_lance.png" 5 192 192 "Blood - Magic Effect" "isolated_preview"

# Unique contact layers prevent twelve projectiles collapsing into one generic hit.
Save-ZipAtlas "god_priest_hit" $lightZip (New-NumberedNames "LightEffect_" 6 10) "impacts\god_priest_hit.png" 5 192 192 "Light - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_priestess_hit" $cosmicZip (New-NumberedNames "4/Cosmic_" 16 20) "impacts\god_priestess_hit.png" 5 192 192 "Cosmic Time - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_angel_hit" $pureZip (New-NumberedNames "Files/Pure_" 21 25) "impacts\god_angel_hit.png" 5 192 192 "Pure Projectile - Magic Effect" "isolated_preview"
Save-ZipAtlas "god_archangel_hit" $lightZip (New-NumberedNames "LightEffect_" 11 15) "impacts\god_archangel_hit.png" 5 192 192 "Light - Magic Effect" "isolated_preview"
Save-AtlasFile "god_aurora_hit" $effects70Zip "70_Effects/explosion7 (2).png" "impacts\god_aurora_hit.png" 4 4 512 512 "70 Animated 2D Game Effects!" "isolated_preview"
Save-ZipAtlas "dark_mage_hit" $arcaneZip (New-NumberedNames "06/Arcane_Effect_" 1 7 1) "impacts\dark_mage_hit.png" 7 160 160 "Arcane Magic Effect" "isolated_preview"
Save-ZipAtlas "dark_queen_hit" $bloodZip (New-NumberedNames "Blood-Magic-Effect_" 11 15) "impacts\dark_queen_hit.png" 5 192 192 "Blood - Magic Effect" "isolated_preview"
Save-AtlasFile "human_archer_hit" $effects70Zip "70_Effects/explosion32.png" "impacts\human_archer_hit.png" 4 4 512 512 "70 Animated 2D Game Effects!" "isolated_preview"
Save-ZipAtlas "human_cleric_hit" $natureZip (New-NumberedNames "1-" 1 7 1) "impacts\human_cleric_hit.png" 7 224 192 "Nature - Magic Effect" "isolated_preview"
Save-ZipAtlas "human_mage_hit" $arcaneZip (New-NumberedNames "05/Arcane_Effect_" 1 7 1) "impacts\human_mage_hit.png" 7 160 160 "Arcane Magic Effect" "isolated_preview"
Save-ZipAtlas "undead_spike_hit" $earthZip (New-NumberedNames "3/Earth-Impact_" 11 15) "impacts\undead_spike_hit.png" 5 192 192 "Earth Impact - Magic Effect" "isolated_preview"
Save-ZipAtlas "undead_mother_hit" $bloodZip (New-NumberedNames "Blood-Magic-Effect_" 16 20) "impacts\undead_mother_hit.png" 5 192 192 "Blood - Magic Effect" "isolated_preview"

# Isolated melee and skill approval candidates; none is connected to live combat.
Save-ZipAtlas "melee_god_gold_arc" $slashZip (New-NumberedNames "Classic/1/Classic_" 1 6) "melee\god_gold_arc.png" 6 160 176 "Weapon Slash - Effect" "isolated_preview"
Save-ZipAtlas "melee_human_blue_arc" $slashZip (New-NumberedNames "Alternative 2/2/Alternative_2_" 7 12) "melee\human_blue_arc.png" 6 160 176 "Weapon Slash - Effect" "isolated_preview"
Save-ZipAtlas "melee_dark_purple_arc" $slashZip (New-NumberedNames "Alternative 1/3/Alternative_1_" 13 18) "melee\dark_purple_arc.png" 6 160 176 "Weapon Slash - Effect" "isolated_preview"
Save-ZipAtlas "skill_angel_shield" "01_angel_shield\Angel Shield Effect.zip" (New-NumberedNames "AngelShieldEffect_" 1 20) "skills\angel_shield.png" 5 200 176 "Angel Shield Effect" "isolated_preview"
Save-ZipAtlas "skill_black_hole" $cosmicZip (New-NumberedNames "5/Cosmic_" 21 25) "skills\black_hole.png" 5 192 192 "Cosmic Time - Magic Effect" "isolated_preview"
Save-ZipAtlas "skill_earth_impact" $earthZip (New-NumberedNames "3/Earth-Impact_" 11 15) "skills\earth_impact.png" 5 192 192 "Earth Impact - Magic Effect" "isolated_preview"

[ordered]@{
    schema = "glory.oga_vfx_atlas_manifest/1"
    generated_from = $SourceRoot
    formal_battle_integration = $true
    entries = $manifest
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot "atlas_manifest.json") -Encoding utf8

Write-Host "Generated $($manifest.Count) OGA VFX atlases under $outputRoot"
Write-Host "Formal battle integration is enabled for approved player-chess routes."
