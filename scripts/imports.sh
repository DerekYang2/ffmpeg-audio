#!/usr/bin/env bash
# Lists the DLLs each built ffmpeg.exe imports. A static build should only need Windows' own DLLs.
set -euo pipefail
for exe in /work/dist/*/ffmpeg.exe; do
    echo "$exe:"
    llvm-readobj --coff-imports "$exe" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/Ip' | sort -fu | tr '\n' ' '
    echo
done
