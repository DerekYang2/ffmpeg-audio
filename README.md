# ffmpeg-audio

An audio-only build of FFmpeg for Windows, for [FluentDL](https://github.com/DerekYang2/FluentDL) and FluentSpek. It has the formats, codecs and filters those two apps use and nothing else, so `ffmpeg.exe` is about 8 MB instead of the 130 MB of a full build.

| | x64 | ARM64 |
| --- | --- | --- |
| `ffmpeg.exe` | 8.2 MB | 6.7 MB |
| Zip | 3.8 MB | 3.5 MB |

The exe is linked statically. It needs only DLLs that ship with Windows 10 and 11: the Universal C Runtime, `kernel32`, `shell32` and `bcrypt`.

## What's in it

FFmpeg 9.0.2 with Fraunhofer FDK AAC 2.0.3, LAME 3.100, Opus 1.5.2, libvorbis 1.3.7, libogg 1.3.6 and zlib 1.3.2.

- **Reading:** AAC, ALAC, FLAC, MP1, MP2 and MP3, Opus, Vorbis, WavPack, Monkey's Audio, TAK, TTA, Musepack, WMA (including Pro and Lossless), AC-3 and E-AC-3, DTS, TrueHD and MLP, DSD, TwinVQ, and PCM. The containers are MP4 and M4A, Matroska and WebM, Ogg, WAV and Wave64, AIFF, CAF, ASF, DSF and DSDIFF, Audible AA, and the raw formats of those codecs. Cover art in JPEG, PNG and BMP.
- **Writing:** FLAC, ALAC, AAC (`libfdk_aac` and FFmpeg's `aac`), MP3 (`libmp3lame`), Vorbis (`libvorbis`), Opus (`libopus`), PCM WAV, and PNG for cover art and spectrograms. The containers are FLAC, MP3, M4A and MP4, Ogg and Opus, WAV, Matroska and WebM, ADTS, raw 32-bit float, and images.
- **Filters:** resampling and sample format conversion, `pan`, `showspectrumpic`, `atrim`, `volume` and `amix`, and the `aevalsrc`, `sine`, `anoisesrc` and `anullsrc` sources the apps' tests use.

`build.sh` lists every component with what needs it. There's no video encoding or decoding apart from cover art, no network access, and no `ffprobe` or `ffplay`.

## Building

You need Docker. On Windows:

```powershell
.\build.ps1                     # x64 and ARM64
.\build.ps1 -Architecture x64
```

The zips land in `dist\`. `build.ps1` builds the image in `Dockerfile`, which is Ubuntu with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) for cross-compiling to both architectures, and runs `build.sh` in it. The source tarballs are downloaded once into `.cache\sources` and checked against the SHA-256 hashes in `versions.sh`. A build takes about 2 minutes per architecture.

To change what's included, edit `FFMPEG_COMPONENTS` in `build.sh`. The build stops if a name isn't an FFmpeg component, and `CHECK_ONLY=1` runs just that check:

```powershell
docker run --rm -v "${PWD}:/work" -e BUILD_DIR=/tmp/build -e CHECK_ONLY=1 ffmpeg-audio-build bash /work/build.sh x64
```

## Testing

`test.ps1` runs the ffmpeg commands FluentDL and FluentSpek use and checks that every output decodes again, and that conversions keep the cover art:

```powershell
pwsh .\test.ps1 -Ffmpeg dist\ffmpeg-9.0.2-audio-win-x64\ffmpeg.exe -Reference C:\path\to\full\ffmpeg.exe
```

The reference is any full ffmpeg build. The test uses it to make inputs this build can't write, such as WMA, AC-3, WavPack and files with cover art. CI runs the test on x64. The ARM64 build is only compiled there, because GitHub's x64 runners can't run ARM64 programs.

FluentDL's Vorbis and Opus conversions need `-vn` with this build. Without it, a source with cover art makes ffmpeg encode the cover as a Theora video stream in the Ogg file. A full build does that without complaint, and this one has no Theora encoder.

## Releases

Pushing a tag such as `v9.0.2-1` builds both architectures, tests x64, and attaches the zips to a GitHub release.

## Licenses

The build is LGPL 2.1 or later, because it includes no GPL parts. Each zip has the licenses of FFmpeg and every library in `licenses\`, and `BUILD.txt` with the versions, source links and FFmpeg's configure options.

FDK AAC is under Fraunhofer's own license. It allows free redistribution in source and binary form, but grants no patent rights. FFmpeg's configure only treats FDK AAC as "nonfree" in GPL builds, so this build doesn't need `--enable-nonfree`.

The FFmpeg, FDK AAC and library sources are the tarballs in `versions.sh`, unmodified except for two build fixes in `build.sh`: LAME's `config.sub` is replaced with a current one, and `lame_init_old` is removed from LAME's export list.
