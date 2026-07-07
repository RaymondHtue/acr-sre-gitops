# ACR SRE \- EKS GitOps Infra

This repository manages the EKS cluster *accor-resilient-eks-dev* using a GitOps approach. Our ArgoCD ApplicationSet uses a matrix generator to read JSON configurations and automatically deploy the necessary infrastructure via Helm charts.

## Architecture
![Structure](./docs/images/architecture.png)

## How it works

The *platform-platform-platform-appset.yaml* file acts as the heart of our automation. It uses a matrix generator to coordinate deployments across the environment:

• It identifies configurations from \`infra-configs/common/\*.json\` for global apps or cluster-specific directories for targeted deployments.  
• Every JSON file defines a Helm application, including its repository, chart version, and destination namespace.  
• We use a layered values approach, starting with \`default.yaml\` and applying cluster-specific overrides as needed.

## Managed apps

| App | Chart | Repo | Version | Namespace |
| :---- | :---- | :---- | :---- | :---- |
| karpenter | karpenter | oci://public.ecr.aws/karpenter/karpenter | 1.13.0 | kube-system |
| aws-load-balancer-controller | aws-load-balancer-controller | https://aws.github.io/eks-charts | 3.4.0 | kube-system |
| eso (External Secrets) | external-secrets | https://charts.external-secrets.io | 2.6.0 | external-secrets-system |
| keda | keda | https://kedacore.github.io/charts | 2.16.1 | keda |
| kube-prometheus-stack | kube-prometheus-stack | https://prometheus-community.github.io/helm-charts | 87.10.1 | monitoring |
| metrics-server | metrics-server | https://kubernetes-sigs.github.io/metrics-server/ | 3.13.1 | kube-system |

alb-gateway-config is present but **disabled** (alb-gateway-config.json\_ — trailing underscore keeps it out of the \*.json glob).

## Repo layout

```
platform-platform-appset.yaml                          # ArgoCD ApplicationSet - the entry point
infra-configs/
  common/*.json                      # Apps deployed to every cluster
  accor-resilient-eks-dev/*.json     # Apps scoped to this cluster only
infra-values/
  <app>/default.yaml                 # Base Helm values
  <app>/<clusterName>.yaml           # Cluster override values
demo-app/                           # Scaling/deployment demos (nginx kustomize app, KEDA/Karpenter tests)
docs/
  charts/gateway-config/             # Local Helm chart: Gateway + GatewayClass
  notes/alb-gateway-gatewayclass/    # Reference manifests for ALB Gateway setup
  karpenter-manifests/               # NodePool manifest
scripts/
  getpods.sh                         # List pods on infra-tainted nodes
  argo-install.sh                      # One-shot ArgoCD bootstrap into cluster
```

## Bootstrap

```shell
# 1. Install ArgoCD
bash argo-install.sh

# 2. Apply the ApplicationSet
kubectl apply -f platform-appset.yaml

# 3. Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Adding an app

1\. Start by creating a new JSON configuration in the appropriate \`infra-configs\` directory.  
2\. Next, define the Helm values by adding a \`default.yaml\` and any necessary cluster overrides.  
3\. Once we commit these changes, ArgoCD automatically recognizes and provisions the new application.

## Key details

• Our Karpenter setup is designed to run specifically on nodes marked with the \`infra\` purpose for better resource isolation.  
• The AWS Load Balancer Controller is configured with the ALB Gateway API enabled, utilizing a dedicated GatewayClass for traffic management.  
• We use External Secrets Operator to securely connect to AWS Secrets Manager using Pod Identity for a credential-less security model.  
• For consistency, all applications use automated synchronization with pruning and self-healing enabled.
