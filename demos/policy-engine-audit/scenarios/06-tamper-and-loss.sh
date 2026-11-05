#!/bin/bash
# Scenario 06 (deep dive): somebody edits one byte of one record, or deletes a
# record. An offline validator with only the public key catches both.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

title "06  Tampering and loss: caught offline with the public key"
business "an external auditor holding the NDJSON export and the gateway's public key" \
         "AID-EMIT-1: every record is fingerprinted, chained to its predecessor and DSSE-signed" \
         "an insider quietly rewriting a deny into an allow, or deleting the record of it"

VALIDATOR="$("$DEMO_DIR/tools/fetch-validator.sh")"
KEY="$DEMO_DIR/keys/ocsf-signing.pub.pem"
WORK="$OUT/tamper"
mkdir -p "$WORK"

# The whole export. A restart (scenario 05) starts a second chain; the
# validator checks each chain_uid and each (epoch, stream) on its own.
records > "$WORK/original.ndjson"
n=$(wc -l < "$WORK/original.ndjson" | tr -d ' ')

step "1. The untouched export ($n records)"
python3 -I "$VALIDATOR" "$WORK/original.ndjson" --key "$KEY" | tail -1 | sed 's/^/    /'

step "2. Flip one deny into an allow in one record"
line=$(grep -n '"action":"Denied"' "$WORK/original.ndjson" | head -1 | cut -d: -f1 || true)
[ -n "$line" ] || fail "no deny record to tamper with; run scenarios 02-03 first"
sed "${line}s/\"action\":\"Denied\"/\"action\":\"Allowed\"/" "$WORK/original.ndjson" > "$WORK/tampered.ndjson"
info "edited record $line"
python3 -I "$VALIDATOR" "$WORK/tampered.ndjson" --key "$KEY" | grep -E '^ERROR|^FAIL' | head -4 | sed 's/^/    /' || true

step "3. Delete one record"
# A record in the middle of the first chain.
del=$(( $(records | jq -s 'map(select(.attestation_list[0].chain_uid == $c)) | length' --arg c "$(records | head -1 | jq -r '.attestation_list[0].chain_uid')") / 2 + 1 ))
sed "${del}d" "$WORK/original.ndjson" > "$WORK/missing.ndjson"
info "deleted record $del"
python3 -I "$VALIDATOR" "$WORK/missing.ndjson" --key "$KEY" | grep -E '^(ERROR|WARN)' | head -3 | sed 's/^/    /' || true
info "and the ledger adapter's gap detector, over the same export (nothing written):"
python3 - "$REPO_DIR/adapters/cpex" "$WORK/missing.ndjson" <<'PY' | sed 's/^/    /'
import json, sys
sys.path.insert(0, sys.argv[1])
from cpex_to_ledger import GapDetector, extract_stream_stamps
detector = GapDetector()
for line in open(sys.argv[2]):
    epoch, stream_id, seq, emission = extract_stream_stamps(json.loads(line))
    for alert in detector.check(stream_id, seq, emission, epoch=epoch):
        print("WARNING:", alert)
PY

auditor "a pinpointed failure for the edited record (fingerprint and signature no longer
         verify, and the next record's link breaks) and a stream_seq gap for the deleted one,
         from the export and a public key alone. No access to the gateway is needed."
