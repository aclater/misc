#!/usr/bin/env bash
set -euo pipefail

# Signal Desktop's release-signing key fingerprint. The key lives in the default
# gpg keyring (imported by the installer). Verification is BOUND to this
# fingerprint via gpg's VALIDSIG status line below, so extra/unexpected keys in
# the keyring cannot pass verification — only a signature made by this key (or a
# subkey of it) is accepted. Source (official):
#   https://updates.signal.org/static/desktop/appimage.asc
SIGNAL_KEY_FPR="4B16B7232DFAA439AD791002EF9F501F13EED94C"

# Skip cleanly if the network isn't up yet (e.g. the timer fired before
# connectivity) rather than erroring out under set -e.
curl -fsI --max-time 10 https://updates.signal.org >/dev/null 2>&1 \
  || { echo "Signal: network unreachable, skipping."; exit 0; }

dest="$HOME/Applications/Signal.AppImage"
mkdir -p "$HOME/Applications"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fL -o "$tmp/Signal.AppImage"     https://updates.signal.org/desktop/signal-desktop.AppImage
curl -fL -o "$tmp/Signal.AppImage.gpg" https://updates.signal.org/desktop/signal-desktop.AppImage.gpg
# Verify the detached signature AND bind it to the pinned key. Plain gpg --verify
# accepts a good signature from ANY key in the default keyring, so we additionally
# require a VALIDSIG status line naming our pinned fingerprint. Capture the status
# output first (|| true) so a failed gpg exit can't be masked by a pipeline under
# set -e; a bad/missing signature yields no VALIDSIG line and we fail closed.
# VALIDSIG format: "VALIDSIG <signing-key-fpr> <date> <ts> ... <primary-key-fpr>",
# so accept the pinned fpr in either the first (signed directly) or last (signed
# by a subkey of the pinned primary) position. grep -a: Signal's signature carries
# a binary NOTATION_DATA line that would otherwise trip grep's binary detection
# and suppress the match on a legitimate signature.
status=$(gpg --status-fd 1 --verify "$tmp/Signal.AppImage.gpg" "$tmp/Signal.AppImage" 2>/dev/null) || true
if ! printf '%s\n' "$status" \
     | grep -aEq "^\[GNUPG:\] VALIDSIG ([0-9A-F]{40} .* )?${SIGNAL_KEY_FPR}( |$)"; then
  echo "Signal: signature not made by pinned key ${SIGNAL_KEY_FPR}; refusing to install." >&2
  exit 1
fi
# Only replace the live AppImage if the file actually changed.
if [ -f "$dest" ] && cmp -s "$tmp/Signal.AppImage" "$dest"; then
  echo "Signal already up to date."
  exit 0
fi
chmod +x "$tmp/Signal.AppImage"
mv -f "$tmp/Signal.AppImage" "$dest"
echo "Signal updated."
