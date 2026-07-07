# Runbook — KEDA 10x Traffic Spike Test

> If load is running but nothing scales, see [`troubleshooting.md`](./troubleshooting.md).

## Prerequisites

- [ ] `kubectl` context set to `accor-resilient-eks-dev`
- [ ] `kube-prometheus-stack` running in `monitoring` namespace
- [ ] `karpenter` running in `kube-system` namespace
- [ ] `nginx` kustomization dev overlay deployed in `testing-dev` namespace
- [ ] NodePool CPU limit ≥ 20 (check: `kubectl get nodepool default -o jsonpath='{.spec.limits.cpu}'`)

---

## Step 1 — Deploy nginx stub_status config + sidecar

```bash
kubectl apply -f demo-app/demo-nginx-kustomization/base/nginx-stub-status-conf.yaml -n testing-dev
```

Apply updated deployment (manually, since kustomize overlay needs sync):
```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-dev
  namespace: testing-dev
spec:
  template:
    spec:
      containers:
      - name: nginx-dev
        volumeMounts:
        - name: nginx-stub-status-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
      - name: nginx-exporter
        image: nginx/nginx-prometheus-exporter:1.4.1
        args:
          - -nginx.scrape-uri=http://localhost:8080/stub_status
        ports:
        - containerPort: 9113
          name: metrics
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        livenessProbe:
          httpGet:
            path: /metrics
            port: 9113
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /metrics
            port: 9113
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: nginx-stub-status-conf
        configMap:
          name: nginx-stub-status-conf
          items:
          - key: default.conf
            path: default.conf
EOF
```

Wait for rollout:
```bash
kubectl rollout status deploy/nginx-dev -n testing-dev
```

---

## Step 2 — Verify exporter metrics

```bash
kubectl port-forward -n testing-dev deploy/nginx-dev 9113:9113 &
curl -s http://localhost:9113/metrics | grep nginx_http_requests_total
kill %1
```

If no metrics, check exporter logs:
```bash
kubectl logs -n testing-dev deploy/nginx-dev -c nginx-exporter --tail=20
```

---

## Step 3 — Apply Service port + ServiceMonitor

Patch Service to add metrics port:
```bash
kubectl patch svc nginx-dev -n testing-dev --type='json' -p='[
  {"op": "add", "path": "/spec/ports/-", "value": {"name": "metrics", "port": 9113, "targetPort": 9113, "protocol": "TCP"}}
]'
```

Apply ServiceMonitor:
```bash
kubectl apply -f demo-app/demo-nginx-kustomization/base/servicemonitor.yaml -n testing-dev
```

Verify Prometheus target:
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
# Open: http://localhost:9090/targets → filter "nginx"
# Should show one target UP in testing-dev namespace
```

Verify PromQL returns data:
```bash
curl -s 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total' | jq '.data.result | length'
# Should return >= 1
kill %1
```

---

## Step 4 — Deploy KEDA

Push `keda.json` to git (ArgoCD ApplicationSet auto-discovers):
```bash
git add infra-configs/common/keda.json infra-values/keda/
git commit -m "feat: add KEDA for workload scaling test"
git push
```

Wait for ArgoCD sync (or trigger manual refresh):
```bash
kubectl get app -n argocd keda-accor-resilient-eks-dev -w
```

Or trigger sync:
```bash
argocd app sync keda-accor-resilient-eks-dev
```

Wait for KEDA pods:
```bash
kubectl get pods -n keda -w
# Expect: keda-operator-xxx, keda-metrics-apiserver-xxx
```

---

## Step 5 — Apply ScaledObject

```bash
kubectl apply -f demo-app/demo-nginx-kustomization/base/scaledobject.yaml -n testing-dev
```

Wait for HPA to appear:
```bash
kubectl get hpa -n testing-dev -w
# Expect: keda-hpa-nginx-scaledobject (min=1, max=30, TARGETS: 0/50)
```

Check ScaledObject status:
```bash
kubectl get scaledobject -n testing-dev
kubectl describe scaledobject nginx-scaledobject -n testing-dev
```

---

## Step 6 — Open observability terminals

Open 4 separate terminals:

**Terminal 1 — Pods:**
```bash
kubectl get pods -n testing-dev -w
```

**Terminal 2 — HPA:**
```bash
kubectl get hpa -n testing-dev -w
```

**Terminal 3 — Nodes (Karpenter provisioning):**
```bash
kubectl get nodes -w --show-labels
```

**Terminal 4 — Karpenter logs:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f --tail=50
```

---

## Step 7 — Run load generator

```bash
kubectl apply -f demo-app/wordload-scaling-testing/load-generator-job.yaml -n testing-dev
```

Watch the containers run sequentially:
```bash
kubectl get pods -n testing-dev -l job-name=load-generator -w
```

Check load generator logs:
```bash
kubectl logs -n testing-dev job/load-generator -c phase1-baseline -f &
kubectl logs -n testing-dev job/load-generator -c phase2-spike -f &
kubectl logs -n testing-dev job/load-generator -c phase3-sustain -f &
kubectl logs -n testing-dev job/load-generator -c phase4-cooldown -f &
```

---

## Step 8 — Observe scaling timeline

```
Phase │ Time      │ Expected Behavior
──────┼───────────┼─────────────────────────────────────
  1   │ 0-120s    │ 1 pod, HPA target ~0-10/50, steady
  2   │ 120-150s  │ HPA target spikes >50, KEDA triggers scale-up
  2   │ 150-240s  │ Pods scale 1→3→5→10→15 (HPA steps up in 4-pod increments)
  2-3 │ 240-420s  │ Karpenter launches new nodes ("launched nodeclaim")
  3   │ 300-420s  │ 15-30 pods running, HPA target stabilizes near 50
  4   │ 420-600s  │ Traffic drops, HPA target drops below 50
  4   │ 600s+     │ Cooldown (300s) + scale-down, pods return to 1
```

Check Karpenter provisioning decisions:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -E "launched|nodeclaim|consolidat|disruption"
```

Check node count:
```bash
kubectl get nodes -l karpenter.sh/nodepool=default --show-labels
```

---

## Step 9 — Verify Prometheus metrics during spike

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
```

Key PromQL queries:
```promql
# Request rate (the KEDA scaling metric)
sum(rate(nginx_http_requests_total{namespace="testing-dev"}[1m]))

# Active connections
nginx_connections_active{namespace="testing-dev"}

# Pod count
count(count by (pod) (nginx_http_requests_total{namespace="testing-dev"}))

# Node count
count(kube_node_info)
kill %1
```

---

## Step 10 — Cleanup

```bash
# Delete load generator job
kubectl delete job load-generator -n testing-dev

# Delete ScaledObject (HPA auto-deleted)
kubectl delete scaledobject nginx-scaledobject -n testing-dev

# Verify HPA gone
kubectl get hpa -n testing-dev

# Karpenter auto-consolidates nodes after ~30s
# Watch: kubectl get nodes -w

---

## Rollback

If KEDA misbehaves:
```bash
kubectl delete scaledobject nginx-scaledobject -n testing-dev
kubectl scale deploy nginx-dev -n testing-dev --replicas=1
kubectl delete -f demo-app/wordload-scaling-testing/load-generator-job.yaml -n testing-dev
```

If Karpenter overprovisions:
```bash
kubectl get nodeclaims -l karpenter.sh/nodepool=default
kubectl delete nodeclaim <name>
```

---

## Key Metrics to Record

| Metric | Baseline | During Spike | Post-Spike |
|--------|----------|--------------|------------|
| Pod count | 1 | ≥15 | 1 |
| Node count | N | N+1 to N+3 | N |
| HPA current/50 | 0-10 | 40-55 | 0-10 |
| Time to max pods | — | ~2-3 min | — |
| Time to first new node | — | ~2-3 min | — |
| Karpenter consolidate time | — | — | ~30-60s |
