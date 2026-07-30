# Expose ArgoCD UI at argocd.maunghtoo.cloud

Exposes the ArgoCD web UI/API through the shared ALB Gateway (Gateway API HTTPRoute), reusing the wildcard `*.maunghtoo.cloud` ACM cert and DNS record.

## How it works

```
browser -> ALB (TLS terminate, *.maunghtoo.cloud ACM cert)
        -> HTTPRoute argocd/argocd-server (host argocd.maunghtoo.cloud)
        -> Service argocd-server:80 (plain HTTP, server.insecure=true)
```

- Gateway: `alb-gateway` in namespace `default` (see
  `docs/notes/alb-gateway-gatewayclass/alb-gateway.yaml`). Listeners `http` (80) and
  `https` (443, TLS Terminate with ACM cert). `allowedRoutes.namespaces.from: All`,
  so the route can live in the `argocd` namespace.
- DNS: wildcard `*.maunghtoo.cloud` already CNAMEs to the ALB. No per-host record needed.
- TLS terminates at the ALB. argocd-server must serve plain HTTP behind it
  (`server.insecure: "true"`), otherwise it 308-redirects 80 to 443 and loops.

## Prerequisites

- AWS Load Balancer Controller synced (with `ALBGatewayAPI` feature gate) and the
  `alb-gateway` Gateway programmed.
- ArgoCD installed (`scripts/argo-install.sh`).

## Steps

Both steps are already part of `scripts/argo-install.sh`; run them manually only when
fixing an existing install.

1. Serve plain HTTP so the ALB terminates TLS:

   ```bash
   kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
     -p '{"data":{"server.insecure":"true"}}'
   kubectl -n argocd rollout restart deployment argocd-server
   ```

2. Apply the HTTPRoute:

   ```bash
   kubectl apply -f scripts/argocd-httproute.yaml
   ```

## Verify

```bash
kubectl -n argocd rollout status deployment argocd-server
kubectl -n argocd get httproute argocd-server \
  -o jsonpath='{.status.parents[*].conditions[*].type}={.status.parents[*].conditions[*].status}'
# expect Accepted=True and ResolvedRefs=True on both parents

curl -s -o /dev/null -w '%{http_code}\n' https://argocd.maunghtoo.cloud/   # 200
```

Login: `admin` plus:

```bash
kubectl -n argocd get secrets argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Gotchas

- `argocd-cmd-params-cm` resets if ArgoCD is reinstalled or the cluster is rebuilt.
  Symptom: ALB health checks fail or the browser loops on redirects. Re-run step 1.
- Plain HTTP (port 80) also serves the UI because `ssl-redirect` is commented out on
  the Gateway. To force HTTPS, uncomment
  `alb.ingress.kubernetes.io/ssl-redirect: '443'` in `alb-gateway.yaml`.
- ArgoCD is NOT managed by the platform ApplicationSet (chicken-and-egg), so this
  exposure lives in bootstrap (`scripts/`), not in `infra-configs/`.
- Teardown: delete the HTTPRoute before removing the LBC, or TargetGroupBindings
  strand on the `elbv2.k8s.aws/resources` finalizer (see `docs/TEARDOWN-RUNBOOK.md`).
