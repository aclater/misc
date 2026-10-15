#!/usr/bin/env bash
# Import the DoD PKI CA bundle (roots trusted, intermediates as chain material)
# into the per-user NSS db. Idempotent; safe to re-run.
set -uo pipefail
DB="sql:$HOME/.pki/nssdb"
DOD_ZIP_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip"

for t in certutil openssl curl unzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "Missing $t — install nss-tools/openssl/curl/unzip and re-run." >&2; exit 1; }
done

# Create the NSS db if no browser has made one yet (empty password, like browsers do).
[ -f "$HOME/.pki/nssdb/cert9.db" ] || { mkdir -p "$HOME/.pki/nssdb"; certutil -d "$DB" -N --empty-password; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work" || exit 1

echo "Fetching DoD PKI CA bundle ..."
curl -fsSL --max-time 60 -o dod.zip "$DOD_ZIP_URL" || { echo "DoD bundle download failed." >&2; exit 1; }
unzip -qj dod.zip -d bundle || { echo "DoD bundle unzip failed." >&2; exit 1; }

# Find the main DoD p7b case-insensitively; prefer the PEM-encoded variant.
shopt -s nullglob nocaseglob
p7b=""
for f in bundle/*dod*pem*.p7b; do p7b="$f"; break; done
if [ -z "$p7b" ]; then for f in bundle/*dod*.p7b; do p7b="$f"; break; done; fi
shopt -u nullglob nocaseglob
[ -n "$p7b" ] || { echo "No DoD .p7b found in bundle (naming changed?) — inspect the zip manually." >&2; exit 1; }
echo "Using bundle file: $(basename "$p7b")"

# Explode the PKCS#7 into individual PEM certs (try PEM parse, then DER).
openssl pkcs7 -print_certs -in "$p7b" >certs.pem 2>/dev/null \
  || openssl pkcs7 -print_certs -inform DER -in "$p7b" >certs.pem 2>/dev/null \
  || { echo "Could not parse $p7b as PKCS#7." >&2; exit 1; }
awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("seg" n ".pem")}' certs.pem

roots=0; inters=0
for c in seg*.pem; do
  [ -s "$c" ] || continue
  openssl x509 -in "$c" -noout >/dev/null 2>&1 || continue
  subj=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
  iss=$(openssl x509 -in "$c" -noout -issuer  -nameopt RFC2253 2>/dev/null); iss=${iss#issuer=}
  fp=$(openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  short=$(echo "$subj" | grep -oiE 'CN=[^,]+' | head -1 | cut -d= -f2-)
  nick="${short:-DoD CA} ${fp:0:8}"
  if [ "$subj" = "$iss" ]; then              # self-signed root -> trust anchor
    certutil -d "$DB" -A -n "$nick" -t "CT,C,C" -i "$c" 2>/dev/null && { echo "  trusted root : $nick"; roots=$((roots+1)); }
  else                                        # intermediate -> chain material only
    certutil -d "$DB" -A -n "$nick" -t ",,"    -i "$c" 2>/dev/null && { echo "  intermediate : $nick"; inters=$((inters+1)); }
  fi
done
echo "DoD PKI import complete: $roots roots trusted, $inters intermediates added to $DB."
