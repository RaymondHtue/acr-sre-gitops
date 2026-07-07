# Troubleshooting - KEDA / Karpenter Scaling

For when load is running but pods aren't scaling. Following step helps to check

```
# scaling flow
load (hey Job) ─> nginx exporter :9113 ─> ServiceMonitor ─> Prometheus ─> KEDA ─> HPA ─> pods ─> Karpenter ─> nodes
```

Note: `nginx_http_requests_total` is a cumulative counter, so it only goes up.
KEDA doesn't scale on that number. It scales on the rate,
`sum(rate(nginx_http_requests_total{namespace="testing-dev"}[1m]))`. A large counter with a low
current rate means no scaling

## Quick check

```bash
kubectl get hpa,scaledobject,pods -n testing-dev
```

| HPA `TARGETS` | ScaledObject | Likely area | Look at |
|---------------|--------------|-------------|---------|
| `<unknown>/50` | `READY=False` | KEDA can't reach Prometheus, or bad query | Steps 4-5 |
| `0/50` | `ACTIVE=False` | Metric arrives but reads 0, no data in Prometheus | Steps 2-4 |
| `<n>/50` (n>0), pods=1 | `ACTIVE=True` | Fine, rate is just below threshold (load ended?) | Step 1 |
| `<big>/50`, some pods `Pending` | - | Fine, node capacity is the limit | Steps 6-7 |

## Step 1 - Is load running right now?

```bash
kubectl get job,pod -n testing-dev -l job-name=load-generator -o wide
```

## Step 2 - Is the exporter serving metrics?

```bash
kubectl port-forward -n testing-dev deploy/nginx-dev 9113:9113
curl -s localhost:9113/metrics | grep nginx_http_requests_total
```

The value should climb on repeat curls while load runs. If it's flat or the endpoint refuses, check
the `nginx-exporter` container logs and that nginx is listening on 8080 with the `/stub_status`
location.

## Step 3 - Can Prometheus discover the ServiceMonitor?

The stack's Prometheus only picks up ServiceMonitors whose labels match its `serviceMonitorSelector`.
Compare them:

```bash
kubectl get servicemonitor -n testing-dev nginx-servicemonitor-dev -o jsonpath='{.metadata.labels}'; echo
kubectl get prometheus -A -o jsonpath='{.items[*].spec.serviceMonitorSelector}'; echo
```

If the selector is `{"matchLabels":{"release":"kube-prometheus-stack"}}` and the ServiceMonitor is
missing `release: kube-prometheus-stack`, Prometheus quietly skips it, so there's no scrape and no
metric. See Known issues below.

## Step 4 - Does Prometheus have the target and data?

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# series present?
curl -s --data-urlencode 'query=nginx_http_requests_total' http://localhost:9090/api/v1/query

# the exact query KEDA runs:
curl -s 'query=sum(rate(nginx_http_requests_total{namespace="testing-dev"}[1m]))' \
  http://localhost:9090/api/v1/query
```

- 0 targets - discovery issue, back to Step 3.
- Target present but `up == 0` - can't reach `:9113`; check the Service `metrics` port and
  `kubectl get endpoints -n testing-dev nginx-dev`.
- Series present but the `{namespace="testing-dev"}` query is empty - label mismatch; Prometheus sets
  `namespace` from the target's namespace, so confirm the ServiceMonitor is in `testing-dev`.
- Query returns a value - Prometheus side is fine, move to Step 5. `rate([1m])` needs about
  a minute of samples after scraping starts before it means much.

## Step 5 - Is KEDA healthy?

```bash
kubectl get scaledobject -n testing-dev -o wide
kubectl describe scaledobject nginx-scaledobject-dev -n testing-dev   # events explain READY=False
kubectl logs -n keda -l app=keda-operator --tail=50
```

`READY=True ACTIVE=True` means KEDA sees a non-zero metric and owns the HPA. It's also worth confirming
the `serverAddress` in the ScaledObject resolves:
`http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`.


## Steps 6 - pods scale but stay `Pending`

That's node capacity rather than KEDA. Check Karpenter:

```bash
kubectl get nodepool default -o jsonpath='{.spec.limits}'; echo   # CPU cap 20 ~= 10 pods at 200m
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter | grep -E "launched|nodeclaim|FailedScheduling"
```

Pending pods with the NodePool at its `limits.cpu` means the ceiling is reached. Raise the limit or
lower pod CPU requests.

## Known issues

**ServiceMonitor missing the `release` label (seen 2026-07-07).**
Load at 500 req/s and the exporter counter climbing, but HPA stuck at `0/50`, ScaledObject
`ACTIVE=False`, pods at 1. Cause: `nginx-servicemonitor-dev` had no `release: kube-prometheus-stack`
label, so Prometheus never discovered it (0 targets, 0 series) and the KEDA query came back empty.


```yaml
metadata:
  name: nginx-servicemonitor
  labels:
    release: kube-prometheus-stack
```

To set it on a running ServiceMonitor without a full resync:

```bash
kubectl label servicemonitor -n testing-dev nginx-servicemonitor-dev \
  release=kube-prometheus-stack --overwrite
```

Prometheus reconciles in roughly 10-30s, re-run the load Job to see the scale-up.
