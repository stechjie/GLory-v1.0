[CmdletBinding()]
param([string]$ProxyUrl = '')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Get-Content -LiteralPath (Join-Path $repo 'addons/glory_speech/runtime.json') -Raw | ConvertFrom-Json
$work = Join-Path $repo 'build/whisper-setup'
$destination = Join-Path $repo 'addons/glory_speech/bin/windows'
New-Item -ItemType Directory -Force -Path $work,$destination | Out-Null

function Download-Verified([string]$Url, [string]$Target, [string]$Expected) {
    if ((Test-Path -LiteralPath $Target) -and (Get-FileHash -LiteralPath $Target).Hash -eq $Expected) { return }
    $args = @{Uri=$Url;OutFile=($Target+'.download');TimeoutSec=300;UseBasicParsing=$true}
    if ($ProxyUrl) { $args.Proxy=$ProxyUrl }
    Invoke-WebRequest @args
    if ((Get-FileHash -LiteralPath ($Target+'.download')).Hash -ne $Expected) { throw "SHA256 mismatch: $Target" }
    Move-Item -LiteralPath ($Target+'.download') -Destination $Target -Force
}

$archive = Join-Path $work ('whisper-'+$manifest.version+'-x64.zip')
Download-Verified $manifest.archive_url $archive $manifest.archive_sha256
Download-Verified $manifest.model_url (Join-Path $destination 'ggml-base-q5_1.bin') $manifest.model_sha256
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($property in $manifest.files.PSObject.Properties) {
        $name=$property.Name
        $target=Join-Path $destination $name
        if ($name -eq 'ggml-base-q5_1.bin') { continue }
        if ($name -like 'LICENSE-*') {
            $url = if($name -eq 'LICENSE-whisper.txt') {
                'https://raw.githubusercontent.com/ggml-org/whisper.cpp/d1be6fde11ac6e0407606b4e42fe72d34add8037/LICENSE'
            } else { 'https://raw.githubusercontent.com/openai/whisper/v20250625/LICENSE' }
            Download-Verified $url $target $property.Value
        } elseif ($name -in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
            Copy-Item -LiteralPath (Join-Path $repo ('addons/glory_voice/bin/windows/'+$name)) -Destination $target -Force
        } else {
            $entry=$zip.GetEntry('Release/'+$name)
            if ($null -eq $entry) { throw "Missing archive input: $name" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)
        }
        if ((Get-FileHash -LiteralPath $target).Hash -ne $property.Value) { throw "SHA256 mismatch: $name" }
    }
} finally { $zip.Dispose() }
Write-Output ('Windows offline speech ready: '+$destination)
