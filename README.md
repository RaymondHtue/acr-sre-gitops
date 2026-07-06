# acr-sre-day2 - EKS GitOps Infra

GitOps repo for EKS cluster `accor-resilient-eks-dev`. ArgoCD ApplicationSet reads JSON configs here and deploys infra Helm charts automatically.

## How it works

`appset.yaml` is an ArgoCD `ApplicationSet` with a matrix generator:

1. Reads `infra-configs/common/*.json` (all clusters) or `infra-configs/<cluster>/*.json` (cluster-specific)
2. Each JSON defines one Helm app - repo, chart, version, namespace, values path
3. Values are layered: `infra-values/<app>/default.yaml` → `infra-values/<app>/<clusterName>.yaml`

## Managed apps

| App | Chart | Version | Namespace |
|-----|-------|---------|-----------|
| `karpenter` | `oci://public.ecr.aws/karpenter/karpenter` | 1.13.0 | `kube-system` |
| `aws-load-balancer-controller` | `https://aws.github.io/eks-charts` | 3.4.0 | `kube-system` |
| `eso` (External Secrets) | `https://charts.external-secrets.io` | 2.6.0 | `external-secrets-system` |

## Repo layout

```
appset.yaml                          # ArgoCD ApplicationSet - the entry point
infra-configs/
  common/*.json                      # Apps deployed to every cluster
  accor-resilient-eks-dev/*.json     # Apps scoped to this cluster only
infra-values/
  <app>/default.yaml                 # Base Helm values
  <app>/<clusterName>.yaml           # Cluster override values
docs/
  charts/gateway-config/             # Local Helm chart: Gateway + GatewayClass
  demo-test/                         # Demo kustomize nginx app (dev/bluestage/greenstage overlays)
  notes/alb-gateway-gatewayclass/    # Reference manifests for ALB Gateway setup
  karpenter-manifests/               # NodePool manifest
scripts/
  getpods.sh                         # List pods on infra-tainted nodes
argo-install.sh                      # One-shot ArgoCD bootstrap into cluster
```

## Bootstrap

```bash
# 1. Install ArgoCD
bash argo-install.sh

# 2. Apply the ApplicationSet
kubectl apply -f appset.yaml

# 3. Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Adding an app

1. Create `infra-configs/common/<app>.json` (or `infra-configs/<cluster>/<app>.json` for cluster-scoped)
2. Add `infra-values/<app>/default.yaml` and `infra-values/<app>/accor-resilient-eks-dev.yaml`
3. Commit - ArgoCD picks up the new Application automatically

## Key details

- Karpenter runs on `node.kubernetes.io/purpose=infra` nodes (taint toleration + nodeSelector)
- AWS LBC has `ALBGatewayAPI: true` feature gate; GatewayClass `accor-aws-alb` uses controller `gateway.k8s.aws/alb`
- ESO connects to AWS Secrets Manager via Pod Identity (no static credentials) / not tested yet
- `syncPolicy.automated` with `prune: true` and `selfHeal: true` on all apps
