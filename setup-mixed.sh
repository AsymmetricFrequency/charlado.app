#!/bin/bash
set -euo pipefail

if [[ ! -x /opt/homebrew/bin/whisper-cli && ! -x /usr/local/bin/whisper-cli ]]; then
    printf '%s\n' 'Instala whisper.cpp con brew install whisper-cpp y vuelve a ejecutar este script.' >&2
    exit 1
fi

directory="$HOME/Library/Application Support/Charlado/Models"
model="$directory/ggml-base-q5_1.bin"
checksum=422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898
mkdir -p "$directory"
matches() {
    printf '%s  %s\n' "$checksum" "$1" | shasum -a 256 -c --status
}
if [[ -f "$model" ]] && matches "$model"; then
    printf '%s\n' 'El modelo mixto ya está instalado.'
    exit 0
fi
temporary=$(mktemp "$directory/.download.XXXXXXXX")
trap 'unlink "$temporary" 2>/dev/null || true' EXIT
curl -fL --retry 2 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin -o "$temporary"
matches "$temporary" || { printf '%s\n' 'El archivo descargado no coincide con la suma esperada.' >&2; exit 1; }
mv "$temporary" "$model"
printf '%s\n' 'Modelo instalado. Selecciona Mixto ES + EN en Charlado.'
