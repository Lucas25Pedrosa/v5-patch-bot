#!/bin/bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-/tmp}/nexus-build"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
THEOS_DIR="${THEOS:-${RUNNER_TEMP:-/tmp}/theos}"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "Preparing Nexus 1.0 PT-BR"

if [ -z "$TOKEN" ]; then
  echo "GH_TOKEN/GITHUB_TOKEN is required"
  exit 1
fi

# Enhancer 0.3.5 frozen sources.
curl -fsSL \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/blobs/636fea8908d802e4189e61fb292c9f42ad668973" \
  | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); sys.stdout.buffer.write(base64.b64decode(d["content"]))' \
  > "$WORK/EnhancerTweak.m"

curl -fsSL \
  "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/2b764e9afb118063d74260f51d1a65527f2e7845/iqface-enhancer-core-ptbr/Translation.m" \
  > "$WORK/Translation.m"

python3 "$ROOT/nexus/prepare_enhancer.py" "$WORK/EnhancerTweak.m" "$WORK/Translation.m"
cp "$ROOT/iqface-enhancer-wordmark-beta/WordmarkActivation.m" "$WORK/WordmarkActivation.m"
cp "$ROOT/iqface-enhancer-1.1/HideButton11.m" "$WORK/HideButton11.m"

# Cache 0.2.2 + Icons 1.1.0.
python3 "$ROOT/nexus/prepare_cache.py" "$ROOT/iqface-cache/Tweak.m" "$WORK/CacheTweak.m"
python3 "$ROOT/nexus/prepare_icons.py" "$ROOT/iqface-icons/Tweak.m" "$WORK/IconsTweak.m"
cp "$ROOT/iqface-icons/IconPicker.m" "$WORK/IconsPicker.m"

# OLED 0.2.5 validated PT-BR composition.
cp "$ROOT/iqface-oled/Tweak.m" "$WORK/Tweak.m"
(
  cd "$WORK"
  python3 "$ROOT/iqface-oled/prepare_oled.py"
  python3 "$ROOT/iqface-oled/prepare_separator.py"
  python3 "$ROOT/iqface-oled/finalize_020.py"
  python3 "$ROOT/iqface-oled/adapt_iqface11.py"
  python3 "$ROOT/iqface-oled/adapt_iqface11_native_icon_switches.py"
)
python3 "$ROOT/nexus/prepare_oled.py" "$WORK/Tweak.m" "$WORK/OLEDTweak.m"
rm "$WORK/Tweak.m"

cp "$ROOT/nexus/NexusSettings.m" "$WORK/NexusSettings.m"
python3 "$ROOT/nexus/prepare_makefile.py" "$ROOT/iqface-4in1/Makefile" "$WORK/Makefile"

# Preparation validation.
grep -F 'NexusVersion = @"1.0"' "$WORK/NexusSettings.m"
grep -F 'NexusCacheCreateManualSetting' "$WORK/CacheTweak.m"
grep -F 'NexusIconsCreateSetting' "$WORK/IconsTweak.m"
grep -F 'NexusOLEDCreateModeSetting' "$WORK/OLEDTweak.m"
grep -F '@"value": @0' "$WORK/CacheTweak.m"
grep -F 'staticCellWithTitle:subtitle:icon:' "$WORK/OLEDTweak.m"

# Compile the single Nexus library.
cd "$WORK"
make clean all FINALPACKAGE=1 THEOS="$THEOS_DIR"

ARTIFACTS="$ROOT/nexus/artifacts"
mkdir -p "$ARTIFACTS"
rm -f "$ARTIFACTS"/*
DYLIB_PATH="$(find .theos -type f -name Nexus.dylib -print -quit)"
test -n "$DYLIB_PATH"
cp "$DYLIB_PATH" "$ARTIFACTS/Nexus.dylib"
shasum -a 256 "$ARTIFACTS/Nexus.dylib" > "$ARTIFACTS/SHA256SUMS.txt"
file "$ARTIFACTS/Nexus.dylib" > "$ARTIFACTS/file.txt"
strings -a "$ARTIFACTS/Nexus.dylib" > "$ARTIFACTS/strings.txt" || true
otool -D "$ARTIFACTS/Nexus.dylib" > "$ARTIFACTS/install-name.txt"
otool -L "$ARTIFACTS/Nexus.dylib" > "$ARTIFACTS/dependencies.txt"

# Binary validation: Nexus identity and all four PT-BR modules.
grep -F 'Mach-O 64-bit' "$ARTIFACTS/file.txt"
grep -F 'arm64' "$ARTIFACTS/file.txt"
grep -F '@rpath/Nexus.dylib' "$ARTIFACTS/install-name.txt"
grep -F '1.1-core-ptbr' "$ARTIFACTS/strings.txt"
grep -F 'RECURSOS' "$ARTIFACTS/strings.txt"
grep -F 'Alterar ícone' "$ARTIFACTS/strings.txt"
grep -F 'IQFIconsPickerController' "$ARTIFACTS/strings.txt"
grep -F 'Modo OLED' "$ARTIFACTS/strings.txt"
grep -F 'Separadores no feed' "$ARTIFACTS/strings.txt"
grep -F 'FBLineComponentInternalView' "$ARTIFACTS/strings.txt"
grep -F 'Limpar cache' "$ARTIFACTS/strings.txt"
grep -F 'Limpar cache automaticamente' "$ARTIFACTS/strings.txt"
grep -F 'Diariamente' "$ARTIFACTS/strings.txt"
grep -F 'com.facebook.Facebook.MosaicIGImageDiskCache' "$ARTIFACTS/strings.txt"

echo "Nexus 1.0 PT-BR build completed"
