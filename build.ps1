# Builds ffmpeg.exe in Docker. Results go to dist\.
#   .\build.ps1                     x64 and ARM64
#   .\build.ps1 -Architecture x64
param(
    [ValidateSet('x64', 'arm64')]
    [string[]] $Architecture = @('x64', 'arm64')
)

$ErrorActionPreference = 'Stop'

docker build -t ffmpeg-audio-build $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }

foreach ($arch in $Architecture) {
    docker run --rm -v "${PSScriptRoot}:/work" -e BUILD_DIR=/tmp/build ffmpeg-audio-build bash /work/build.sh $arch
    if ($LASTEXITCODE -ne 0) { throw "The $arch build failed" }
}
