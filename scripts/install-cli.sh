#!/usr/bin/env bash
# Installs or updates the botspeaker CLI.
#
#   curl -fsSL https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.sh | bash
#   scripts/install-cli.sh                    # latest GitHub release, into /usr/local/bin (or ~/.local/bin)
#   scripts/install-cli.sh --version 0.4.0    # a specific release
#   scripts/install-cli.sh --source           # build cli/ from this checkout instead of downloading
#   scripts/install-cli.sh --dest ~/bin       # custom destination directory
#
# An existing botspeaker in the destination is replaced, whatever its version.
# Once installed, `botspeaker upgrade` does the same thing from inside the CLI.
set -euo pipefail

REPOSITORY="DJBen/BotSpeaker"
ASSET="botspeaker-cli-macos-universal.zip"
DOWNLOAD_BASE="${BOTSPEAKER_CLI_DOWNLOAD_BASE:-https://github.com/${REPOSITORY}/releases/download}"
LATEST_URL="${BOTSPEAKER_CLI_LATEST_URL:-https://api.github.com/repos/${REPOSITORY}/releases/latest}"

version=""
from_source=false
destination=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --source) from_source=true; shift ;;
    --dest) destination="${2:-}"; shift 2 ;;
    --dest=*) destination="${1#*=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) destination="$1"; shift ;;
  esac
done
version="${version#v}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "botspeaker runs on macOS only." >&2
  exit 1
fi

# Locate a checkout when the script is run from one (not when piped from curl).
repo_root=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
  if [[ -n "$candidate" && -f "$candidate/cli/Package.swift" ]]; then
    repo_root="$candidate"
  fi
fi

explicit_destination=true
if [[ -z "$destination" ]]; then
  explicit_destination=false
  if [[ -w /usr/local/bin ]]; then
    destination=/usr/local/bin
  else
    destination="$HOME/.local/bin"
  fi
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/botspeaker-cli.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

build_from_source() {
  local root="$repo_root"
  if [[ -z "$root" ]]; then
    echo "Cloning ${REPOSITORY} to build the CLI from source..."
    git clone --quiet --depth 1 "https://github.com/${REPOSITORY}.git" "$work_dir/src"
    root="$work_dir/src"
  fi
  echo "Building botspeaker from $root/cli (release)..."
  (cd "$root/cli" && swift build -c release --product botspeaker >/dev/null)
  local bin_path
  bin_path="$(cd "$root/cli" && swift build -c release --product botspeaker --show-bin-path)"
  cp "$bin_path/botspeaker" "$work_dir/botspeaker"
}

download_release() {
  local tag="$version"
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSL "$LATEST_URL" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    tag="${tag#v}"
    if [[ -z "$tag" ]]; then
      echo "Could not determine the latest release of ${REPOSITORY}." >&2
      return 1
    fi
  fi
  echo "Downloading botspeaker ${tag}..."
  if ! curl -fsSL -o "$work_dir/$ASSET" "${DOWNLOAD_BASE}/${tag}/${ASSET}"; then
    echo "Release ${tag} has no ${ASSET} asset." >&2
    return 1
  fi
  curl -fsSL -o "$work_dir/$ASSET.sha256" "${DOWNLOAD_BASE}/${tag}/${ASSET}.sha256"
  local expected actual
  expected="$(awk '{print $1}' "$work_dir/$ASSET.sha256")"
  actual="$(shasum -a 256 "$work_dir/$ASSET" | awk '{print $1}')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "Checksum mismatch for ${ASSET} (${tag}); refusing to install." >&2
    exit 1
  fi
  ditto -xk "$work_dir/$ASSET" "$work_dir"
  [[ -x "$work_dir/botspeaker" ]]
}

if $from_source; then
  build_from_source
elif ! download_release; then
  if [[ -n "$repo_root" ]]; then
    echo "Falling back to a source build from $repo_root." >&2
    build_from_source
  else
    echo "Download failed. Re-run with --source to build from a checkout." >&2
    exit 1
  fi
fi

target="$destination/botspeaker"
previous=""
if [[ -e "$target" || -L "$target" ]]; then
  previous="$("$target" --version 2>/dev/null || echo "unknown version")"
fi
new_version="$("$work_dir/botspeaker" --version 2>/dev/null || echo "unknown version")"

install_binary() {
  mkdir -p "$destination"
  # Replace atomically so a running `botspeaker` keeps its old inode.
  cp "$work_dir/botspeaker" "$target.new.$$"
  chmod 755 "$target.new.$$"
  mv -f "$target.new.$$" "$target"
}

if [[ -d "$destination" && ! -w "$destination" ]] || [[ ! -d "$destination" && ! -w "$(dirname "$destination")" ]]; then
  if $explicit_destination; then
    echo "$destination is not writable; using sudo."
    sudo mkdir -p "$destination"
    sudo cp "$work_dir/botspeaker" "$target.new.$$"
    sudo chmod 755 "$target.new.$$"
    sudo mv -f "$target.new.$$" "$target"
  else
    destination="$HOME/.local/bin"; target="$destination/botspeaker"
    install_binary
  fi
else
  install_binary
fi

if [[ -n "$previous" ]]; then
  echo "Updated botspeaker ${previous} -> ${new_version} at $target"
else
  echo "Installed botspeaker ${new_version} at $target"
fi
case ":$PATH:" in
  *":$destination:"*) ;;
  *) echo "Add $destination to your PATH to use it as 'botspeaker'." ;;
esac
