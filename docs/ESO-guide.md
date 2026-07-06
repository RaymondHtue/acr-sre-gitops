# External Secrets Operator (ESO) — Grafana Integration Guide

## How It Works

```
AWS Secrets Manager
  └─ secret key: accor-resilient-eks-dev/grafana
       ├─ admin-user
       └─ admin-password
              │
              │  ESO polls every 1h
              ▼
ClusterSecretStore: aws-secrets-manager
  (auth via EKS Pod Identity → IAM role → secretsmanager:GetSecretValue)
              │
              ▼
ExternalSecret: grafana-admin-secret  (namespace: monitoring)
              │
              ▼
Kubernetes Secret: grafana-admin-secret
              │
              ▼
kube-prometheus-stack Grafana
  grafana.admin.existingSecret: grafana-admin-secret
```

## Components

| Resource | Kind | Namespace | File |
|---|---|---|---|
| `aws-secrets-manager` | ClusterSecretStore | cluster-scoped | `infra-values/kube-prometheus-stack/accor-resilient-eks-dev.yaml` |
| `grafana-admin-secret` | ExternalSecret | monitoring | `infra-values/kube-prometheus-stack/accor-resilient-eks-dev.yaml` |
| `grafana-admin-secret` | Secret (generated) | monitoring | created by ESO |
| ESO controller | Deployment | external-secrets-system | `infra-configs/common/eso.json` |

---

## Step-by-Step Setup

### Step 1 — Create the IAM Policy

ESO needs `secretsmanager:GetSecretValue` on the Grafana secret.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:accor-resilient-eks-dev/grafana*"
    }
  ]
}
```

```bash
aws iam create-policy \
  --policy-name accor-eks-dev-eso-secrets-policy \
  --policy-document file://eso-policy.json
```

### Step 2 — Create the IAM Role for Pod Identity

```bash
# Create trust policy for EKS Pod Identity
cat > eso-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

aws iam create-role \
  --role-name accor-eks-dev-eso-role \
  --assume-role-policy-document file://eso-trust-policy.json

aws iam attach-role-policy \
  --role-name accor-eks-dev-eso-role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/accor-eks-dev-eso-secrets-policy
```

### Step 3 — Create the Pod Identity Association

Links the IAM role to the ESO controller's Kubernetes service account.

```bash
aws eks create-pod-identity-association \
  --cluster-name accor-resilient-eks-dev \
  --namespace external-secrets-system \
  --service-account external-secrets \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/accor-eks-dev-eso-role
```

### Step 4 — Store the Secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name accor-resilient-eks-dev/grafana \
  --region us-east-1 \
  --secret-string '{
    "admin-user": "admin",
    "admin-password": "<strong-password-here>"
  }'
```

To rotate the password later:

```bash
aws secretsmanager update-secret \
  --secret-id accor-resilient-eks-dev/grafana \
  --secret-string '{
    "admin-user": "admin",
    "admin-password": "<new-password>"
  }'
```

ESO syncs the new value within 1 hour (or force a sync — see Troubleshooting).

### Step 5 — Deploy via ArgoCD

ESO controller deploys first (it is in `infra-configs/common/eso.json`). ArgoCD syncs it automatically.

Once ESO is running, sync kube-prometheus-stack:

```bash
argocd app sync kube-prometheus-stack-accor-resilient-eks-dev
```

ArgoCD deploys:
1. ClusterSecretStore
2. ExternalSecret
3. Grafana (picks up the generated secret on startup)

### Step 6 — Verify

```bash
# ClusterSecretStore should show Ready
kubectl get clustersecretstore aws-secrets-manager

# ExternalSecret should show SecretSynced
kubectl get externalsecret grafana-admin-secret -n monitoring

# Secret should exist
kubectl get secret grafana-admin-secret -n monitoring

# Check Grafana pod is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
```

---

## Troubleshooting

### ExternalSecret stuck in NotReady

```bash
kubectl describe externalsecret grafana-admin-secret -n monitoring
```

Common causes:
- IAM role not associated with the `external-secrets` service account → recheck Step 3
- Secret path wrong in AWS SM → verify `accor-resilient-eks-dev/grafana` exists in `us-east-1`
- ESO controller pod not running → `kubectl get pods -n external-secrets-system`

### Force ESO re-sync immediately

```bash
kubectl annotate externalsecret grafana-admin-secret \
  -n monitoring \
  force-sync=$(date +%s) \
  --overwrite
```

### ClusterSecretStore auth failure

```bash
kubectl describe clustersecretstore aws-secrets-manager
```

If you see `AccessDeniedException`, the Pod Identity association is missing or the IAM policy does not cover the secret ARN. Verify:

```bash
aws eks list-pod-identity-associations \
  --cluster-name accor-resilient-eks-dev \
  --namespace external-secrets-system
```

### Grafana still using old password

Grafana reads the secret only on pod start. Restart after ESO syncs:

```bash
kubectl rollout restart deployment -n monitoring -l app.kubernetes.io/name=grafana
```

---

## Adding More Secrets

To pull additional secrets (e.g., SMTP credentials, OAuth client secret), add entries to the ExternalSecret in `infra-values/kube-prometheus-stack/accor-resilient-eks-dev.yaml`:

```yaml
data:
  - secretKey: admin-user
    remoteRef:
      key: accor-resilient-eks-dev/grafana
      property: admin-user
  - secretKey: admin-password
    remoteRef:
      key: accor-resilient-eks-dev/grafana
      property: admin-password
  # add more fields from the same secret, or a different secret key entirely
  - secretKey: smtp-password
    remoteRef:
      key: accor-resilient-eks-dev/grafana-smtp
      property: password
```

The generated Kubernetes secret `grafana-admin-secret` will contain all mapped keys.
