#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# route-coversheet-smoke.sh -- cross-machine smoke test for /product-route and
# /product-cover-sheet (and the SOL-119 DB-down path). Squirrel cannot reach the
# LAN or build PASOE; RUN THIS FROM ROD'S DEV BOX so the firewall path is
# actually exercised (a loopback-on-server run does NOT prove the network path).
#
# It drives the live connector with curl, prints each response, and asserts the
# HTTP status. It diffs the two 200 bodies against the committed samples when the
# seed data below is loaded (see docs/test-db-setup.md for the .df + .d additions
# and the exact seed rows these expectations assume).
#
# Usage:
#   HOST=192.168.50.30 PORT=8810 WEBAPP=<webapp> \
#   BEARER=<the CLEARVUE_CONNECTOR_API_KEY> \
#   ./route-coversheet-smoke.sh
#
# Env (all overridable):
#   HOST      connector host                (default 192.168.50.30)
#   PORT      connector port                (default 8810)
#   WEBAPP    PASOE web-app context root    (default ROOT -> empty segment)
#   BEARER    the shared secret (no "Bearer" prefix; the script adds it)
#   PART      an existing part with routing (default PUMP-ASSY-100)
#   NOROUTE   an existing part with NO routing (default HOUSING-100)
#   MISSING   a part NOT in pt_mstr         (default NOPE-999)
#   FACILITY  external facility code        (default 1000)
#
#   SOL-1736 QtyPallet cases. Each *_WANT is the expected JSON TOKEN for
#   Header.QtyPallet, quotes included ("48") or the bare word null. Override
#   the part + token together to run a case against real data.
#   PART_QTY_WANT     QtyPallet for PART (multiple non-zero)  (default "48")
#   PALLETCMT         multiple 0 + a matched customer part    (default IMPELLER-50)
#   PALLETCMT_WANT    -> that customer part's comment         (default "36")
#   PALLETNONE        multiple 0 + NO matched customer part   (default BRACKET-20)
#   PALLETNONE_WANT   -> blank, emitted as null (1b pending)  (default null)

set -u

HOST="${HOST:-192.168.50.30}"
PORT="${PORT:-8810}"
WEBAPP="${WEBAPP:-}"
BEARER="${BEARER:-}"
PART="${PART:-PUMP-ASSY-100}"
NOROUTE="${NOROUTE:-HOUSING-100}"
MISSING="${MISSING:-NOPE-999}"
FACILITY="${FACILITY:-1000}"
PART_QTY_WANT="${PART_QTY_WANT:-\"48\"}"
PALLETCMT="${PALLETCMT:-IMPELLER-50}"
PALLETCMT_WANT="${PALLETCMT_WANT:-\"36\"}"
PALLETNONE="${PALLETNONE:-BRACKET-20}"
PALLETNONE_WANT="${PALLETNONE_WANT:-null}"

# base URL: http://host:port[/webapp]/clearvue/erp/v1
BASE="http://${HOST}:${PORT}"
[ -n "$WEBAPP" ] && BASE="${BASE}/${WEBAPP}"
BASE="${BASE}/clearvue/erp/v1"

SAMPLES="$(cd "$(dirname "$0")/../../samples" 2>/dev/null && pwd)"

pass=0 ; fail=0

# hit <name> <expected-status> <url> [extra curl args...]
hit() {
  local name="$1" want="$2" url="$3" ; shift 3
  local body code
  body="$(curl -s -w $'\n%{http_code}' "$@" "$url")"
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$code" = "$want" ]; then
    printf '  PASS  %-52s -> %s\n' "$name" "$code" ; pass=$((pass+1))
  else
    printf '  FAIL  %-52s -> %s (wanted %s)\n' "$name" "$code" "$want" ; fail=$((fail+1))
  fi
  printf '        %s\n' "$body" | head -c 2000 ; echo
  LAST_BODY="$body"
}

# qtypallet_token -- print the JSON token for "QtyPallet" in LAST_BODY: a
# quoted string (escapes allowed) or null. Empty when the member is absent.
# Works on compact or pretty JSON; QtyPallet occurs only in the header.
qtypallet_token() {
  printf '%s\n' "$LAST_BODY" \
    | sed -n -E 's/.*"QtyPallet"[[:space:]]*:[[:space:]]*("([^"\\]|\\.)*"|null).*/\1/p' \
    | head -n 1
}

# qty <name> <part> <want-token> -- fetch the cover sheet for <part>, assert
# 200, then assert Header.QtyPallet equals <want-token>.
qty() {
  local name="$1" part="$2" want="$3" got
  hit "coversheet: ${name} (200)" 200 \
      "${BASE}/product-cover-sheet?partNumber=${part}&facility=${FACILITY}" "${AUTH[@]}"
  got="$(qtypallet_token)"
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-52s -> QtyPallet %s\n' "$name" "$got" ; pass=$((pass+1))
  else
    printf '  FAIL  %-52s -> QtyPallet %s (wanted %s)\n' "$name" "${got:-<absent>}" "$want" ; fail=$((fail+1))
  fi
}

AUTH=(-H "Authorization: Bearer ${BEARER}")

echo "== connector: ${BASE} =="
echo

echo "-- /product-route --"
hit "route: part with routing (200)"        200 \
    "${BASE}/product-route?partNumber=${PART}&facility=${FACILITY}"     "${AUTH[@]}"
if [ -n "$SAMPLES" ] && [ -f "$SAMPLES/product-route.example.json" ]; then
  echo "$LAST_BODY" | diff - "$SAMPLES/product-route.example.json" \
    && echo "  DIFF  route body == sample" \
    || echo "  NOTE  route body differs from sample (ok if seed data differs)"
fi
hit "route: part exists, NO routing (200 [])" 200 \
    "${BASE}/product-route?partNumber=${NOROUTE}&facility=${FACILITY}"  "${AUTH[@]}"
hit "route: part not in ERP (404)"          404 \
    "${BASE}/product-route?partNumber=${MISSING}&facility=${FACILITY}"  "${AUTH[@]}"
hit "route: missing partNumber (400)"       400 \
    "${BASE}/product-route?facility=${FACILITY}"                        "${AUTH[@]}"
hit "route: missing/absent bearer (401)"    401 \
    "${BASE}/product-route?partNumber=${PART}&facility=${FACILITY}"
hit "route: wrong bearer (401)"             401 \
    "${BASE}/product-route?partNumber=${PART}&facility=${FACILITY}" \
    -H "Authorization: Bearer NOT-THE-KEY"
echo

echo "-- /product-cover-sheet --"
hit "coversheet: existing part (200)"       200 \
    "${BASE}/product-cover-sheet?partNumber=${PART}&facility=${FACILITY}" "${AUTH[@]}"
if [ -n "$SAMPLES" ] && [ -f "$SAMPLES/product-cover-sheet.example.json" ]; then
  echo "$LAST_BODY" | diff - "$SAMPLES/product-cover-sheet.example.json" \
    && echo "  DIFF  coversheet body == sample" \
    || echo "  NOTE  coversheet body differs from sample (ok if seed data differs)"
fi
hit "coversheet: part not in ERP (404)"     404 \
    "${BASE}/product-cover-sheet?partNumber=${MISSING}&facility=${FACILITY}" "${AUTH[@]}"
hit "coversheet: missing/absent bearer (401)" 401 \
    "${BASE}/product-cover-sheet?partNumber=${PART}&facility=${FACILITY}"
echo

echo "-- /product-cover-sheet QtyPallet (SOL-1736) --"
# ptp_ord_mult when non-zero; when 0, the cp_comment of the SAME cp_mstr record
# that supplies ShipTo/CustItem. Seed rows + what each pins: docs/test-db-setup.md.
qty "QtyPallet: multiple non-zero -> the multiple"        "$PART"       "$PART_QTY_WANT"
qty "QtyPallet: multiple 0 + matched customer -> comment" "$PALLETCMT"  "$PALLETCMT_WANT"
qty "QtyPallet: multiple 0 + no match -> null (1b)"       "$PALLETNONE" "$PALLETNONE_WANT"
echo

echo "-- correlationId echo (SOL-119) --"
# a 404 error body must echo the caller-supplied correlationId
hit "route 404 echoes supplied correlationId" 404 \
    "${BASE}/product-route?partNumber=${MISSING}&facility=${FACILITY}&correlationId=smoke-corr-123" "${AUTH[@]}"
echo "$LAST_BODY" | grep -q "smoke-corr-123" \
  && echo "  PASS  correlationId echoed in error body" \
  || echo "  FAIL  correlationId NOT echoed"
echo

cat <<'EOF'
-- SOL-119: ERP DB DOWN (503, retryable) -- MANUAL STEP --
  1. Stop the MFG/PRO broker (or the synthetic test DB proserve).
  2. Re-run just the two lookups below and confirm:
       - HTTP 503
       - body code == ERP_UNAVAILABLE (broker unreachable) or ERP_DISCONNECTED
         (was connected, reconnect failed in budget)
       - "retryable": true, "category": "ERP_CONNECTIVITY"
       - a "correlationId" is present, and the body carries NO db name / class
         name / OE error number (raw detail is in the PASOE agent log only,
         grep it:  grep <correlationId> <agent-log>  -> subsystem CVERR)
       - it returns within the reconnect budget (~6s), not minutes.

  BEARER=... HOST=... PORT=... WEBAPP=... bash -c '
    b="http://$HOST:$PORT${WEBAPP:+/$WEBAPP}/clearvue/erp/v1"
    curl -s -w "\n%{http_code}\n" -H "Authorization: Bearer $BEARER" \
      "$b/product-route?partNumber=PUMP-ASSY-100&facility=1000"
    curl -s -w "\n%{http_code}\n" -H "Authorization: Bearer $BEARER" \
      "$b/product-cover-sheet?partNumber=PUMP-ASSY-100&facility=1000"
  '
  3. Restart the DB and re-run this script: it must go green again WITHOUT a
     PASOE bounce (proves persistent-connection auto-reconnect).
EOF

echo
echo "== ${pass} passed, ${fail} failed (excludes the manual DB-down step) =="
[ "$fail" -eq 0 ]
