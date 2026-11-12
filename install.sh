#!/bin/bash
# Installs (or updates) Perch: https://github.com/tanmayhc7/perch
#
#   curl -fsSL https://raw.githubusercontent.com/tanmayhc7/perch/main/install.sh | bash
#
# What it does, in order:
#   1. checks you're on macOS 14 or later
#   2. finds the latest release on GitHub and downloads its zip
#   3. checks the zip against the checksum GitHub lists for it
#   4. quits Perch if it's running, then puts Perch.app in /Applications
#      (or ~/Applications if /Applications isn't writable for you)
#   5. clears the "downloaded from the internet" flag, so macOS doesn't show its
#      "unidentified developer" warning (Perch isn't notarized yet), and opens it
#
# It never uses sudo and touches nothing outside the install folder and a temp folder.
# Run it again any time to update. For testing: PERCH_INSTALL_DIR=<folder> installs there,
# and PERCH_NO_OPEN=1 doesn't launch the app.

set -euo pipefail

REPO="tanmayhc7/perch"
APP="Perch.app"
BUNDLE_ID="io.github.tanmayhc7.perch"

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }
die()  { printf '\n\033[31mCouldn'"'"'t install Perch:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Perch is a Mac app; this only works on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Perch needs macOS 14 (Sonoma) or later; this Mac has $(sw_vers -productVersion)."
command -v curl >/dev/null || die "curl isn't available."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Finding the latest Perch"
# /releases/latest redirects to .../tag/<tag>, so the tag is the last part of the final address.
final="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" </dev/null)" \
  || die "couldn't reach GitHub. Check your internet connection and try again."
tag="${final##*/}"
case "$tag" in v[0-9]*) ;; *) die "couldn't find a release (got '$tag')." ;; esac
version="${tag#v}"
note "Version $version"

say "Downloading"
zip="$tmp/perch.zip"
curl -fL --progress-bar -o "$zip" "https://github.com/$REPO/releases/download/$tag/perch-$version.zip" </dev/null \
  || die "the download failed."

say "Checking the download"
# GitHub lists a SHA-256 for every release file. If it can't be fetched (for example, rate-limited), carry on without it.
expected="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$tag" </dev/null 2>/dev/null \
  | awk -v n="perch-$version.zip" '$0 ~ "\"name\": \"" n "\"" {f=1} f && /"digest": "sha256:/ {gsub(/.*sha256:|".*/, ""); print; exit}' || true)"
if [ -n "$expected" ]; then
  actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || die "the download doesn't match GitHub's checksum, so it was not installed."
  note "Checksum matches"
else
  note "No checksum available from GitHub; skipping this check"
fi

say "Installing"
ditto -x -k "$zip" "$tmp/unzipped" || die "couldn't unzip the download."
[ -d "$tmp/unzipped/$APP" ] || die "the download doesn't contain $APP."

dest="${PERCH_INSTALL_DIR:-/Applications}"
if [ ! -d "$dest" ] || [ ! -w "$dest" ]; then
  if [ -z "${PERCH_INSTALL_DIR:-}" ]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
    note "/Applications isn't writable for this account, so installing to $dest"
  else
    die "$dest isn't a folder you can write to."
  fi
fi

# Quit the copy running from the install folder so it can be replaced (a copy run from elsewhere is left alone).
running() { pgrep -f "$dest/$APP/Contents/MacOS/" >/dev/null 2>&1; }
if running; then
  note "Quitting the running Perch"
  osascript -e "tell application \"$dest/$APP\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 0.5; done
  if running; then pkill -f "$dest/$APP/Contents/MacOS/" || true; fi
fi

rm -rf "$dest/$APP"
ditto "$tmp/unzipped/$APP" "$dest/$APP" || die "couldn't copy $APP into $dest."
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true
note "Installed to $dest/$APP"

if [ -z "${PERCH_NO_OPEN:-}" ]; then
  open "$dest/$APP"
fi

say "Done"
note "Perch has no Dock icon. Move your pointer to the notch at the top of the screen to open it."
note "To start it when you log in, open it and choose  ...  ->  Open at login."
note "To update later, run the same command again."
