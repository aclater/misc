#!/usr/bin/env bash
#
# piv-card-recon.sh — READ-ONLY reconnaissance of a PIV card and the local
# trust state. Changes NOTHING: no imports, no config writes. It answers:
#
#   1. Is the smartcard stack healthy? (pcscd, reader, card, p11-kit/OpenSC)
#   2. What certificates are on the card? (all slots: subject/issuer/validity)
#   3. What CA chain does the PIV Authentication cert need, hop by hop?
#      (follows AIA caIssuers with SKI/AKI parent matching — same logic as
#       import-piv-cas.sh, but reporting instead of importing)
#   4. Which of those CAs are already in ~/.pki/nssdb, and with what trust?
#   5. What should BRANCH_FILTER in import-federal-cas.sh be for THIS card?
#
# Run with the card inserted:  ./piv-card-recon.sh
# Paste the full output back for analysis.
#
set -uo pipefail

DB="sql:$HOME/.pki/nssdb"
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
info() { printf '  [ -- ] %s\n' "$*"; }
hr()   { printf -- '---------------------------------------------------------------\n'; }

# ── 0. Dependencies (report, don't install) ─────────────────────────────────
hr; echo "0. Tooling"
missing=0
for t in pkcs11-tool opensc-tool openssl curl certutil p11-kit; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t $(command -v "$t")"
  else bad "$t missing"; missing=1; fi
done
[ "$missing" -eq 1 ] && { echo; echo "Install missing tools (dnf: opensc nss-tools openssl p11-kit) and re-run."; exit 1; }

# ── 1. Smartcard stack health ───────────────────────────────────────────────
hr; echo "1. Smartcard stack"
if systemctl is-active --quiet pcscd 2>/dev/null || systemctl is-active --quiet pcscd.socket 2>/dev/null; then
  ok "pcscd is active (service or socket)"
else
  info "pcscd not currently active (socket activation may start it on demand)"
fi

readers=$(opensc-tool -l 2>/dev/null || true)
if [ -z "$readers" ] || echo "$readers" | grep -qi 'No smart card readers'; then
  bad "No smartcard reader detected. Plug in the reader and re-run."
  exit 1
fi
# shellcheck disable=SC2001  # multi-line indent; sed is the clear tool here
echo "$readers" | sed 's/^/       /'
if echo "$readers" | grep -q 'Yes'; then
  ok "Card present in reader"
else
  bad "Reader present but NO card detected. Insert the PIV card and re-run."
  exit 1
fi
card_name=$(opensc-tool -n 2>/dev/null || echo "unknown")
info "Card recognized as: $card_name"

if p11-kit list-modules 2>/dev/null | grep -qi 'opensc'; then
  ok "OpenSC PKCS#11 module registered with p11-kit (browsers will see the card)"
else
  bad "OpenSC module NOT visible to p11-kit — browsers won't see the card. Check the opensc package."
fi

# ── 2. Certificate inventory on the card ────────────────────────────────────
hr; echo "2. Certificates on the card"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Enumerate certificate object IDs from the token.
mapfile -t cert_ids < <(pkcs11-tool --list-objects --type cert 2>/dev/null \
  | grep -oE 'ID:[[:space:]]*[0-9a-fA-F]+' | awk '{print $2}' | sort -u)
if [ "${#cert_ids[@]}" -eq 0 ]; then
  bad "pkcs11-tool sees no certificate objects on the card."
  exit 1
fi

leaf=""   # will hold the PIV Authentication cert (id 01) for the chain walk
for id in "${cert_ids[@]}"; do
  der="$work/card_$id.der"; pem="$work/card_$id.pem"
  pkcs11-tool --read-object --type cert --id "$id" >"$der" 2>/dev/null || continue
  openssl x509 -inform DER -in "$der" -out "$pem" 2>/dev/null || continue
  subj=$(openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
  iss=$(openssl x509 -in "$pem" -noout -issuer  -nameopt RFC2253 2>/dev/null); iss=${iss#issuer=}
  na=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  eku=$(openssl x509 -in "$pem" -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2 | tr -d ' ' | tr '\n' ' ')
  echo "  slot id $id:"
  echo "     subject : $subj"
  echo "     issuer  : $iss"
  echo "     expires : $na"
  [ -n "$eku" ] && echo "     EKU     : $eku"
  if openssl x509 -in "$pem" -checkend 0 >/dev/null 2>&1; then :; else bad "  slot $id cert is EXPIRED"; fi
  case "$id" in 01|1) leaf="$pem" ;; esac
done
if [ -z "$leaf" ]; then
  bad "No PIV Authentication cert (object id 01) found — chain walk skipped."
  exit 1
fi

# The issuer O= / OU= of the leaf is what import-federal-cas.sh must branch into.
leaf_iss=$(openssl x509 -in "$leaf" -noout -issuer -nameopt RFC2253 2>/dev/null); leaf_iss=${leaf_iss#issuer=}
suggest_org=$(echo "$leaf_iss" | grep -oE 'O=[^,]+' | head -1 | cut -d= -f2-)

# ── 3. nssdb fingerprint inventory (so each chain hop can be checked) ───────
hr; echo "3. Local trust store ($DB)"
declare -A NSS_TRUST=()
if [ -f "$HOME/.pki/nssdb/cert9.db" ]; then
  # certutil -L lines: <nickname ...> <trust>. Nickname may contain spaces, so
  # split on the LAST whitespace-separated field.
  while IFS= read -r line; do
    line="${line%"${line##*[![:space:]]}"}"   # rtrim: certutil pads the trust column
    trust=${line##* }; nick=${line%"$trust"}
    nick="${nick%"${nick##*[![:space:]]}"}"   # trim trailing whitespace (no extglob needed)
    [ -n "$nick" ] || continue
    pemtmp="$work/nss_one.pem"
    certutil -d "$DB" -L -n "$nick" -a >"$pemtmp" 2>/dev/null || continue
    # A nickname can hold multiple certs; fingerprint each.
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("'"$work"'/nsseg" n ".pem")}' "$pemtmp"
    for f in "$work"/nsseg*.pem; do
      [ -s "$f" ] || continue
      fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
      [ -n "$fp" ] && NSS_TRUST["$fp"]="$trust"
      rm -f "$f"
    done
  done < <(certutil -d "$DB" -L 2>/dev/null | tail -n +5)
  echo "  nssdb exists with ${#NSS_TRUST[@]} certificate(s) loaded."
else
  info "No ~/.pki/nssdb yet (no browser has created one and no import has run)."
fi

nss_status() {  # $1=pemfile -> prints trust state of this exact cert in nssdb
  local fp t
  fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  t="${NSS_TRUST[$fp]:-}"
  if [ -z "$t" ]; then echo "MISSING from nssdb"
  elif [[ "$t" == *C* ]] || [[ "$t" == *T* ]]; then echo "present, TRUSTED ($t)"
  else echo "present, chain-only ($t)"; fi
}

# ── 4. Dry-run chain walk (AIA upward, SKI/AKI parent matching) ─────────────
hr; echo "4. Chain the PIV Authentication cert requires (leaf -> root)"
ski() { openssl x509 -in "$1" -noout -text 2>/dev/null | grep -A1 "Subject Key Identifier"   | tail -1 | tr -d ' '; }
aki() { openssl x509 -in "$1" -noout -text 2>/dev/null | grep -A1 "Authority Key Identifier" | tail -1 | tr -d ' ' | sed 's/keyid://'; }

hop=0
cur="$leaf"
subj=$(openssl x509 -in "$cur" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
echo "  [$hop] LEAF: $subj"
echo "        (leaf lives on the card; it is never imported anywhere)"

while :; do
  hop=$((hop+1)); [ "$hop" -gt 8 ] && { bad "chain longer than 8 hops? stopping."; break; }
  subj=$(openssl x509 -in "$cur" -noout -subject -nameopt RFC2253 2>/dev/null); subj=${subj#subject=}
  iss=$(openssl x509 -in "$cur" -noout -issuer  -nameopt RFC2253 2>/dev/null); iss=${iss#issuer=}
  [ "$subj" = "$iss" ] && break   # reached the self-signed root
  want=$(aki "$cur")
  mapfile -t aia_urls < <(openssl x509 -in "$cur" -noout -text 2>/dev/null \
      | grep -oE 'CA Issuers - URI:https?://[^ ]+' | sed 's/CA Issuers - URI://')
  if [ "${#aia_urls[@]}" -eq 0 ]; then
    bad "  [$hop] cert has NO AIA caIssuers URL — chain cannot be auto-discovered above: $subj"
    break
  fi
  parent=""
  for u in "${aia_urls[@]}"; do
    tmp="$work/aia.bin"
    curl -fsS --max-time 20 -o "$tmp" "$u" || { info "  [$hop] AIA fetch failed: $u"; continue; }
    certs="$work/aia.pem"
    openssl pkcs7 -inform DER -in "$tmp" -print_certs 2>/dev/null >"$certs" \
      || openssl pkcs7 -in "$tmp" -print_certs 2>/dev/null >"$certs" \
      || openssl x509 -inform DER -in "$tmp" 2>/dev/null >"$certs" || continue
    rm -f "$work"/aiaseg*.pem
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("'"$work"'/aiaseg" n ".pem")}' "$certs"
    best=""; best_root=""
    for c in "$work"/aiaseg*.pem; do
      [ -s "$c" ] || continue
      openssl x509 -in "$c" -noout >/dev/null 2>&1 || continue
      csub=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 2>/dev/null); csub=${csub#subject=}
      ciss=$(openssl x509 -in "$c" -noout -issuer  -nameopt RFC2253 2>/dev/null); ciss=${ciss#issuer=}
      if { [ -n "$want" ] && [ "$(ski "$c")" = "$want" ]; } \
         || { [ -z "$want" ] && [ "$csub" = "$iss" ]; }; then
        if [ "$csub" = "$ciss" ]; then best_root="$c"; else best="$c"; fi
      fi
    done
    parent="${best_root:-$best}"
    if [ -n "$parent" ]; then
      psub=$(openssl x509 -in "$parent" -noout -subject -nameopt RFC2253 2>/dev/null); psub=${psub#subject=}
      pkind="intermediate"; [ "$best_root" = "$parent" ] && pkind="SELF-SIGNED ROOT"
      echo "  [$hop] $pkind: $psub"
      echo "        found via  : $u"
      echo "        nssdb state: $(nss_status "$parent")"
      cp "$parent" "$work/hop$hop.pem"; cur="$work/hop$hop.pem"
      break
    fi
  done
  [ -n "$parent" ] || { bad "  [$hop] no parent matching AKI found in any AIA bundle for: $subj"; break; }
done

# ── 5. Verdict & recommendations ────────────────────────────────────────────
hr; echo "5. Recommendations"
echo "  Leaf issuer          : $leaf_iss"
echo "  Suggested BRANCH_FILTER for import-federal-cas.sh: '${suggest_org:-<none found>}'"
echo "    (compare against the current value; it matches case-insensitively on the CA subject)"
echo
if certutil -d "$DB" -V -u C -n "PIV_II:Certificate for PIV Authentication" </dev/null 2>/dev/null; then
  ok "certutil validates the card's PIV Authentication cert for TLS client auth NOW."
  echo "       Browsers should offer the cert. If a site still doesn't prompt, it's server-side."
else
  info "certutil could not validate the token cert (missing chain links above, or a"
  info "different token label). If any hop shows MISSING, run: import-federal-cas.sh"
  info "then import-piv-cas.sh (card inserted), and re-run this recon."
fi
hr
echo "Recon complete. Nothing was modified. Paste this output back for analysis."
