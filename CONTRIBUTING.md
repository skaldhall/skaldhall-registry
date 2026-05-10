# Contributing

## Adding a pipeline

1. Pick a `sourceId`. Convention: lowercase + dashes + a project prefix
   (`tetragon`, `kube-apiserver-audit`, `nginx-ingress-access`).

2. Drop 5–15 representative raw log lines into
   `samples/<source-id>.txt`. Each line is what Vector's
   `kubernetes_logs` source would emit on `.message` — i.e. the raw
   stdout line as printed by the source.

   The first line of the file SHOULD be a `# source: <URL>` comment
   citing where the samples came from.

3. Pick an OCSF class_uid. See [SCHEMA.md](./SCHEMA.md) for the table
   used in this registry. When in doubt, prefer 2004 (Detection Finding)
   for security alerts, 6003 (API Activity) for control-plane / mgmt
   actions, 4001/4002/4003 for network/http/dns, 1007 for process
   events, 6008 for plain operational logs.

4. Write `pipelines/<source-id>.yaml`:

   ```yaml
   sourceId: my-source
   fingerprint: ""              # leave empty unless you want to pin a shape
   family: json                 # json | klog | kv | regex
   ocsfClass: 2004
   description: One-line summary
   sample: "<copy the most representative sample line>"
   vrl: |
     src = .
     parsed = parse_json(.message) ?? {}
     . = {}
     .class_uid = 2004
     .activity_id = <int>
     .severity_id = <int>
     .time = parsed.time ?? src.timestamp ?? now()
     .metadata = {"product": {"name": "<vendor>"}, "version": "1.5.0"}
     # ... map fields ...
   ```

   The full VRL contract is in [SCHEMA.md](./SCHEMA.md).

5. Validate locally:

   ```bash
   bash scripts/validate.sh my-source samples/my-source.txt pipelines/my-source.yaml
   # or, if you keep the VRL in a separate file during authoring:
   bash scripts/validate.sh my-source samples/my-source.txt my-source.vrl
   ```

   The validator runs Vector against the samples + your VRL and asserts:
   - every input line produces an output record;
   - **no output record contains an `unmapped` key**;
   - every output has `class_uid`, `time`, `severity_id`, `metadata`.

   It needs the Vector binary on PATH or at the path pointed to by the
   `VECTOR` env var (defaults to `/home/jradikk/OpenSIEM/bin/vector` —
   override with `export VECTOR=$(which vector)`).

6. Regenerate `index.yaml`:

   ```bash
   bash scripts/build-index.sh
   ```

7. Add a row to the table in [README.md](./README.md).

8. Open a PR.

## Reviewing

- Run the harness against every changed `pipelines/*.yaml` in CI.
- Eyeball the rendered output (`tmp/out.ndjson` left by the harness on
  a successful run) to confirm the mapping makes sense — passing the
  harness only proves shape compliance, not semantic correctness.
- Reject changes that introduce an `unmapped` key in any output.

## Iterating against a real cluster

The registry only takes effect after the operator re-fetches
`index.yaml` (5-minute TTL). To force a refresh, restart the operator:

```bash
kubectl -n siem rollout restart deployment/bragi-operator
```

To verify a draft was satisfied by the registry, look at its conditions:

```bash
kubectl get parserdraft <name> -o jsonpath='{.status.conditions[?(@.type=="Generated")].reason}'
# expected: Registry
```
