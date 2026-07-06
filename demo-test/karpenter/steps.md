Order of operations:

# 1. Apply karpenter TF stack (creates IAM + SQS + pod identity + access entry)
```
cd us-east-1/dev/karpenter
terragrunt apply
```

# 2. Deploy Karpenter via ArgoCD/Helm (GitOps)
#    Use gitops/karpenter/helm-values.yaml

# 3. Apply CRDs after controller is Running
```
kubectl apply -f gitops/karpenter/ec2nodeclass.yaml
kubectl apply -f gitops/karpenter/nodepool.yaml
```

# 4. Verify
```
kubectl get ec2nodeclass,nodepool
kubectl logs -n kube-system -l app.kubernetes.io
```
```
ArgoCD Application snippet:
source:
  repoURL: public.ecr.aws/karpenter
  chart: karpenter
  targetRevision: 1.3.3
  helm:
    valuesObject:
      settings:
        clusterName: resilient-eks-redemption-de
        clusterEndpoint: "https://4451DE56AF9D23B7CD641F0BE1C6A320.gr7.us-east-1.eks.amazonaws.com"
        interruptionQueue: Karpenter-resilient-e
      tolerations:
        - key: node.kubernetes.io/purpose
          operator: Equal
          value: infra
          effect: NoSchedule
      nodeSelector:
        node.kubernetes.io/purpose: infra
      replicas: 2
```
