#!/bin/zsh
# Builds Lightbox in Release for Apple silicon, installs it, replacing any earlier copy, then launches it.
# The Core ML models must exist first (tools/build-models.sh, once).
#
#   scripts/release.sh                 # installs to /Applications
#   scripts/release.sh ~/Applications  # or another folder
#   scripts/release.sh --no-launch     # install without starting it
#   scripts/release.sh --zip           # also write build/Lightbox-<version>.zip, e.g. to copy to another Mac
set -euo pipefail

cd "${0:A:h}/.."

dest=/Applications
launch=1
zip=0
for arg in "$@"; do
    case $arg in
        --no-launch) launch=0 ;;
        --zip) zip=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) dest=${arg%/} ;;
    esac
done

[[ -d $dest ]] || { echo "No such folder: $dest" >&2; exit 1; }
[[ -w $dest ]] || { echo "Cannot write to $dest" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
for model in BiRefNet_HR_2048 BiRefNet_HR_Matting_2048 ViTMatte_Base_1024 Nomos2_DAT2_x4 BHI_DAT2_Real_x4 RealESRGAN_x4; do
    [[ -d Lightbox/Models/$model.mlpackage ]] || { echo "Missing Lightbox/Models/$model.mlpackage: run tools/build-models.sh first" >&2; exit 1; }
done

echo "› Generating project"
xcodegen generate --quiet

echo "› Building Release"
log=build/release.log
mkdir -p build
if ! xcodebuild -project Lightbox.xcodeproj -scheme Lightbox -configuration Release \
        -derivedDataPath build -destination 'platform=macOS,arch=arm64' build >"$log" 2>&1; then
    grep -E "error:" "$log" >&2 || tail -30 "$log" >&2
    echo "Build failed; full log in $log" >&2
    exit 1
fi
app=build/Build/Products/Release/Lightbox.app
codesign --verify --deep "$app"
archs=$(lipo -archs "$app/Contents/MacOS/Lightbox")
[[ $archs == arm64 ]] || { echo "Expected an Apple silicon (arm64) binary, got: $archs" >&2; exit 1; }

if pgrep -xq Lightbox; then
    echo "› Quitting the running Lightbox"
    osascript -e 'tell application id "com.stormbuster.lightbox" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Lightbox || break; sleep 0.25; done
    pkill -x Lightbox 2>/dev/null || true
fi

echo "› Installing to $dest/Lightbox.app"
rm -rf "$dest/Lightbox.app"
ditto "$app" "$dest/Lightbox.app"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/Lightbox.app/Contents/Info.plist")
echo "✓ Lightbox $version ($archs) installed ($(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ':!build' || echo ', with uncommitted changes'))"

if (( zip )); then
    archive="build/Lightbox-$version.zip"
    rm -f "$archive"
    ditto -c -k --keepParent "$app" "$archive"
    echo "✓ $archive ($(du -h "$archive" | cut -f1))"
fi

if (( launch )); then
    open "$dest/Lightbox.app"
    echo "✓ Launched"
fi
