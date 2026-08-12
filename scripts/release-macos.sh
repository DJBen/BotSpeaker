#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
PUBLISH_GITHUB=false

if [[ "$VERSION" == "" ]]; then
    echo "Usage: $0 <major.minor.patch> [--publish-github]" >&2
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must use major.minor.patch, for example 0.1.0" >&2
    exit 1
fi

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish-github)
            PUBLISH_GITHUB=true
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
fi

for tool in xcodebuild xcrun security codesign spctl lipo shasum create-dmg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool is missing: $tool" >&2
        if [[ "$tool" == "create-dmg" ]]; then
            echo "Install it with: npm install --global create-dmg" >&2
        fi
        exit 1
    fi
done

DEVELOPER_ID_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ && /\(52RD2GH5DP\)/ {print $2; exit}')"
if [[ -z "$DEVELOPER_ID_IDENTITY" ]]; then
    echo "Error: no Developer ID Application certificate is installed in the login keychain." >&2
    echo "Create or import the certificate for Apple team 52RD2GH5DP, then retry." >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_PRIVATE_KEY_BASE64="${ASC_PRIVATE_KEY_BASE64:-}"

if [[ -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_ID" ]]; then
    echo "Error: ASC_KEY_ID and ASC_ISSUER_ID must be set in the environment or .env." >&2
    exit 1
fi

if [[ -n "$ASC_PRIVATE_KEY_BASE64" ]]; then
    KEY_DIRECTORY="$BUILD_DIR/private_keys"
    ASC_KEY_PATH="$KEY_DIRECTORY/AuthKey_${ASC_KEY_ID}.p8"
    mkdir -p "$KEY_DIRECTORY"
    chmod 700 "$KEY_DIRECTORY"
    if ! printf '%s' "$ASC_PRIVATE_KEY_BASE64" | /usr/bin/base64 -D >"$ASC_KEY_PATH"; then
        echo "Error: ASC_PRIVATE_KEY_BASE64 is not valid base64." >&2
        exit 1
    fi
    chmod 600 "$ASC_KEY_PATH"
elif [[ -z "$ASC_KEY_PATH" ]]; then
    ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
fi

if [[ ! -f "$ASC_KEY_PATH" ]] || ! grep -q -- '-----BEGIN PRIVATE KEY-----' "$ASC_KEY_PATH"; then
    echo "Error: a valid App Store Connect .p8 private key was not provided." >&2
    echo "Set ASC_PRIVATE_KEY_BASE64 or ASC_KEY_PATH in .env." >&2
    exit 1
fi

if $PUBLISH_GITHUB; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "Error: gh is required with --publish-github" >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "Error: gh is not authenticated" >&2
        exit 1
    fi
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
        echo "Error: commit all release source changes before publishing to GitHub." >&2
        exit 1
    fi
fi

PROJECT="$REPO_ROOT/macOS/BotSpeaker.xcodeproj"
EXPORT_OPTIONS="$REPO_ROOT/macOS/ExportOptions.plist"
SCHEME="BotSpeaker"
TEAM_ID="52RD2GH5DP"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
TAG="${VERSION}"
DIST_DIR="$REPO_ROOT/dist"
DMG_NAME="BotSpeaker-${VERSION}-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
ARCHIVE_PATH="$BUILD_DIR/BotSpeaker.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
NOTARY_RESULT="$BUILD_DIR/notary-result.json"

mkdir -p "$DIST_DIR"
if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" ]]; then
    echo "Error: release output already exists for $VERSION in $DIST_DIR" >&2
    exit 1
fi

echo "Building BotSpeaker $VERSION ($BUILD_NUMBER) for arm64 and x86_64..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO

echo "Exporting the Developer ID application..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

APP_PATH="$(find "$EXPORT_PATH" -maxdepth 2 -type d -name 'BotSpeaker.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
    echo "Error: exported BotSpeaker.app was not found" >&2
    exit 1
fi

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/BotSpeaker"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "Error: expected a universal binary, found: $ARCHITECTURES" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$REPO_ROOT/scripts/make-dmg.sh" "$APP_PATH" "$DMG_PATH" "$DEVELOPER_ID_IDENTITY"

echo "Submitting the DMG to Apple's notary service..."
set +e
xcrun notarytool submit "$DMG_PATH" \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait \
    --output-format json >"$NOTARY_RESULT"
NOTARY_EXIT=$?
set -e

cat "$NOTARY_RESULT"
SUBMISSION_ID="$(plutil -extract id raw "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw "$NOTARY_RESULT" 2>/dev/null || true)"

if [[ $NOTARY_EXIT -ne 0 || "$NOTARY_STATUS" != "Accepted" ]]; then
    if [[ -n "$SUBMISSION_ID" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$ASC_KEY_PATH" \
            --key-id "$ASC_KEY_ID" \
            --issuer "$ASC_ISSUER_ID" || true
    fi
    echo "Error: notarization was not accepted" >&2
    exit 1
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --verbose=2 --type open --context context:primary-signature "$DMG_PATH"

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$DMG_NAME" >"$CHECKSUM_PATH"

if $PUBLISH_GITHUB; then
    if ! gh release view "$TAG" >/dev/null 2>&1; then
        if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
            if ! git show-ref --verify --quiet "refs/tags/$TAG"; then
                git fetch origin "refs/tags/$TAG:refs/tags/$TAG"
            fi
        else
            if ! git show-ref --verify --quiet "refs/tags/$TAG"; then
                git tag -a "$TAG" -m "BotSpeaker $VERSION"
            fi
            git push origin "$TAG"
        fi

        gh release create "$TAG" \
            --verify-tag \
            --title "BotSpeaker $VERSION" \
            --notes "Cross-platform BotSpeaker release. See the attached assets for macOS and Windows downloads."
    fi

    git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
    TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
        echo "Error: $TAG points to $TAG_COMMIT, but this checkout is $HEAD_COMMIT." >&2
        echo "Check out the release tag before uploading platform assets." >&2
        exit 1
    fi

    EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
    for asset in "$DMG_NAME" "$(basename "$CHECKSUM_PATH")"; do
        if grep -Fxq "$asset" <<<"$EXISTING_ASSETS"; then
            echo "Error: GitHub release $TAG already contains $asset" >&2
            exit 1
        fi
    done

    gh release upload "$TAG" "$DMG_PATH" "$CHECKSUM_PATH"
fi

echo "Release complete:"
echo "  DMG: $DMG_PATH"
echo "  SHA-256: $SHA256"
if ! $PUBLISH_GITHUB; then
    echo "  GitHub publishing was skipped. Re-run with --publish-github when ready."
fi
