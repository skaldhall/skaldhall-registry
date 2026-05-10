# skaldhall-registry

Community-maintained Bragi pipelines: each entry is a Vector Remap Language
(VRL) program that parses a known log source and emits OCSF v1.5 records.

The Bragi operator fetches `index.yaml` from this repo at startup and
re-checks every 5 minutes. When a new ParserDraft appears for a source
that already has a registry entry, the operator skips the LLM round-trip
and uses the registry VRL directly (`reason=Registry`, `confidence=1.0`).

## What's in here

| Path | Purpose |
|---|---|
| `index.yaml` | Aggregate file the operator fetches. Auto-generated from `pipelines/*.yaml`. **Don't edit by hand** — edit the per-pipeline file and re-run `scripts/build-index.sh`. |
| `pipelines/<source-id>.yaml` | One file per pipeline. Source of truth for VRL + metadata. |
| `samples/<source-id>.txt` | Representative raw log lines used to author + test the VRL. Lines starting with `#` are comments. |
| `scripts/validate.sh` | Validation harness. Runs Vector against samples + a candidate VRL and asserts: every input → an output record, no `unmapped` key, all of `class_uid|time|severity_id|metadata` present. |
| `scripts/build-index.sh` | Regenerates `index.yaml` from `pipelines/*.yaml`. |

## Pipelines (58)

| sourceId | OCSF | family | description |
|---|---|---|---|
| antrea-flow | 4001 | json | Antrea Flow Aggregator JSONL |
| apparmor | 1001 | kv | Linux kernel AppArmor audit |
| calico-dns | 4003 | json | Calico DNS logs |
| calico-felix | 6008 | regex | Calico Felix log |
| calico-flow | 4001 | json | Calico flow logs |
| certmanager | 6002 | json | cert-manager controller log (zap) |
| coraza | 2004 | json | Coraza WAF audit JSON |
| cosign-verify | 2004 | json | Sigstore cosign verify log |
| crowdsec | 2004 | json | CrowdSec alerts/decisions |
| envoy-rbac | 3005 | json | Envoy ext_authz / RBAC filter log |
| etcd-access | 6003 | json | etcd access log (zap JSON) |
| etcd-audit | 6003 | json | etcd request audit log (zap JSON) |
| externalsecrets-event | 7001 | json | External Secrets Operator events (zerolog) |
| falco | 2004 | json | Falco rule firings |
| gatekeeper-audit | 2004 | json | OPA Gatekeeper audit log |
| gatekeeper-violation | 2004 | json | OPA Gatekeeper Constraint violations |
| haproxy | 4002 | regex | HAProxy httplog |
| harbor-audit | 6003 | json | Harbor registry audit log |
| hubble-flow | 4001 | json | Cilium Hubble flow logs |
| hubble-policy | 4001 | json | Cilium Hubble policy verdicts |
| inspektor-gadget | 1007 | json | Inspektor Gadget eBPF event JSONL |
| istio-authzpolicy-deny | 3005 | json | Istio AuthorizationPolicy deny |
| istio-envoy-access | 4002 | json | Istio Envoy access log (default JSON) |
| journald | 6008 | regex | systemd journald entries |
| jspolicy-violation | 2004 | json | jsPolicy violation log |
| kube-apiserver-audit | 6003 | json | kube-apiserver AdvancedAudit log |
| kube-apiserver-server | 6008 | klog | kube-apiserver process log (klog) |
| kube-controller-manager | 6002 | klog | kube-controller-manager log (klog) |
| kube-events | 7001 | json | Kubernetes events.k8s.io v1.Event |
| kube-scheduler | 6002 | klog | kube-scheduler log (klog) |
| kubearmor | 1007 | json | KubeArmor process/file/network alerts |
| kubebench | 2006 | json | kube-bench CIS test results |
| kubehunter | 2002 | json | kube-hunter scan findings |
| kubelet | 6008 | klog | kubelet log (klog) |
| kubewarden-audit | 6003 | json | Kubewarden audit log |
| kuma-dp | 4002 | json | Kuma DP / Envoy access log |
| kyverno-admission | 6003 | json | Kyverno admission webhook log |
| kyverno-policyreport | 2004 | json | Kyverno PolicyReport rows |
| linkerd-proxy | 4002 | regex | linkerd2-proxy structured tracing |
| linux-auditd | 1007 | kv | Linux auditd kernel events |
| nginx-ingress-access | 4002 | regex | NGINX Ingress access log |
| nginx-ingress-error | 6008 | regex | NGINX Ingress error log |
| pixie | 6008 | json | Pixie agent stdout / OTLP |
| polaris-finding | 2006 | json | Polaris audit findings |
| sealedsecrets | 6002 | klog | Sealed Secrets controller log (klog) |
| selinux | 1007 | kv | Linux kernel SELinux AVC audit |
| stackrox | 2004 | json | StackRox sensor/collector alerts |
| suricata-eve | 4001 | json | Suricata eve.json |
| sysdig-oss | 1007 | json | Sysdig OSS event JSON |
| tekton-chains | 6002 | json | Tekton Chains attestation events |
| tetragon | 1007 | json | Cilium Tetragon process events |
| tracee | 1007 | json | Aqua Tracee syscall/eBPF events |
| traefik-access | 4002 | json | Traefik access log JSON |
| trivy-configaudit | 2006 | json | Trivy ConfigAuditReport |
| trivy-exposedsecret | 2004 | json | Trivy ExposedSecretReport |
| trivy-vulnerabilityreport | 2002 | json | Trivy VulnerabilityReport |
| vault-audit | 6003 | json | HashiCorp Vault audit log |
| zeek | 4001 | json | Zeek conn/dns/http JSON logs |

## Wiring Bragi at this registry

Set the chart value `operator.registryUrl` to the raw URL of `index.yaml`
on the branch you want Bragi to follow:

```bash
helm install bragi oci://ghcr.io/skaldhall/bragi/charts/bragi \
  --version 0.6.5 \
  --namespace siem --create-namespace \
  --set openai.existingSecret=bragi-openai \
  --set opensearch.url=https://os.example.com:9200 \
  --set operator.registryUrl=https://raw.githubusercontent.com/skaldhall/registry/main/index.yaml
```

## How the lookup works

The Bragi operator's `registry.Lookup(sourceId, fingerprint, family)` matches
in this order — first match wins:

1. **Exact** — `Entry.fingerprint == fingerprint` (full hash).
2. **Prefix** — `Entry.fingerprint` is a prefix of `fingerprint` (≥8 chars).
3. **Wildcard** — `Entry.fingerprint == ""` (matches any fingerprint for the source).
4. **Family fallback** — `Entry.family == family` and `family != ""`.

Most pipelines in this registry use **wildcard fingerprint** (`fingerprint: ""`)
because:

- The fingerprint is the operator's content hash of the line shape — small
  format changes (a new field, reordered keys for JSON) flip the hash.
- A wildcard match means the canonical parser runs for *any* shape the
  source emits, so onboarding is friction-free.
- If you want to pin a specific shape, set `fingerprint` to the first
  16 hex chars of the shape hash and the prefix matcher will catch it.

## What's NOT in here

- The Bragi operator binary. That's at `github.com/skaldhall/bragi`.
- Sigma rules. Bragi auto-attaches OpenSearch Security Analytics detectors
  for OCSF classes that map to a Sigma category (1007 → linux,
  4001 → network, 4002 → others_web, 4003 → dns, 6003 → cloudtrail).
  Findings are emitted by SA, not by the parser.
- LLM prompts. When a source isn't in this registry the operator falls
  back to its parser-generator service (OpenAI under the hood).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) and [SCHEMA.md](./SCHEMA.md).

## License

(TBD before public release.)
