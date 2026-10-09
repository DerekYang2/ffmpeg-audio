# Runs the ffmpeg commands FluentDL and FluentSpek use against a build, and checks each output decodes. Needs PowerShell 7.
#   pwsh .\test.ps1 -Ffmpeg dist\ffmpeg-9.0.2-audio-win-x64\ffmpeg.exe [-Reference C:\path\to\full\ffmpeg.exe]
# The reference ffmpeg, a full build, makes the input files this build can't write, such as WMA, AC-3 and WavPack.
# Without one, those inputs are skipped.
#Requires -Version 7
param(
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [string] $Reference
)

$ErrorActionPreference = 'Stop'
$Ffmpeg = (Resolve-Path $Ffmpeg).Path
if (-not $Reference) {
    $Reference = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -ne $Ffmpeg } | Select-Object -First 1).Source
}
$work = Join-Path ([IO.Path]::GetTempPath()) "ffmpeg-audio-test-$PID"
New-Item -ItemType Directory $work -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Ffmpeg([string] $exe, [string[]] $arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.RedirectStandardError = $true
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    foreach ($a in @('-hide_banner', '-nostdin', '-y') + $arguments) { $info.ArgumentList.Add($a) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout.Wait()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stderr = $stderr.Result }
}

function Get-AudioCodec([string] $file) {
    $probe = Invoke-Ffmpeg $Ffmpeg @('-i', $file)
    if ($probe.Stderr -match 'Stream #0:\d+\S*: Audio: (\w+)') { $Matches[1] } else { $null }
}

# Runs one command with the build under test. A non-zero exit fails the test. Audio outputs must decode again with the
# same build, and their codec must match ExpectCodec when it's given. With ExpectCover, the output must keep the cover.
function Test-Command([string] $name, [string[]] $arguments, [string] $output, [string] $expectCodec, [switch] $ExpectCover) {
    $run = Invoke-Ffmpeg $Ffmpeg $arguments
    $problem = $null
    if ($run.ExitCode -ne 0) {
        $problem = ($run.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    }
    elseif ($output -and (-not (Test-Path $output) -or (Get-Item $output).Length -eq 0)) {
        $problem = 'no output'
    }
    elseif ($expectCodec) {
        $codec = Get-AudioCodec $output
        if ($codec -ne $expectCodec) { $problem = "codec is $codec, expected $expectCodec" }
        elseif ((Invoke-Ffmpeg $Ffmpeg @('-v', 'error', '-i', $output, '-map', '0:a', '-f', 'null', '-')).ExitCode -ne 0) {
            $problem = "the output doesn't decode"
        }
        elseif ($ExpectCover -and (Invoke-Ffmpeg $Ffmpeg @('-i', $output)).Stderr -notmatch 'Video: \w+.*\(attached pic\)') {
            $problem = 'the cover art is missing'
        }
    }
    $results.Add([pscustomobject]@{ Test = $name; Result = $(if ($problem) { "FAIL: $problem" } else { 'ok' }) })
}

function New-Input([string] $name, [string[]] $arguments, [switch] $NeedsReference) {
    $path = Join-Path $work $name
    $exe = if ($NeedsReference) { $Reference } else { $Ffmpeg }
    if (-not $exe) { return $null }
    $run = Invoke-Ffmpeg $exe (@('-loglevel', 'error') + $arguments + @($path))
    if ($run.ExitCode -ne 0) { throw "Couldn't make $name with $exe`n$($run.Stderr)" }
    $path
}

function Out([string] $name) { Join-Path $work $name }

# A JPEG cover, drawn with .NET because this build has no image sources.
Add-Type -AssemblyName System.Drawing
$coverPath = Join-Path $work 'cover.jpg'
$bitmap = [Drawing.Bitmap]::new(300, 300)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([Drawing.Color]::SteelBlue)
$graphics.FillEllipse([Drawing.Brushes]::Orange, 50, 50, 200, 200)
$bitmap.Save($coverPath, [Drawing.Imaging.ImageFormat]::Jpeg)
$graphics.Dispose(); $bitmap.Dispose()

# Inputs this build can make itself, with the commands the projects' tests use.
$tone = 'aevalsrc=0.4*sin(2*PI*1000*t)|0.4*sin(2*PI*5000*t):s=44100:d=4'
$flac = New-Input 'tone.flac' @('-f', 'lavfi', '-i', $tone, '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-metadata', 'title=Tone', '-metadata', 'album=Tests')
$wav16 = New-Input 'tone.wav' @('-f', 'lavfi', '-i', $tone, '-c:a', 'pcm_s16le')
New-Input 'gen.mp3' @('-f', 'lavfi', '-i', $tone, '-c:a', 'libmp3lame', '-b:a', '320k') | Out-Null
New-Input 'gen.m4a' @('-f', 'lavfi', '-i', $tone, '-c:a', 'aac', '-b:a', '256k') | Out-Null
New-Input 'gen.opus' @('-f', 'lavfi', '-i', $tone, '-c:a', 'libopus', '-b:a', '192k') | Out-Null
New-Input 'gen.webm' @('-f', 'lavfi', '-i', $tone, '-c:a', 'libopus') | Out-Null
New-Input 'surround.flac' @('-f', 'lavfi', '-i', 'aevalsrc=0.1*sin(2*PI*440*t)|0.1*sin(2*PI*550*t)|0.1*sin(2*PI*660*t)|0.1*sin(2*PI*50*t)|0.1*sin(2*PI*770*t)|0.1*sin(2*PI*880*t):c=5.1:s=48000:d=3', '-c:a', 'flac') | Out-Null
New-Input 'two.mka' @('-f', 'lavfi', '-i', 'sine=f=440:d=2', '-f', 'lavfi', '-i', 'sine=f=3000:d=2', '-map', '0', '-map', '1', '-c:a', 'flac') | Out-Null
New-Input 'noise.flac' @('-f', 'lavfi', '-i', 'anoisesrc=d=3:r=44100', '-c:a', 'flac') | Out-Null
$results.Add([pscustomobject]@{ Test = 'make test inputs with lavfi (FluentDL and Spek.NET tests)'; Result = 'ok' })

# Inputs only a full build can make: other codecs and containers, and files with cover art.
$inputs = [ordered]@{ 'tone.flac' = $flac; 'tone.wav' = $wav16 }
if ($Reference) {
    $src = @('-i', $wav16)
    $withCover = @('-i', $wav16, '-i', $coverPath, '-map', '0', '-map', '1', '-c:v', 'copy', '-disposition:v', 'attached_pic')
    $inputs['cover.flac'] = New-Input 'cover.flac' ($withCover + @('-c:a', 'flac')) -NeedsReference
    $inputs['cover.mp3'] = New-Input 'cover.mp3' ($withCover + @('-c:a', 'libmp3lame', '-b:a', '256k', '-id3v2_version', '3')) -NeedsReference
    $inputs['cover.m4a'] = New-Input 'cover.m4a' ($withCover + @('-c:a', 'aac', '-b:a', '192k')) -NeedsReference
    $inputs['alac.m4a'] = New-Input 'alac.m4a' ($src + @('-c:a', 'alac')) -NeedsReference
    $inputs['youtube.mp4'] = New-Input 'youtube.mp4' ($src + @('-c:a', 'aac', '-b:a', '128k')) -NeedsReference
    $inputs['youtube.webm'] = New-Input 'youtube.webm' ($src + @('-c:a', 'libopus', '-b:a', '160k')) -NeedsReference
    $inputs['vorbis.ogg'] = New-Input 'vorbis.ogg' ($src + @('-c:a', 'libvorbis')) -NeedsReference
    $inputs['wma.wma'] = New-Input 'wma.wma' ($src + @('-c:a', 'wmav2', '-b:a', '192k')) -NeedsReference
    $inputs['ac3.ac3'] = New-Input 'ac3.ac3' ($src + @('-c:a', 'ac3')) -NeedsReference
    $inputs['eac3.eac3'] = New-Input 'eac3.eac3' ($src + @('-c:a', 'eac3')) -NeedsReference
    $inputs['dts.dts'] = New-Input 'dts.dts' ($src + @('-c:a', 'dca', '-strict', '-2')) -NeedsReference
    $inputs['mp2.mp2'] = New-Input 'mp2.mp2' ($src + @('-c:a', 'mp2')) -NeedsReference
    $inputs['wavpack.wv'] = New-Input 'wavpack.wv' ($src + @('-c:a', 'wavpack')) -NeedsReference
    $inputs['tta.tta'] = New-Input 'tta.tta' ($src + @('-c:a', 'tta')) -NeedsReference
    $inputs['aiff.aiff'] = New-Input 'aiff.aiff' ($src + @('-c:a', 'pcm_s16be')) -NeedsReference
    $inputs['adts.aac'] = New-Input 'adts.aac' ($src + @('-c:a', 'aac')) -NeedsReference
    $inputs['caf.caf'] = New-Input 'caf.caf' ($src + @('-c:a', 'alac')) -NeedsReference
    $inputs['truehd.mka'] = New-Input 'truehd.mka' ($src + @('-c:a', 'truehd', '-strict', '-2')) -NeedsReference
}
else {
    $results.Add([pscustomobject]@{ Test = 'inputs that need a full reference ffmpeg'; Result = 'skipped: no reference ffmpeg' })
}

# Reading every input: Spek.NET's probe and decode, and FluentDL's ReplayGain decode.
foreach ($name in $inputs.Keys) {
    $file = $inputs[$name]
    if (-not $file) { continue }
    Test-Command "Spek.NET decode: $name" @('-v', 'error', '-i', $file, '-map', '0:a:0', '-af', 'pan=mono|c0=c0', '-f', 'f32le', '-acodec', 'pcm_f32le', (Out "$name.f32")) (Out "$name.f32")
    Test-Command "ReplayGain decode: $name" @('-loglevel', 'error', '-i', $file, '-vn', '-sn', '-dn', '-map_metadata', '-1', '-fflags', '+bitexact', '-c:a', 'pcm_f32le', '-f', 'wav', (Out "$name.rg.wav")) (Out "$name.rg.wav") 'pcm_f32le'
}
Test-Command 'Spek.NET decode: second stream of two.mka' @('-v', 'error', '-i', (Out 'two.mka'), '-map', '0:a:1', '-af', 'pan=mono|c0=c0', '-f', 'f32le', '-acodec', 'pcm_f32le', (Out 'two-1.f32')) (Out 'two-1.f32')
Test-Command 'Spek.NET decode: channel 6 of surround.flac' @('-v', 'error', '-i', (Out 'surround.flac'), '-map', '0:a:0', '-af', 'pan=mono|c0=c5', '-f', 'f32le', '-acodec', 'pcm_f32le', (Out 'surround-5.f32')) (Out 'surround-5.f32')
$descriptions = & $Ffmpeg -hide_banner -decoders 2>$null
$results.Add([pscustomobject]@{ Test = 'Spek.NET codec descriptions (-decoders)'; Result = $(if ($descriptions -match 'FLAC \(Free Lossless Audio Codec\)') { 'ok' } else { 'FAIL: no FLAC description' }) })

# FluentDL's conversions, with the arguments FFmpegRunner passes. AAC uses FDK, as FluentDL will once its argument
# order is fixed.
$sources = @('tone.flac', 'cover.flac', 'cover.mp3', 'cover.m4a', 'youtube.webm', 'wma.wma') | Where-Object { $inputs[$_] }
foreach ($name in $sources) {
    $in = $inputs[$name]
    $base = [IO.Path]::GetFileNameWithoutExtension($name) + '-' + [IO.Path]::GetExtension($name).TrimStart('.')
    $cover = @{ ExpectCover = $name -like 'cover.*' }
    Test-Command "CreateFlac: $name" @('-i', $in, '-c:v', 'copy', '-map_metadata', '0', (Out "$base.out.flac")) (Out "$base.out.flac") 'flac' @cover
    Test-Command "CreateMp3 VBR: $name" @('-i', $in, '-c:a', 'libmp3lame', '-q:a', '0', '-c:v', 'copy', '-map_metadata', '0', '-id3v2_version', '3', (Out "$base.vbr.mp3")) (Out "$base.vbr.mp3") 'mp3' @cover
    Test-Command "CreateMp3 320k: $name" @('-i', $in, '-c:a', 'libmp3lame', '-b:a', '320k', '-c:v', 'copy', '-map_metadata', '0', '-id3v2_version', '3', (Out "$base.cbr.mp3")) (Out "$base.cbr.mp3") 'mp3' @cover
    Test-Command "CreateMp3 without -c:v copy: $name" @('-i', $in, '-c:a', 'libmp3lame', '-q:a', '0', '-map_metadata', '0', '-id3v2_version', '3', (Out "$base.nocopy.mp3")) (Out "$base.nocopy.mp3") 'mp3' @cover
    Test-Command "CreateAac FDK 256k: $name" @('-i', $in, '-c:v', 'copy', '-c:a', 'libfdk_aac', '-map_metadata', '0', '-b:a', '256k', (Out "$base.fdk.m4a")) (Out "$base.fdk.m4a") 'aac' @cover
    Test-Command "CreateAac native 128k: $name" @('-i', $in, '-c:v', 'copy', '-c:a', 'aac', '-map_metadata', '0', '-b:a', '128k', (Out "$base.aac.m4a")) (Out "$base.aac.m4a") 'aac' @cover
    Test-Command "CreateAlac: $name" @('-i', $in, '-c:v', 'copy', '-map_metadata', '0', '-c:a', 'alac', (Out "$base.alac.m4a")) (Out "$base.alac.m4a") 'alac' @cover
    # FluentDL's Vorbis and Opus commands need -vn. Without it, a source with cover art makes ffmpeg encode the cover as
    # a Theora video stream in the Ogg file, which a full build does quietly and this build can't.
    Test-Command "CreateVorbisVBR: $name" @('-i', $in, '-vn', '-c:a', 'libvorbis', '-q:a', '5', '-map_metadata', '0', (Out "$base.vbr.ogg")) (Out "$base.vbr.ogg") 'vorbis'
    Test-Command "CreateVorbis 192k: $name" @('-i', $in, '-vn', '-c:a', 'libvorbis', '-map_metadata', '0', '-b:a', '192k', (Out "$base.cbr.ogg")) (Out "$base.cbr.ogg") 'vorbis'
    Test-Command "CreateOpus 128k: $name" @('-i', $in, '-vn', '-c:a', 'libopus', '-vbr', 'on', '-frame_duration', '60', '-b:a', '128k', (Out "$base.opus.ogg")) (Out "$base.opus.ogg") 'opus'
    Test-Command "ConvertToFlac 44.1 kHz s16: $name" @('-i', $in, '-sample_fmt', 's16', '-ar', '44100', (Out "$base.s16.flac")) (Out "$base.s16.flac") 'flac'
}

# FluentDL's download paths.
if ($inputs['youtube.mp4']) {
    Test-Command 'ConvertMp4ToM4a (copy)' @('-i', $inputs['youtube.mp4'], '-c', 'copy', '-map', '0:a:0', (Out 'yt.m4a')) (Out 'yt.m4a') 'aac'
}
if ($inputs['youtube.webm']) {
    Test-Command 'ConvertWebmToOpus (copy)' @('-i', $inputs['youtube.webm'], '-c', 'copy', '-map', '0:a:0', (Out 'yt.opus')) (Out 'yt.opus') 'opus'
    Test-Command 'ConvertWebmToFlac' @('-i', $inputs['youtube.webm'], '-c:a', 'flac', '-map', '0:a:0', (Out 'yt.flac')) (Out 'yt.flac') 'flac'
    Test-Command 'RemuxOpus (copy)' @('-i', $inputs['youtube.webm'], '-c', 'copy', (Out 'yt-remux.opus')) (Out 'yt-remux.opus') 'opus'
    Test-Command 'Opus to FLAC at 48 kHz (Spotify path)' @('-i', (Out 'yt.opus'), '-sample_fmt', 's16', '-ar', '48000', (Out 'yt48.flac')) (Out 'yt48.flac') 'flac'
}
if ($inputs['adts.aac']) {
    Test-Command 'ADTS AAC copied into M4A' @('-i', $inputs['adts.aac'], '-c', 'copy', (Out 'adts.m4a')) (Out 'adts.m4a') 'aac'
}

# FluentDL's current spectrogram dialog.
Test-Command 'showspectrumpic to PNG pipe' @('-i', $flac, '-filter_complex', 'showspectrumpic=s=1024x512', '-c:v', 'png', '-f', 'image2pipe', (Out 'spectrum-pipe.png')) (Out 'spectrum-pipe.png')
Test-Command 'showspectrumpic to PNG file' @('-i', $flac, '-filter_complex', 'showspectrumpic=s=2048x1024', '-c:v', 'png', '-f', 'image2', (Out 'spectrum.png')) (Out 'spectrum.png')

$failed = @($results | Where-Object { $_.Result -like 'FAIL*' })
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
"{0} passed, {1} failed, {2} skipped" -f @($results | Where-Object Result -eq 'ok').Count, $failed.Count, @($results | Where-Object { $_.Result -like 'skipped*' }).Count
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($failed.Count -gt 0) { exit 1 }
