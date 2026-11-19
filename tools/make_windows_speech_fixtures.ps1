# Synthetic audio for the offline recognition integration check. No microphone is opened.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$directory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build/whisper-setup'))
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Mono)
foreach ($locale in @('zh','en')) {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $voice = $synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name.StartsWith($locale) } | Select-Object -First 1
        if ($null -eq $voice) { throw "Install a Windows TTS voice for fixture language: $locale" }
        $synth.SelectVoice($voice.VoiceInfo.Name)
        $synth.SetOutputToWaveFile((Join-Path $directory ($locale+'.wav')),$format)
        $sentence = if ($locale -eq 'zh') {
            # Unicode code points keep this script compatible with Windows PowerShell 5.1.
            -join ([char[]]@(0x5927,0x5BB6,0x597D,0xFF0C,0x6211,0x4EEC,0x4E00,0x8D77,0x5F00,0x59CB,0x6E38,0x620F,0x3002))
        } else { 'Hello team, let us play together.' }
        $synth.Speak($sentence)
    } finally { $synth.Dispose() }
}
Write-Output ('Speech fixtures ready: '+$directory)
