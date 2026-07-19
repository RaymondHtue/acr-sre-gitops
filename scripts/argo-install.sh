kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Serve plain HTTP so the ALB (wildcard *.maunghtoo.cloud cert) terminates TLS.
# Without this argocd-server 308-redirects 80->443 and loops behind the LB.
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server

k -n argocd get secrets argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
