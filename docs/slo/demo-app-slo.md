# demo-app — SLA / SLO / SLI

This document defines the service-level objectives for `demo-app` (the nginx
demo workload) and how they are implemented on the existing kube-prometheus-stack
(Prometheus + Grafana + Alertmanager) in the `accor-resilient-eks-dev` cluster.

## Definitions

| Term | Meaning here |
|------|--------------|
| **SLI** | A measured signal of quality. We use two: **availability** (`probe_success`) and **latency** (`probe_duration_seconds`). |
| **SLO** | The internal target for each SLI over a rolling 30-day window. |
| **SLA** | The externally promised level. Deliberately looser than the SLO so we react before breaching the contract. Documented here only — no code. |

## Why blackbox probing (the metric gap)

The app exposes metrics via the `nginx-prometheus-exporter` sidecar scraping
nginx `stub_status`. That endpoint reports **connection and request counts only**
— it has **no HTTP status codes and no latency**. So it cannot produce a real
error-rate or latency SLI.

To close the gap we run a **`prometheus-blackbox-exporter`** (deployed as an
infra app) and a Prometheus-Operator **`Probe`** CR that hits the app's public
HTTPRoute URL every 15s. This measures the true end-to-end path
(client → ALB/Gateway → nginx) and yields:

- `probe_success{slo_service="demo-app"}` — 1 if a 2xx was served, else 0
- `probe_duration_seconds{slo_service="demo-app"}` — total request time

> The existing `nginx_http_requests_total` / `nginx_connections_active` metrics
> remain useful as **throughput/saturation** signals but are not the SLI.

## Targets

Targets are aligned with the design doc ("The Redemption", Section 5).

| SLI | SLO (30d) | SLA (external) | Error budget |
|-----|-----------|----------------|--------------|
| Availability | **99.9%** of probes succeed | 99.5% | 0.1% ≈ **43 min** unavailable / 30d |
| Latency | **p95 < 200 ms** | — | — |
| Error rate (5xx) | **< 0.5%** | — | needs request-level source (see note) |

> **Error-rate note:** a real 5xx-rate SLI needs HTTP status codes per request.
> nginx `stub_status` and the blackbox probe don't provide them, so until an
> ALB access-log/CloudWatch metric or a status-code-aware exporter is wired, the
> availability SLI (probe non-2xx) is the working proxy for error rate.

## Implementation (all GitOps, synced by ArgoCD)

| Concern | Where |
|---------|-------|
| Prober | `infra-configs/common/blackbox-exporter.json` + `infra-values/blackbox-exporter/` |
| Raw SLI probe | `demo-app/demo-nginx-kustomization/base/probe.yaml` (hostname patched per overlay) |
| Recording + alerting rules | `demo-app/demo-nginx-kustomization/base/slo-rules.yaml` (`PrometheusRule`) |
| Dashboard | `demo-app/demo-nginx-kustomization/base/slo-dashboard-configmap.yaml` (Grafana sidecar, uid `demo-app-slo`) |
| Dashboard discovery | `grafana.sidecar.dashboards.searchNamespace: ALL` in `infra-values/kube-prometheus-stack/default.yaml` |

### Recording rules

`sli:demo_app_availability:ratio_rateNN` = `avg_over_time(probe_success[NN])`
for the windows 5m/30m/1h/2h/6h/1d/3d. `slo:demo_app_availability:target` (0.999)
and `:error_budget` (0.001) are published as constants for the dashboard.
Latency has `sli:demo_app_latency_p95:seconds_rate{5m,1h}` =
`quantile_over_time(0.95, probe_duration_seconds[...])`, target
`slo:demo_app_latency_p95:target_seconds` (0.2).

### Error-budget burn alerts (Google SRE multi-window, multi-burn-rate)

Threshold = `burn_rate × error_budget(0.001)`; both the long and short window
must breach before firing (kills false positives):

| Alert | Burn | Long / short | Severity |
|-------|------|--------------|----------|
| `DemoAppAvailabilityErrorBudgetBurnFast` | 14.4× | 1h / 5m | critical (page) |
| `DemoAppAvailabilityErrorBudgetBurnMedium` | 6× | 6h / 30m | critical (page) |
| `DemoAppAvailabilityErrorBudgetBurnSlow` | 3× | 1d / 2h | warning (ticket) |
| `DemoAppLatencySLOBreach` | — | p95(1h) > 200ms | warning |

Alerts route through the existing Alertmanager.

## Error-budget policy (suggested)

- **Budget healthy (>25% left):** ship features freely.
- **Budget < 25%:** freeze risky changes; prioritise reliability work.
- **Budget exhausted:** feature freeze until back in budget; run a review.

## Prerequisites & notes

- The probe target must be publicly resolvable with a valid TLS cert. Dev
  overlay targets `https://traffic.maunghtoo.cloud`; base targets
  `https://nginx01.maunghtoo.cloud`. If DNS/ACM isn't ready, point the probe at
  the in-cluster service (`http://nginx-dev.testing-dev.svc:80`) instead.
- Each overlay creates its own `Probe`; series stay separated by target/instance
  labels, so rules and alerts evaluate per environment.
- 30-day availability needs Prometheus retention ≥ 30d. Dev currently runs 7d
  (`infra-values/kube-prometheus-stack/accor-resilient-eks-dev.yaml`) — raise it,
  or read the 30d window from a longer-retention/remote-write store.

## Validate locally

```bash
kubectl kustomize demo-app/demo-nginx-kustomization/overlays/dev
promtool check rules demo-app/demo-nginx-kustomization/base/slo-rules.yaml
jq . infra-configs/common/blackbox-exporter.json
```
