#!/usr/bin/env bash
# install-bin.sh: link the tools in bin/ into ~/.local/bin and the user units
# in systemd/user/ into ~/.config/systemd/user, so this repo is the single
# source of truth. Idempotent. An existing regular file is moved (never
# overwritten) to ~/.local/share/misc-backup/, outside PATH.
#
#   ./install-bin.sh            link everything
#   ./install-bin.sh --dry-run  show what would change
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
BACKUP="$HOME/.local/share/misc-backup/$(date +%Y%m%d-%H%M%S)"
do_() { if [ "$DRY" = 1 ]; then echo "  would: $*"; else "$@"; fi; }

link() {   # link <source> <dest>
    local src=$1 dst=$2
    if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
        echo "  ok      $dst"; return
    fi
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        do_ mkdir -p "$BACKUP"
        do_ mv "$dst" "$BACKUP/"; echo "  saved   $dst -> $BACKUP/"
    fi
    do_ ln -sfn "$src" "$dst"; echo "  linked  $dst -> $src"
}

echo ">> tools -> ~/.local/bin"
do_ mkdir -p "$HOME/.local/bin"
for f in "$REPO"/bin/*; do link "$f" "$HOME/.local/bin/$(basename "$f")"; done

echo ">> user units -> ~/.config/systemd/user"
do_ mkdir -p "$HOME/.config/systemd/user"
for f in "$REPO"/systemd/user/*; do link "$f" "$HOME/.config/systemd/user/$(basename "$f")"; done
do_ systemctl --user daemon-reload

cat <<'NOTE'
>> next steps (only what applies to you)
   systemctl --user enable --now update-signal.timer
   systemctl --user enable --now sync-vm-images-saturn.timer   # needs ~/.config/sync-vm-images-saturn/config
   roam-guard install        # root-owned copy + NetworkManager hook; re-run after editing bin/roam-guard
NOTE
