# Registry schema

## index.yaml

```yaml
pipelines:
  - sourceId: <string>          # required. Matches LogSource.spec.sourceId.
    fingerprint: <string>       # optional. Empty = wildcard for the source.
    family: <string>            # optional. One of: json, klog, kv, regex.
                                # Used by the operator's family fallback.
    ocsfClass: <int>            # required. OCSF class_uid the VRL emits.
    description: <string>       # optional. Human-readable summary.
    vrl: |                      # required. Vector Remap Language program.
      <multi-line VRL>
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

## VRL gotchas (Vector 0.38)

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
