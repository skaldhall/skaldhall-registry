# Registry schema

## index.yaml

```yaml
pipelines:
  - sourceId: <string>          # required. Matches LogSource.spec.sourceId.
    fingerprint: <string>       # optional. Empty = wildcard for the source.
    family: <string>            # optional. One of: json, klog, kv, regex.
                                # Used by the operator's family fallback.
    ocsfClass: <int>            # required. The PRIMARY class — pipeline identity
                                # and default index. Advisory: routing uses the
                                # class_uid the VRL actually sets per record.
    emits: [<int>, ...]         # optional. EVERY class the VRL can emit; drives
                                # index-template pre-creation. Empty = [ocsfClass].
    classByKey: {<str>: <int>}  # optional, legacy. Wrapper-key -> class.
    reduce: {...}               # optional. Stateful event merging (see below).
    merge_lines: {...}          # optional. Raw-line pairing at the edge (below).
    description: <string>       # optional. Human-readable summary.
    vrl: |                      # required. Vector Remap Language program.
      <multi-line VRL>
```

> **Adding a new top-level field is TWO changes.** `scripts/build-index.sh` has
> a `FIELDS` allow-list and copies only what it knows; a field missing from it
> is silently dropped from `index.yaml` and the operator never sees it (this is
> how `emits` was lost once). Add it to `FIELDS`, to the emit block below it,
> **and** to `registry.Entry` in the operator.

### `merge_lines` — pairing raw lines at the edge

For sources that split one logical event across consecutive lines (cloudflared
logs a request line and its response line, with no shared id). Rendered by the
operator into the **LogSource input fragment** — the Vector instance tailing the
pod — where that pod's lines arrive in file order:

```yaml
merge_lines:
  when_regex: '\sDBG\s'                    # optional gate: which lines pair at all
  key_regex: 'connIndex=(?P<key>\d+)'       # required: named group `key` = group id
  starts_when_regex: '\s(GET|POST)\s+https?://'   # the line that OPENS a pair
  expire_after_ms: 3000                     # unpaired halves flush alone after this
```

Joined lines arrive at the VRL as ONE `.message` separated by newlines, so the
parser must handle both halves in a single pass. Grouping is per `(pod, key)`.

> **Why the edge, not the pipeline.** The pipeline DaemonSet shares one
> JetStream consumer, so a pair's two lines land on *different* Vector pods
> whose state never meets — and `connIndex`-style ids are not unique across
> pods. Pipeline-level merging looks fine on a single-node dev cluster and
> merges nothing in production.

### `reduce` — stateful merging in the pipeline

Vector `reduce` options passed through verbatim (`group_by`, `starts_when`,
`ends_when`, `expire_after_ms`, `merge_strategies`), applied to **parsed events**
between parse and route. Only sound when a single consumer sees every related
event — for per-pod line pairing use `merge_lines` instead.

```yaml
reduce:
  group_by: ["connection_info.uid"]
  starts_when: "exists(.http_request.http_method)"
  expire_after_ms: 3000
  merge_strategies:
    severity_id: max            # numbers otherwise SUM across merged events
    class_uid: discard
    raw_data: concat_newline
```

The operator fetches `index.yaml`, caches it for 5 minutes, and on every new
ParserDraft calls `registry.Lookup(sourceId, fingerprint, family)` against
the cached set.

## pipelines/<source-id>.yaml

Same schema as one row of `index.yaml`, plus an extra `sample:` field that
holds one representative raw log line. The `sample` is illustrative only —
the operator never reads it.

## VRL contract

Each VRL is run inside a Vector `remap` transform downstream of an envelope
transform that has already added: `source_id`, `vector_host`, `observed_at`.
The input event's `.message` field contains the raw log line; on Kubernetes,
the input also has a `.kubernetes` object with pod metadata.

A VRL must produce a record that:

1. Has all four required OCSF fields:
   - `.class_uid` (int) — pick from OCSF v1.5.
   - `.time` (timestamp) — the event time, not Vector's read time.
   - `.severity_id` (int) — 0 unknown, 1 informational, 2 low, 3 medium,
     4 high, 5 critical, 6 fatal.
   - `.metadata` (object) — must include `metadata.product.name`.
2. Has **no `unmapped` key**. The validation harness asserts this.
3. Maps every documented field of the source into a stable OCSF path.

The standard pattern that guarantees no `unmapped`:

```vrl
src = .
parsed = parse_json(.message) ?? {}
. = {}                               # ← reset; the only way to ensure
                                     #   nothing leaks into `unmapped`
.class_uid = <int>
.activity_id = <int>
.severity_id = <int>
.time = parsed.time ?? src.timestamp ?? now()
.metadata = {"product": {"name": "<vendor>", "vendor_name": "<vendor>"}, "version": "1.5.0"}
# ... map known fields ...
```

## OCSF classes used in this registry

| class_uid | Name | Used for |
|---|---|---|
| 1001 | File Activity | AppArmor / SELinux file ops |
| 1007 | Process Activity | Tetragon / KubeArmor / Tracee / auditd / SELinux exec |
| 2002 | Vulnerability Finding | Trivy VulnerabilityReport, kube-hunter |
| 2004 | Detection Finding | Falco, IDS alerts, policy violations, WAF, secrets |
| 2006 | Compliance Finding | Polaris, kube-bench, Trivy ConfigAudit |
| 3005 | Authorization | Envoy RBAC denials, Istio AuthZ deny |
| 4001 | Network Activity | Hubble flow, Calico flow, Antrea, Suricata flow, Zeek conn |
| 4002 | HTTP Activity | NGINX/Traefik/HAProxy access, Istio Envoy, Linkerd, Kuma |
| 4003 | DNS Activity | Calico DNS, Suricata dns, Zeek dns |
| 6002 | Application Lifecycle | kube-scheduler/-controller, cert-manager, sealed-secrets, Tekton Chains |
| 6003 | API Activity | apiserver audit, etcd, Vault audit, Kyverno admission, Harbor |
| 6008 | Application Error | apiserver-server, kubelet, journald, Pixie, Felix |
| 7001 | Entity Management | k8s events, External Secrets |

## VRL gotchas (Vector 0.50 — vendored at `~/bragi/bin/vector`)

- `to_string(x) ?? ""` errors with E651 when `x` is statically known.
  Use `string(x) ?? ""` (the type-asserter) instead, or skip `??` entirely.
- After `parsed = parse_json(.message)`, the compiler narrows the type
  if you check the error first. Use `parsed = parse_json(.message) ?? {}`
  directly so `parsed.foo` stays fallible.
- `from_unix_timestamp(int, unit: "seconds")` is the timestamp constructor.
  Not `to_timestamp`.
- `keys(obj)` returns the key list. Not `object_keys`.
- klog timestamps don't include a year — synthesize from `now()`'s year
  via `format_timestamp!(now(), format: "%Y")`.
- When mapping arrays of findings (Trivy `vulnerabilities[]`, Kyverno
  `results[]`, etc.), VRL doesn't fan out one input → many outputs.
  Convention: pick the severest entry as the headline mapping and stash
  `.count = length(arr)` so the UI surfaces the rest.

## Adding a pipeline

See [CONTRIBUTING.md](./CONTRIBUTING.md).
