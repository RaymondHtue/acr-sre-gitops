kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

k -n argocd get secrets argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
