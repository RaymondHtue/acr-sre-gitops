# Executive Summary: Cluster Scaling & Deployment Validation

This project demonstrates a production-ready, event-driven scaling loop within the EKS environment. By integrating **KEDA** and **Karpenter**, we provide empirical proof of the cluster\&apos;s ability to scale workloads based on real-time traffic metrics and dynamically provision compute resources on demand.

# Architecture Flow

1. **Traffic Spike:** External load is generated against the Nginx service.  
2. **Metrics Collection:** Nginx-exporter publishes request-rate metrics to Prometheus.

3. **KEDA Trigger:** KEDA monitors the Prometheus query and scales the Deployment via HPA.  
4. **Horizontal Scaling:** Pod replicas increase from 1 to 30 based on the configured threshold.  
5. **Node Provisioning:** Karpenter detects unschedulable pods and provisions EC2 nodes (M5/M6i) on demand.

# Component Breakdown

## 1\. Workload Strategy (demo-nginx-kustomization/)

Uses a Kustomize base \+ overlay pattern to manage environment-specific configurations (Dev, Blue, Green). The workload is a hardened Nginx deployment with a Prometheus sidecar, governed by a ScaledObject targeting 50 req/s.

## 2\. Validation Methodology (wordload-scaling-testing/)

Verification is driven by a hey load-generator Job that simulates a 10× traffic spike. Detailed runbooks and troubleshooting guides facilitate the end-to-end validation of the metrics-to-node-provisioning chain.

## 3\. Node Layer (karpenter/)

Implements automated node lifecycle management using EC2NodeClass and NodePool CRDs. The configuration optimizes for cost and availability by mixing On-Demand and Spot instances across multiple availability zones.

# Operations

To validate the Kustomize manifests and view the rendered resources, execute:

```shell
kubectl kustomize demo-app/demo-nginx-kustomization/overlays/dev
kubectl kustomize demo-app/demo-nginx-kustomization/overlays/blue
kubectl kustomize demo-app/demo-nginx-kustomization/overlays/green
```
> For the full scaling experiment, refer to runbook.md within the testing directory.
