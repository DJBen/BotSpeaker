#!/usr/bin/env bash
# Builds the botspeaker CLI in release mode and links it into a bin directory.
#   scripts/install-cli.sh            # installs to /usr/local/bin (or ~/.local/bin if not writable)
#   scripts/install-cli.sh ~/bin      # custom destination
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/cli"
swift build -c release --product botspeaker >/dev/null
binary="$(swift build -c release --product botspeaker --show-bin-path)/botspeaker"

destination="${1:-}"
if [[ -z "$destination" ]]; then
  if [[ -w /usr/local/bin ]]; then
    destination=/usr/local/bin
  else
    destination="$HOME/.local/bin"
  fi
fi
mkdir -p "$destination"
ln -sf "$binary" "$destination/botspeaker"
echo "Installed botspeaker -> $destination/botspeaker"
case ":$PATH:" in
  *":$destination:"*) ;;
  *) echo "Add $destination to your PATH to use it as 'botspeaker'." ;;
esac
