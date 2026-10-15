#!/usr/bin/env bash
# Import a Federal PIV CA chain into the per-user NSS db so Chrome/Edge/
# Firefox will offer the card's client cert. Run once with the card inserted.
# NOT set -e: chain gathering is best-effort (failed AIA fetches / non-cert blobs
# are expected and handled inline; a stray nonzero must not abort the whole run).
set -uo pipefail
DB="sql:$HOME/.pki/nssdb"
FCPCA_URL="http://repo.fpki.gov/fcpca/fcpcag2.crt"

# Self-reliant: ensure every CLI we use exists; install the providing package if not.
declare -A NEED=( [certutil]=nss-tools [pkcs11-tool]=opensc [opensc-tool]=opensc [openssl]=openssl [curl]=curl )
miss=()
for t in "${!NEED[@]}"; do command -v "$t" >/dev/null 2>&1 || miss+=("${NEED[$t]}"); done
if [ "${#miss[@]}" -gt 0 ]; then
  # de-dup package list
  mapfile -t miss < <(printf '%s\n' "${miss[@]}" | sort -u)
  echo "Installing missing dependencies: ${miss[*]}"
  sudo dnf -y install "${miss[@]}" || { echo "Could not install: ${miss[*]} — install them and re-run."; exit 1; }
fi
# pcscd must be running to reach the reader; start it if a prior step didn't.
systemctl is-active --quiet pcscd 2>/dev/null || sudo systemctl enable --now pcscd.socket 2>/dev/null || true

# Create the NSS db if no browser has made one yet (empty password, like browsers do).
[ -f "$HOME/.pki/nssdb/cert9.db" ] || { mkdir -p "$HOME/.pki/nssdb"; certutil -d "$DB" -N --empty-password; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work" || exit 1

# PIV Authentication cert is always object id 0x01 on a PIV card.
if ! pkcs11-tool --read-object --type cert --id 1 >leaf.der 2>/dev/null; then
  echo "No PIV card / reader found — insert the card and retry."; exit 1
fi
openssl x509 -inform DER -in leaf.der -out leaf.pem

seen="$work/seen.txt"; : >"$seen"
import_cert() {  # $1=pemfile
  local f="$1" subj iss fp nick short
  # Skip anything that isn't a parseable X.509 cert (e.g. pkcs7 header text).
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || return 0
  # Strip openssl's "subject="/"issuer=" prefixes so a self-signed cert compares equal.
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
  iss=$(openssl x509 -in "$f" -noout -issuer  -nameopt RFC2253 2>/dev/null); iss=${iss#issuer=}
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  grep -qF "$fp" "$seen" && return 0; echo "$fp" >>"$seen"
  short=$(echo "$subj" | grep -oiE '(CN|OU)=[^,]+' | head -1 | cut -d= -f2-)
  nick="${short:-CA} ${fp:0:8}"
  if [ "$subj" = "$iss" ]; then              # self-signed root -> trust anchor
    certutil -d "$DB" -A -n "$nick" -t "CT,C,C" -i "$f" 2>/dev/null && echo "  trusted root : $nick"
  else                                        # intermediate -> chain material only
    certutil -d "$DB" -A -n "$nick" -t ",,"    -i "$f" 2>/dev/null && echo "  intermediate : $nick"
  fi
}

# Key-identifier helpers — used to follow ONLY the true parent at each hop.
ski() { openssl x509 -in "$1" -noout -text 2>/dev/null | grep -A1 "Subject Key Identifier"   | tail -1 | tr -d ' '; }
aki() { openssl x509 -in "$1" -noout -text 2>/dev/null | grep -A1 "Authority Key Identifier" | tail -1 | tr -d ' ' | sed 's/keyid://'; }

# Walk the issuer chain UPWARD. At each cert, fetch its caIssuers AIA and pick the
# ONE real parent — the cert whose Subject Key Identifier equals our Authority Key
# Identifier (falling back to subject-DN == issuer-DN only when no AKI is present).
# Matching by key id is essential: the issuing root went through a key rollover, so
# several certs share the "Entrust Managed Services Root CA" name but only one is
# the actual signer. Following every name/cross-cert instead would wander the
# entire Federal Bridge mesh (DoD, CertiPath, Boeing, ...) and never finish.
# Recursion stops at the self-signed root, which import_cert marks as a trust anchor.
chase() {  # $1=pemfile $2=depth
  local f="$1" d="${2:-0}" subj iss want u tmp certs c csub ciss best best_root chosen
  [ "$d" -gt 8 ] && return
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
  iss=$(openssl x509 -in "$f" -noout -issuer  -nameopt RFC2253 2>/dev/null); iss=${iss#issuer=}
  [ "$subj" = "$iss" ] && return          # self-signed root: nothing above it
  want=$(aki "$f")                         # the issuer key id we must match
  for u in $(openssl x509 -in "$f" -noout -text 2>/dev/null \
             | grep -oE 'CA Issuers - URI:http://[^ ]+' | sed 's/CA Issuers - URI://'); do
    tmp=$(mktemp); curl -fsS --max-time 20 -o "$tmp" "$u" || { rm -f "$tmp"; continue; }
    certs=$(mktemp)
    openssl pkcs7 -inform DER -in "$tmp" -print_certs 2>/dev/null >"$certs" \
      || openssl x509 -inform DER -in "$tmp" 2>/dev/null >"$certs" || { rm -f "$tmp" "$certs"; continue; }
    # Split into per-cert files; n>0 guard drops pkcs7's pre-cert header lines.
    ( cd "$work" && awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("seg"n".pem")}' "$certs" )
    # Among the returned certs, find the true parent (Subject Key Id == our AKI,
    # or subject DN == our issuer DN when no AKI). A CA key rollover yields several
    # certs for the same key; PREFER the self-signed copy so the walk terminates at
    # the root instead of climbing cross-certs into the Federal Bridge mesh.
    best=""; best_root=""
    for c in "$work"/seg*.pem; do
      [ -s "$c" ] || continue
      openssl x509 -in "$c" -noout >/dev/null 2>&1 || { rm -f "$c"; continue; }
      csub=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 2>/dev/null); csub=${csub#subject=}
      ciss=$(openssl x509 -in "$c" -noout -issuer  -nameopt RFC2253 2>/dev/null); ciss=${ciss#issuer=}
      if { [ -n "$want" ] && [ "$(ski "$c")" = "$want" ]; } \
         || { [ -z "$want" ] && [ "$csub" = "$iss" ]; }; then
        if [ "$csub" = "$ciss" ]; then cp "$c" "$work/parent_root.pem"; best_root="$work/parent_root.pem"
        else                           cp "$c" "$work/parent.pem";      best="$work/parent.pem"; fi
      fi
      rm -f "$c"
    done
    rm -f "$tmp" "$certs"
    chosen="${best_root:-$best}"
    if [ -n "$chosen" ]; then
      import_cert "$chosen"; chase "$chosen" $((d+1)); rm -f "$work/parent_root.pem" "$work/parent.pem"
      return                               # parent found — skip remaining AIA URLs
    fi
  done
}

echo "Importing PIV CA chain into $DB ..."
chase leaf.pem 0

# Always pin the Federal Common Policy CA G2 root straight from the FPKI repo.
if curl -fsS --max-time 25 -o fcpca.crt "$FCPCA_URL"; then
  openssl x509 -inform DER -in fcpca.crt -out fcpca.pem && import_cert fcpca.pem
fi

echo
echo "nssdb CA list:"; certutil -d "$DB" -L
echo
if certutil -d "$DB" -V -u C -n "PIV_II:Certificate for PIV Authentication" </dev/null 2>/dev/null; then
  echo "OK: PIV Authentication cert validates for TLS client auth."
  echo "Restart your browser, open the site that wants your card, pick 'PIV Authentication', enter PIN."
else
  echo "Imported, but couldn't auto-verify the token cert (token label may differ)."
fi
