#!/usr/bin/env python3
"""Look up the ledger receipt for one OCSF record and verify it.

    receipt.py --uid <metadata.uid> [--endpoint localhost:19292]

Finds the `cpex.decision` ledger entry the CPEX adapter wrote for the record
whose `metadata.uid` is <uid> (the adapter uses it as the idempotency key),
then asks the ledger to verify that entry's proof: its hash, its link to the
previous entry, and its position in the chain. Prints the receipt fields an
auditor would file next to the OCSF record.
"""

from __future__ import annotations

import argparse
import json
import sys

from ledger_client import LedgerClient


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--uid", required=True, help="the OCSF record's metadata.uid")
    parser.add_argument("--endpoint", default="localhost:19292")
    args = parser.parse_args()

    with LedgerClient(args.endpoint) as client:
        entries = [
            e for e in client.query(entry_type="cpex.decision") if e.idempotency_key == args.uid
        ]
        if not entries:
            print(f"  no ledger entry for {args.uid}", file=sys.stderr)
            return 1
        entry = entries[0]
        proof = client.verify_proof(entry.entry_hash, entry.entry_type)

    record = json.loads(entry.content)
    print(f"  Receipt for     {args.uid}")
    print(f"  Ledger valid    {'YES' if proof.valid else 'NO  ' + proof.failure_reason}")
    print(f"  Chain position  {entry.chain_position}")
    print(f"  Entry hash      {entry.entry_hash}")
    print(f"  Previous hash   {entry.previous_hash}")
    print(f"  Signed by       {entry.signer_key_reference or '-'} "
          f"({len(entry.writer_signature)}-byte gateway signature kept with the entry)")
    print(f"  Record verdict  {record.get('disposition')} {record.get('status_code') or ''}".rstrip())
    return 0 if proof.valid else 1


if __name__ == "__main__":
    sys.exit(main())
