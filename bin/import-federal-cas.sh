#!/usr/bin/env bash
# Card-free import of the Federal PIV trust chain into the per-user NSS db.
# Trusts FCPCA G2, then imports the Entrust SSP branch (cross-certs + issuing
# CAs) as chain material by following SIA repository bundles downward.
# Idempotent; safe to re-run. NOT set -e: bundle fetching is best-effort.
set -uo pipefail
DB="sql:$HOME/.pki/nssdb"
FCPCA_URL="http://repo.fpki.gov/fcpca/fcpcag2.crt"
FCPCA_SIA_FALLBACK="http://repo.fpki.gov/fcpca/caCertsIssuedByfcpcag2.p7c"
# Direct seeds for the Entrust SSP branch, independent of SIA discovery through the
# cross-cert (URLs confirmed live via card recon + GSA FPKI notifications):
#  - CertsIssuedByEMSRootCA.p7c: certs the EMS Root has ISSUED — contains the
#    "Entrust Managed Services SSP CA" that issues the PIV certs.
#  - CertsIssuedToEMSRootCA.p7c: certs issued TO the EMS Root — contains its
#    SELF-SIGNED root cert (auto-promoted to trust anchor by import_cert) plus
#    the FCPCA cross-certs. Directly trusting the self-signed EMS root matters:
#    NSS validation through the FCPCA->EMS cross-cert path fails its policy
#    processing, so the short chain (leaf -> SSP -> EMS root) is what browsers
#    actually validate against — matching a known-good host's trust state.
# Belt and suspenders — dedup'd by fingerprint if the walk already found them.
EXTRA_SIA_SEEDS="http://rootweb.managed.entrust.com/SIA/CertsIssuedByEMSRootCA.p7c
http://rootweb.managed.entrust.com/AIA/CertsIssuedToEMSRootCA.p7c"
BRANCH_FILTER="${BRANCH_FILTER:-entrust}"   # descend only into CAs matching this (your card's SSP branch; piv-card-recon.sh suggests it)

for t in certutil openssl curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "Missing $t — install nss-tools/openssl/curl and re-run." >&2; exit 1; }
done
[ -f "$HOME/.pki/nssdb/cert9.db" ] || { mkdir -p "$HOME/.pki/nssdb"; certutil -d "$DB" -N --empty-password; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work" || exit 1

seen="$work/seen.txt"; : >"$seen"
import_cert() {  # $1=pemfile
  local f="$1" subj iss fp nick short
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || return 0
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

sia_urls() {  # $1=pemfile — print the CA Repository URIs from the SIA extension
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | grep -oE 'CA Repository - URI:https?://[^ ]+' | sed 's/CA Repository - URI://'
}

# Fetch one SIA/AIA-style p7c bundle, import every cert in it, and recurse into
# the SIA of certs matching BRANCH_FILTER. Depth-capped; fingerprints dedup'd.
process_bundle() {  # $1=url $2=depth
  local url="$1" d="${2:-0}" tmp certs segdir c u2
  [ "$d" -gt 3 ] && return
  tmp=$(mktemp); curl -fsS --max-time 25 -o "$tmp" "$url" || { rm -f "$tmp"; return; }
  certs=$(mktemp)
  openssl pkcs7 -inform DER -in "$tmp" -print_certs 2>/dev/null >"$certs" \
    || openssl pkcs7 -in "$tmp" -print_certs 2>/dev/null >"$certs" \
    || openssl x509 -inform DER -in "$tmp" 2>/dev/null >"$certs" \
    || { rm -f "$tmp" "$certs"; return; }
  segdir=$(mktemp -d -p "$work")
  ( cd "$segdir" && awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("seg"n".pem")}' "$certs" )
  for c in "$segdir"/seg*.pem; do
    [ -s "$c" ] || continue
    openssl x509 -in "$c" -noout >/dev/null 2>&1 || continue
    import_cert "$c"
    if openssl x509 -in "$c" -noout -subject 2>/dev/null | grep -qi "$BRANCH_FILTER"; then
      for u2 in $(sia_urls "$c"); do process_bundle "$u2" $((d+1)); done
    fi
  done
  rm -rf "$tmp" "$certs" "$segdir"
}

echo "Importing Federal PIV trust chain (card-free) into $DB ..."
if ! curl -fsS --max-time 25 -o fcpca.crt "$FCPCA_URL"; then
  echo "Could not fetch the FCPCA G2 root from $FCPCA_URL — check network and re-run." >&2
  exit 1
fi
openssl x509 -inform DER -in fcpca.crt -out fcpca.pem 2>/dev/null \
  || openssl x509 -in fcpca.crt -out fcpca.pem 2>/dev/null \
  || { echo "Fetched FCPCA file is not a certificate." >&2; exit 1; }
import_cert fcpca.pem

# Walk down from the root's own SIA; fall back to the published bundle URL if
# the SIA extension can't be parsed for any reason.
urls=$(sia_urls fcpca.pem)
[ -n "$urls" ] || urls="$FCPCA_SIA_FALLBACK"
for u in $urls; do process_bundle "$u" 0; done
# Direct branch seeds (see EXTRA_SIA_SEEDS above) — idempotent with the walk.
for u in $EXTRA_SIA_SEEDS; do process_bundle "$u" 1; done

echo "Federal PKI import complete ($(wc -l < "$seen") certs processed into $DB)."
