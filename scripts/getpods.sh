for n in $(kubectl get nodes -l node.kubernetes.io/purpose=infra -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $n ==="
  kubectl get pods -A --field-selector spec.nodeName=$n
done