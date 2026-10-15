#!/usr/bin/env bash
#
# verify-pki-trust.sh [path/to/piv-auth-leaf.pem]
#
# Card-free verification that a machine set up by fedora_stuff.sh can actually
# validate Federal PIV (Entrust SSP branch) and DoD chains. Run on ANY host — no PIV card, no reader
# needed. Exit code 0 = all checks pass, nonzero = something failed, so it can
# be driven over SSH across a fleet:
#
#   for h in host1 host2; do ssh "$h" 'bash -s' < verify-pki-trust.sh \
#       && echo "$h OK" || echo "$h FAILED"; done
#
# GOLD-STANDARD MODE: pass your exported PIV Authentication cert (public — safe
# to copy between your machines) as $1 and the script validates that exact leaf
# for TLS client auth against this host's trust store — byte-for-byte the same
# evaluation a browser performs when deciding whether to offer your cert.
# Export it once on the host that has the card:
#   pkcs11-tool --read-object --type cert --id 1 2>/dev/null \
#     | openssl x509 -inform DER -out ~/piv-auth-leaf.pem
#
# Checks performed:
#   1. nssdb exists
#   2. FCPCA G2 present and TRUSTED
#   3. Entrust Managed Services SSP CA present (the PIV issuing CA)
#   4. LIVE chain validation: fetch the real SSP CA cert from Entrust's AIA and
#      validate it as an SSL CA against this trust store
#   5. DoD Root CAs present and TRUSTED
#   6. (optional, with $1) your actual leaf validates for TLS client auth
#
set -uo pipefail

DB_DIR="$HOME/.pki/nssdb"
DB="sql:$DB_DIR"
SSP_AIA_URL="http://sspweb.managed.entrust.com/AIA/CertsIssuedToEMSSSPCA.p7c"
LEAF="${1:-}"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
info(){ printf '  [ -- ] %s\n' "$*"; }
hr()  { printf -- '---------------------------------------------------------------\n'; }

for t in certutil openssl curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "Missing $t — run fedora_stuff.sh first (or dnf install nss-tools openssl curl)."; exit 2; }
done

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Validate a cert FILE against the nssdb. $1 = pemfile, $2 = usage
# (C = SSL client, L = SSL CA).
#
# Preferred engine is vfychain, which validates a file directly — but Fedora's
# nss-tools does not ship it (Ubuntu's libnss3-tools does), so the fallback is
# certutil with a DEDUP-SAFE strategy: certutil -A of a cert that already
# exists in the db silently succeeds while keeping the ORIGINAL nickname, so a
# temp-nickname -V would fail with "not found" and produce a FALSE NEGATIVE for
# any cert the importers already landed. If the temp nickname doesn't
# materialize, we locate the existing nickname by SHA-256 fingerprint and
# validate that entry instead.
validate_file() {
  local f="$1" usage="$2"
  if command -v vfychain >/dev/null 2>&1; then
    local u; case "$usage" in C) u=0 ;; L) u=3 ;; *) u="$usage" ;; esac
    vfychain -d "$DB" -u "$u" -a "$f" >/dev/null 2>&1
    return $?
  fi
  local nick rc=1 fp cfp line trustcol cand existing=""
  nick="__verify_tmp_$$_${RANDOM}"
  certutil -d "$DB" -A -n "$nick" -t ",," -i "$f" 2>/dev/null || return 1
  if certutil -d "$DB" -L -n "$nick" >/dev/null 2>&1; then
    # Cert was genuinely new: validate under the temp nickname, then remove it.
    certutil -d "$DB" -V -u "$usage" -n "$nick" </dev/null >/dev/null 2>&1 && rc=0
    certutil -d "$DB" -D -n "$nick" 2>/dev/null
  else
    # Dedup case: the cert pre-existed under another nickname — find it.
    fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    while IFS= read -r line; do
      line="${line%"${line##*[![:space:]]}"}"
      trustcol=${line##* }; cand=${line%"$trustcol"}
      cand="${cand%"${cand##*[![:space:]]}"}"
      [ -n "$cand" ] || continue
      cfp=$(certutil -d "$DB" -L -n "$cand" -a 2>/dev/null \
              | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
      [ "$cfp" = "$fp" ] && { existing="$cand"; break; }
    done < <(certutil -d "$DB" -L 2>/dev/null | tail -n +5)
    if [ -n "$existing" ]; then
      certutil -d "$DB" -V -u "$usage" -n "$existing" </dev/null >/dev/null 2>&1 && rc=0
    fi
  fi
  return "$rc"
}

hr; echo "PKI trust verification — $(hostname) — $DB"

# 1. nssdb exists
if [ -f "$DB_DIR/cert9.db" ]; then
  ok "nssdb exists"
else
  bad "no nssdb at $DB_DIR — fedora_stuff.sh imports have not run for this user"
  hr; echo "RESULT: FAILED ($fail failure(s))"; exit 1
fi

nsslist=$(certutil -d "$DB" -L 2>/dev/null | tail -n +5)

# 2. FCPCA G2 present and trusted (trust column contains C or T)
fcp_line=$(echo "$nsslist" | grep -i 'federal common policy' | head -1 || true)
if [ -n "$fcp_line" ] && echo "$fcp_line" | awk '{print $NF}' | grep -qE '[CT]'; then
  ok "Federal Common Policy CA G2 present and trusted"
elif [ -n "$fcp_line" ]; then
  bad "FCPCA G2 present but NOT trusted (trust: $(echo "$fcp_line" | awk '{print $NF}')) — re-run import-federal-cas.sh"
else
  bad "FCPCA G2 not in nssdb — run import-federal-cas.sh"
fi

# 3. The PIV issuing CA present as chain material
if echo "$nsslist" | grep -qi 'entrust managed services ssp'; then
  ok "Entrust Managed Services SSP CA (PIV issuer) present"
else
  bad "Entrust Managed Services SSP CA not in nssdb — run import-federal-cas.sh"
fi

# 4. LIVE chain proof: fetch the real SSP CA cert from Entrust's AIA repository
#    and ask NSS to validate it as an SSL CA against this machine's trust store.
#    This exercises the actual chain (SSP -> EMS Root [-> FCPCA]) end to end.
if curl -fsS --max-time 25 -o "$work/ssp.p7c" "$SSP_AIA_URL"; then
  if openssl pkcs7 -inform DER -in "$work/ssp.p7c" -print_certs 2>/dev/null >"$work/ssp_all.pem" \
     || openssl pkcs7 -in "$work/ssp.p7c" -print_certs 2>/dev/null >"$work/ssp_all.pem"; then
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > ("'"$work"'/ssp" n ".pem")}' "$work/ssp_all.pem"
    live_ok=0; diag_cert=""
    for c in "$work"/ssp[0-9]*.pem; do
      [ -s "$c" ] || continue
      openssl x509 -in "$c" -noout 2>/dev/null || continue
      if validate_file "$c" L; then live_ok=1; break; fi
      diag_cert="$c"
    done
    if [ "$live_ok" -eq 1 ]; then
      ok "LIVE: real Entrust SSP CA cert validates as SSL CA against this trust store"
    else
      bad "LIVE: fetched SSP CA cert does NOT validate — chain to a trust anchor is broken here"
      if [ -n "$diag_cert" ]; then
        info "       candidate: $(openssl x509 -in "$diag_cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
        info "       validity : $(openssl x509 -in "$diag_cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
        if command -v vfychain >/dev/null 2>&1; then
          vfychain -d "$DB" -u 3 -a "$diag_cert" 2>&1 | grep -E 'ERROR|CERT [0-9]' | head -4 \
            | while IFS= read -r l; do info "       NSS: $l"; done
        else
          info "       (inspect further with: certutil -d $DB -V -u L -n '<its nickname>')"
        fi
      fi
    fi
  else
    info "LIVE check skipped: could not parse the fetched AIA bundle"
  fi
else
  info "LIVE check skipped: could not reach $SSP_AIA_URL (offline?) — static checks above still stand"
fi

# 5. DoD roots present and trusted
dod_total=$(echo "$nsslist" | grep -ci 'dod root ca' || true)
dod_trusted=$(echo "$nsslist" | grep -i 'dod root ca' | awk '{print $NF}' | grep -cE '[CT]' || true)
if [ "${dod_trusted:-0}" -ge 1 ]; then
  ok "DoD Root CAs: $dod_trusted trusted (of $dod_total present)"
else
  bad "No trusted DoD Root CAs in nssdb — run import-dod-cas.sh"
fi

# 6. Gold standard: validate the actual PIV Authentication leaf. Source
#    priority: $1 argument, else read live from an inserted PIV card, else skip.
if [ -z "$LEAF" ] && command -v pkcs11-tool >/dev/null 2>&1 \
   && opensc-tool -l 2>/dev/null | grep -q 'Yes'; then
  if pkcs11-tool --read-object --type cert --id 1 2>/dev/null \
       | openssl x509 -inform DER -out "$work/card-leaf.pem" 2>/dev/null; then
    LEAF="$work/card-leaf.pem"
    info "Gold-standard leaf read live from the inserted PIV card."
  fi
fi
if [ -n "$LEAF" ]; then
  if [ ! -f "$LEAF" ]; then
    bad "leaf file not found: $LEAF"
  elif ! openssl x509 -in "$LEAF" -noout 2>/dev/null; then
    bad "leaf file is not a PEM certificate: $LEAF (export with the pkcs11-tool one-liner in the header)"
  elif validate_file "$LEAF" C; then
    ok "GOLD: your PIV Authentication leaf validates for TLS CLIENT AUTH on this host"
  else
    bad "GOLD: your leaf does NOT validate here — a chain link is missing on this host"
  fi
else
  info "No leaf supplied and no PIV card inserted — gold-standard check skipped."
  info "(Optional: export the public leaf on the card host with"
  info "  pkcs11-tool --read-object --type cert --id 1 | openssl x509 -inform DER -out ~/piv-auth-leaf.pem"
  info " and pass its path as \$1 on other hosts.)"
fi

hr
if [ "$fail" -eq 0 ]; then
  echo "RESULT: OK — $pass check(s) passed. This host will offer PIV certs and trust DoD chains."
  exit 0
else
  echo "RESULT: FAILED — $fail failure(s), $pass pass(es). See FAIL lines above."
  exit 1
fi
