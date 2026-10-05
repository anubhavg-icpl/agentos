# Audit log

`agentos.audit` records who did what on a Nestlo host in a log that shows
when it has been edited afterwards. It is built for record-keeping duties such
as EU AI Act Art. 12, SOC 2 CC7.2 and ISO 27001 A.8.15 (control mapping at the
end).

```nix
agentos.audit = {
  enable = true;
  retentionDays = 183;     # default: six months
  strict = false;          # true: refuse work while the log cannot be written
  export.splunk = {        # optional SIEM export, see below
    enable = true;
    url = "https://splunk.example.org:8088/services/collector/event";
    tokenFile = "/run/secrets/splunk-hec";
  };
};
```

Needs `agentos.runtime.enable`. Gateway DLP (`agentos.gateway.dlp`) is a
separate feature that reports into this log; see [dlp.md](dlp.md).

## What is recorded

| Event | When | Main fields |
|:---|:---|:---|
| `gateway.request` | every request an authenticated agent sends, also refused ones | agent, method, provider, model, status, `cost_usd`, token counts, duration, error type |
| `budget.refused` | a request refused for lack of budget | scope (agent/global), spent, reserved, limit, estimate |
| `auth.failure` | bad or missing agent token | claimed agent id, client address, reason, throttled |
| `dlp.detection` | DLP found something | direction, mode, action, detector counts |
| `task.submit` `task.approve` `task.reject` `task.cancel` `task.retry` `task.finish` | orchestrator | task id, agent, workspace, group, who (from `SO_PEERCRED`), status, exit code |
| `agent.spawn` `agent.kill` `agent.exit` | daemon | agent id, kind, operator, workspace, isolation, reason |
| `publish.pr` | a branch was pushed and a PR opened | task, repository, branch, PR URL, pushed commit |
| `audit.dropped` | a producer lost events while the writer was away | count |
| `audit.start` `audit.checkpoint` `audit.retention` | the writer itself | key id, signature, removed segments |

**Never recorded:** prompt or response bodies, task prompts, agent command
lines, header values, tokens, or DLP-matched text. Actors are agent ids and
user names.

## Format

`/var/lib/agentos-audit/audit-<first seq>.jsonl`, one canonical JSON object
per line:

```json
{"actor":"a1","data":{"cost_usd":0.012,"model":"claude-sonnet-5-5","provider":"anthropic","status":200},
 "ets":1800000000100,"hash":"…","peer":{"pid":812,"uid":981},"prev":"…","seq":42,
 "source":"gateway","ts":1800000000112,"type":"gateway.request"}
```

| Field | Meaning |
|:---|:---|
| `seq` | 1, 2, 3 ... without gaps, continuing across segments |
| `ts` | Unix time in milliseconds, set by the writer |
| `ets` | the producer's own clock (ms), to see delays |
| `prev` | SHA-256 of the previous record's line (64 zeros for the first record) |
| `hash` | SHA-256 of this record's canonical JSON without `hash` |
| `peer` | uid and pid of the sending process, from `SO_PEERCRED` |

Editing a record breaks its `hash` and the next record's `prev`; deleting,
inserting or reordering records breaks `seq` and `prev`. A segment is closed
at `segmentSizeMB` (default 64) and at UTC midnight; the next one continues
the chain, so removing or renaming a segment shows up as a gap.

## Who can write

* The **writer** (`agentos-audit.service`, user `agentos-audit`) is the only
  process that opens the files. The state directory is `0750`
  `agentos-audit:agentos-audit`, files `0640`.
* **Producers** (gateway, orchestrator, daemon, task runner; user `agentos`
  or root) send JSON events over `/run/agentos-audit/audit.sock` (`0660`,
  group `agentos-audit`). They cannot open, truncate or delete the log. The
  writer accepts only the event types in the table above, caps an event at
  32 KiB, assigns `seq`, `ts` and the hashes itself, and stamps the sender's
  uid and pid.
* The sandboxed agent user is not in the group and cannot reach the socket
  or the files.
* **Readers** are the members of the group `agentos-audit`
  (`agentos.audit.readers`, default `agentos.runtime.operators`). A reader
  can also connect to the socket; the stamped `peer` shows who sent what.
* Root can of course do anything; see "Limits" for how the signatures and the
  SIEM export cover that.

## Checkpoints and the signing key

After `checkpointEvery` records (default 100) and every five minutes, the
writer appends an `audit.checkpoint` record carrying an **Ed25519 signature**
over `(seq, hash)` of the last record. Someone who rewrites history and
recomputes every hash after the edit still cannot re-sign the old checkpoints.

* `agentos-audit-keygen.service` creates the key on the first boot
  (`/var/lib/agentos-audit-key/signing.key`, root-only, mode `0400`, never
  overwritten). The writer receives it as the systemd credential
  `audit-signing-key`; no other service sees it.
* The public key is appended to `/var/lib/agentos-audit/public.keys`. A
  verifier trusts only keys in that file or given with `--pubkey`; a
  checkpoint signed by an unknown key is an error. For stronger assurance
  copy the public key to another system once, and verify with
  `--pubkey-only --pubkey <file>`.
* To rotate, delete the key file, then run
  `systemctl restart agentos-audit-keygen.service agentos-audit.service`
  (the keygen unit stays active after first boot, so restarting the writer
  alone does not make a new key). The new key id is added to `public.keys`;
  old checkpoints stay verifiable.

## Verifying

```sh
agentos-audit verify              # whole chain and all checkpoint signatures
agentos-audit verify --from 5000  # from the segment containing seq 5000
agentos-audit verify --all --json # every error, machine readable
agentos-audit tail -n 50          # latest records (add -f to follow, --json for raw)
```

Exit status 0 means the chain is intact. Errors name the record and file line:

| Kind | Cause |
|:---|:---|
| `hash_mismatch` | the record was modified |
| `chain_broken` | `prev` does not match: a neighbour was modified, removed or reordered |
| `seq_gap` / `out_of_order` | records missing, duplicated or reordered |
| `segment_gap` | a whole segment is missing |
| `bad_signature` / `checkpoint_mismatch` | a checkpoint is forged, or signs a record that has since changed |
| `unknown_key` | a checkpoint was signed with a key you do not trust |

Run it from a timer or your monitoring too; the result also notes how many
records at the tail are not yet covered by a signed checkpoint.

## Producer behaviour: never block the request path

Each service has a small client. `emit()` puts the event into a bounded
in-memory buffer and returns; a background thread owns the socket and
reconnects. If the writer is down and the buffer
(`agentos.audit.bufferEvents`, 1000) fills, new events are **dropped and
counted**; when the writer returns the client first sends an `audit.dropped`
record with the count, so the chain itself shows the loss. The gateway reports
the counters on `/_agentos/health` under `audit`.

With **`agentos.audit.strict = true`** the services fail closed instead: while
the writer is unreachable (or events were lost and not yet reported) the
gateway answers `503 audit_unavailable`, and the orchestrator refuses to
submit, approve, reject or cancel (HTTP 503). Running tasks and agents are not
stopped, and their events are buffered.

Delivery between producer and writer is at most once: events sitting in the
kernel socket buffer when the writer crashes are lost without a count.

## Retention and rotation

`retentionDays` (default **183**) deletes whole closed segments whose newest
record is older than that, checked hourly; the active segment is never
removed. Each deletion appends an `audit.retention` record listing the
segments removed. `verify` then starts from the first remaining segment and
says that earlier history was pruned. A value below 183 produces a build
warning, `0` keeps everything. Provision disk accordingly: a request
record is a few hundred bytes.

## SIEM export

The writer runs one export loop per enabled sink. Each reads records after a
persisted cursor (`/var/lib/agentos-audit/export/<sink>.cursor`), sends a
batch, and only then advances the cursor. Failures are retried with
exponential back-off (1 s to 60 s) from the same cursor: delivery is **at
least once and in order**; de-duplicate on `metadata.uid` (the record hash) or
`metadata.sequence`. Checkpoint records are exported too, so your SIEM holds a
copy of the signatures independent of this host.

```nix
agentos.audit.export = {
  syslog = {                       # RFC 5424, octet-counted, TCP + TLS
    enable = true;
    host = "siem.example.org";
    port = 6514;                   # default
    caFile = ./siem-ca.pem;        # null: system trust store
  };
  splunk = {                       # HTTP Event Collector
    enable = true;
    url = "https://splunk.example.org:8088/services/collector/event";
    tokenFile = "/run/secrets/splunk-hec";   # loaded as a systemd credential
    index = "agentos";
  };
  otlp = {                         # OTLP/HTTP JSON logs
    enable = true;
    endpoint = "http://otel-collector:4318/v1/logs";
    tokenFile = null;              # optional bearer token
  };
};
```

All three send the same OCSF event as the log body. A sink that sends a token (Splunk always, OTLP with `tokenFile`) refuses an `http://` URL unless it points at this host; use `https://`.

### OCSF mapping

Records map to **OCSF 1.3.0 API Activity** (`class_uid` 6003, category 6
Application Activity); field names follow
<https://schema.ocsf.io/1.3.0/classes/api_activity>.

| OCSF field | From |
|:---|:---|
| `class_uid` / `category_uid` | 6003 / 6 |
| `activity_id`, `activity_name`, `type_uid` (= `600300 + activity_id`) | event type: requests, submits, spawns and publishes are Create (1); approve, reject, cancel, retry and finish are Update (3); kill and exit are Delete (4); budget refusal, auth failure, DLP and audit housekeeping are Other (99) |
| `time` | `ts` (ms) |
| `severity_id` | 1 Informational; 2 Low for 4xx and budget refusals; 3 Medium for 5xx, auth failures, kills and DLP blocks; 4 High for lost events |
| `status_id`, `status_code` | Success/Failure from the HTTP status, task status or event type |
| `message` | one-line summary |
| `metadata.version`, `.product`, `.uid`, `.sequence`, `.log_name` | `1.3.0`, Nestlo, record hash, `seq`, `agentos-audit` |
| `actor.user.name` | agent id or user name (`system` when none) |
| `api.operation`, `api.response.code`, `http_response.code` | event type, HTTP status |
| `src_endpoint.svc_name` (and `.ip` for auth failures) | producing service, client address |
| `dst_endpoint.svc_name` | provider |
| `unmapped` | everything else in `data` (model, cost, tokens, task id, ...) and `peer` |

Syslog messages are RFC 5424: `<PRI>1 TIMESTAMP HOST agentos-audit - TYPE
[agentos@32473 seq=".." hash=".." type=".." actor=".."] {OCSF JSON}`, facility
13 (log audit), severity derived from the OCSF severity.

## Limits

* The log is **tamper-evident, not tamper-proof**. Root can stop the writer,
  delete everything and start over; what survives is whatever you exported.
  Use the SIEM export (it includes the signed checkpoints) and keep the public
  key elsewhere.
* Truncating the end of the log removes records without breaking the chain;
  only a later checkpoint or the SIEM copy reveals it. `verify` reports how
  many tail records are uncovered by a checkpoint.
* An attacker with the signing key (it lives in the writer's memory and
  credentials) can forge checkpoints. Keep the writer's host hardened.
* Clocks: `ts` comes from the host clock; run NTP.
* Dropped events when the writer is away (non-strict) are counted but not
  recoverable.

## Control mapping

| Framework | Requirement | How this feature helps |
|:---|:---|:---|
| **EU AI Act Art. 12** (record-keeping) | High-risk AI systems must technically allow automatic recording of events over their lifetime, enough to identify risk situations and support post-market monitoring and operation monitoring | Every model request (agent, provider, model, status, cost, tokens), refusal, authentication failure, task decision and agent lifecycle event is recorded with a timestamp and sender identity, in order, without gaps |
| **Art. 19** (automatically generated logs, providers) | Providers keep the logs under their control for a period appropriate to the purpose, at least six months | `retentionDays` default 183; deletion is itself logged; export keeps an independent copy |
| **Art. 26(6)** (deployers) | Deployers keep the logs automatically generated by the high-risk system for at least six months | Same default; a build warning if you set less |
| **SOC 2 CC7.2** | Monitor system components and anomalies indicative of malicious acts, natural disasters and errors | Auth failures, budget refusals, DLP findings, kills and circuit events are recorded and streamed to the SIEM as OCSF; strict mode and `audit.dropped` make gaps visible |
| **SOC 2 CC7.3 / CC7.4** | Evaluate security events; respond | `agentos-audit tail` and `verify`, structured OCSF events with severity, actor and sequence for incident timelines |
| **ISO/IEC 27001:2022 A.8.15** (logging) | Logs recording activities, exceptions, faults and other relevant events shall be produced, stored, protected and analysed | Produced (events above), stored (retention, rotation), protected (separate writer user, append-only socket protocol, hash chain, signed checkpoints, root-only key) and analysed (SIEM export) |
| **ISO/IEC 27001:2022 A.8.16 / A.8.17** | Monitoring activities; clock synchronisation | SIEM export; NTP is the operator's duty (see Limits) |

This is engineering support for those controls, not a compliance
certification; which obligations apply to you, and what counts as "events"
for your system, is for your own assessment.
