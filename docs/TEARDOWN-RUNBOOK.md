# Cluster Teardown Runbook - accor-resilient-eks-dev

Goal: cleanly remove all ArgoCD-managed workloads/controllers so AWS resources
(ALB, Karpenter nodes) are released, then `terraform destroy` runs clean.


- Remote: `origin` = https://github.com/RaymondHtue/acr-sre-gitops.git
- `accor-infra-apps` ApplicationSet (11 platform apps) tracks branch `observability/loki-fluent-bit-tempo`
- `nginx-kustomization-appset` + standalone `aws-alb-gateway` app track `main` (HEAD)
- otel-demo (97 resources) is NOT ArgoCD-managed → plain kubectl works
- All apps: `automated` + `prune:true` + `selfHeal:true` → raw `kubectl delete` on a
  managed resource gets RE-CREATED. Drive via Git or delete the App/AppSet.
- No PVCs . One ALB from Gateway `default/alb-gateway`.

## Rule

Remove resource-HOLDERS before their CONTROLLERS:
HTTPRoutes/Gateway before LBC; workloads + NodePool before Karpenter.

---

## Phase 1 — workloads + routes (drains ALB target groups, Karpenter nodes)

```bash
# nginx apps (deleting the AppSet cascades to nginx-blue/dev/green)
kubectl delete applicationset nginx-kustomization-appset -n argocd

# otel-demo (manual, not ArgoCD)
kubectl delete ns otel-demo --wait=false

# confirm nginx/otel apps gone
kubectl get applications -n argocd | grep -E "nginx|otel-demo" || echo "cleared"
```

## Phase 2 — Gateway → ALB (must happen BEFORE disabling LBC)

```bash
# aws-alb-gateway is a standalone Application (source aws-alb-manifests/ on main)
kubectl delete application aws-alb-gateway -n argocd

# LBC now deletes the ALB. VERIFY it is actually gone before Phase 3:
kubectl get gateway -A                    # alb-gateway should disappear
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-default')].LoadBalancerName" \
  --output text                           # expect empty
```
Do NOT proceed until the ALB is gone. Disabling LBC first orphans the ALB and
`terraform destroy` of the VPC hangs on in-use ENIs.

### GOTCHA: deleting the app alone deadlocks and orphans the ALB 

The app has `PrunePropagationPolicy=foreground`, so it deletes Gateway +
GatewayClass + LoadBalancerConfiguration + TargetGroupConfiguration at once. LBC's
gateway controller then can't validate the (terminating) GatewayClass/params, marks
the Gateway `Accepted: False / Invalid`, and NEVER runs the ALB-delete path. Result:
Gateway hangs on finalizer `gateway.k8s.aws/alb`, ALB stays `active` in AWS.

Symptom: `kubectl delete application` hangs; `kubectl get gateway alb-gateway`
shows a `deletionTimestamp` but the object persists; `aws elbv2
describe-load-balancers` still lists `k8s-default-albgatew`.

Recovery — delete the AWS resources by tag directly (for a teardown the stuck CRs
don't matter, but the orphaned AWS resources block `terraform destroy`):

```bash
# 1. enumerate everything LBC created (ALB + all target groups)
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=accor-resilient-eks-dev \
  --resource-type-filters elasticloadbalancing

# 2. delete the ALB (removes its listeners+rules), poll until gone (releases ENIs)
ALB=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-default-albgatew')].LoadBalancerArn" --output text)
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB"

# 3. delete each target group (ARNs from step 1, targetgroup filter)
aws elbv2 delete-target-group --target-group-arn <tg-arn>   # repeat per TG

# 4. delete ALL LBC-created security groups in the VPC. LBC leaves TWO kinds and
#    terraform owns NEITHER, so both silently block `DeleteVpc` (DependencyViolation)
#    long after the ALB/ENIs are gone - they don't show as ENIs or LBs:
#      - frontend/managed:  k8s-<ns>-albgatew-*   (e.g. k8s-default-albgatew-*)
#      - traffic:           k8s-traffic-*
#    if a delete fails DependencyViolation, first revoke any ingress rule on another
#    SG (e.g. the node SG sg-*-node-*) that references it.
VPC=vpc-xxxxxxxx   # the cluster VPC id
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
  --query "SecurityGroups[?starts_with(GroupName,'k8s-')].{ID:GroupId,Name:GroupName}" --output table
for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
    --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" --output text); do
  aws ec2 delete-security-group --group-id "$sg"
done

# 5. verify empty: 0 tagged ELB resources AND no non-default SGs left in the VPC
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=elbv2.k8s.aws/cluster,Values=accor-resilient-eks-dev \
  --resource-type-filters elasticloadbalancing            # expect 0
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" --output text   # expect empty

# 6. (optional tidiness) clear the stuck k8s finalizers so the ArgoCD app finishes.
#    Safe ONLY after the AWS resources above are deleted.
for kind in gateway/alb-gateway loadbalancerconfiguration/alb-public-ip targetgroupconfiguration/tg-ip-target; do
  kubectl -n default patch ${kind%/*} ${kind#*/} --type merge -p '{"metadata":{"finalizers":[]}}'
done
kubectl patch gatewayclass accor-aws-alb --type merge -p '{"metadata":{"finalizers":[]}}'
```

To AVOID the deadlock next time: delete only the Gateway first (let LBC remove the
ALB + finalizer), confirm the ALB is gone in AWS, THEN delete GatewayClass + the
two config CRs. i.e. don't foreground-cascade all four together.

## Phase 3 — Karpenter nodes, then controllers + rest

```bash
# force Karpenter to deprovision its nodes
kubectl delete nodepool --all
kubectl get nodeclaims                     # wait until EMPTY (only terraform nodegroup nodes remain)
```

Then disable all remaining platform apps. Git-driven (this is the pruning path
for the accor-infra-apps AppSet). Do it on the tracked branch:

```bash
git checkout observability/loki-fluent-bit-tempo
cd infra-configs/common
for f in alb-controller blackbox-exporter cert-manager eso fluent-bit \
         karpenter keda kube-prometheus-stack metrics-server otel-operator tempo; do
  git mv "$f.json" "$f.json_"
done
cd ../..
git commit -am "chore: disable all platform apps for cluster teardown"
git push origin observability/loki-fluent-bit-tempo
# ArgoCD prunes all 11 apps. Watch:
kubectl get applications -n argocd -w
```

### GOTCHA: deleting operators before their CRs strands finalizers

Fast teardown deletes operators (LBC, KEDA, ...) before the workloads whose CRs
they own. Those CRs then hang forever on the operator's finalizer - the operator
that would remove it is already gone. This cascades UP: a stuck CR blocks its
namespace's termination, which blocks the ArgoCD app's cascade prune
(`resources-finalizer.argocd.argoproj.io`), which leaves the Application object
hung with a `deletionTimestamp` that never clears.

Observed chains (deleting accor-infra-apps + nginx-kustomization-appset):
- `elbv2.k8s.aws/resources` on TargetGroupBindings (LBC deleted) -> otel-demo ns
  stuck Terminating + nginx app prune stalled.
- `finalizer.keda.sh` on ScaledObjects (KEDA deleted) -> testing-* ns stuck
  Terminating -> nginx Applications hung.

Symptom: `kubectl get ns <x> -o jsonpath='{.status.conditions[?(@.type=="NamespaceFinalizersRemaining")].message}'`
names the finalizer; ArgoCD apps sit `deletionTimestamp` set, health `Progressing`,
sync `Succeeded`.

Recovery - clear the stranded finalizers (safe: these hold NO external/AWS state,
and any AWS-backed resources like target groups were already deleted in Phase 2):
```bash
# TargetGroupBindings (LBC finalizer)
kubectl get targetgroupbindings -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  | while IFS=/ read -r ns name; do
      kubectl -n "$ns" patch targetgroupbinding "$name" --type merge -p '{"metadata":{"finalizers":[]}}'; done
# ScaledObjects (KEDA finalizer)
kubectl get scaledobjects -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  | while IFS=/ read -r ns name; do
      kubectl -n "$ns" patch scaledobject "$name" --type merge -p '{"metadata":{"finalizers":[]}}'; done
```
Namespaces then finish terminating and the ArgoCD apps delete on their own. Repeat
for any other operator finalizer named in a namespace's `FinalizersRemaining`.

To AVOID it: delete workloads/CRs BEFORE their operators (Phase 1 before Phase 3),
OR just accept the cleanup above. Note: these stuck k8s objects never block
`terraform destroy` - it tears down the control plane at the AWS layer regardless.
Only orphaned AWS resources (ALB/TGs/SG, see Phase 2 gotcha) block terraform.

## Phase 4 — remove ArgoCD control plane (optional, once apps pruned)

```bash
kubectl delete applicationset accor-infra-apps -n argocd
# ArgoCD itself, if installed via argo-install.sh:
kubectl delete ns argocd
```

## Phase 5 — handoff

Confirm before terraform:
```bash
kubectl get gateway,httproute -A        # empty
kubectl get nodeclaims                  # empty
aws elbv2 describe-load-balancers       # no k8s-* ALB
```
Then YOU run `terraform destroy` (manual, in your terragrunt workflow).

## Rollback (before Phase 5)

Undo the platform disable: rename `.json_` back to `.json`, push. ArgoCD re-deploys.
Phases 1-2 (deleted AppSet/app) require re-applying the manifests:
`kubectl apply -f nginx-appset.yaml aws-alb-manifests/aws-alb-application.yaml`.
