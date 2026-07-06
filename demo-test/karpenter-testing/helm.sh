helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.0.1 \
  --namespace kube-system \
  --create-namespace \
  -f karpenter-values.yaml \
  --wait

