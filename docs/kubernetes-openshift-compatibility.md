# Making Platform Forge Work on Kubernetes or OpenShift

This document covers how to make Platform Forge deployable to **either** vanilla Kubernetes (kubeadm) **or** OpenShift, and what changes are needed for each component.

**Current state:** The on-prem cluster has already been migrated from kubeadm/Ubuntu to a 3-node OpenShift compact cluster on the Beelink SER5 MAX MiniPCs. The AWS EKS burst cluster remains vanilla Kubernetes.

**TL;DR:** The project's application-level manifests (Deployments, Services, HPAs, ServiceMonitors) are ~95% portable. The work is in the infrastructure layer: per-component `values-openshift.yaml` overlays, a separate `k8s/apps-openshift/` directory for ArgoCD Applications, and OpenShift Routes instead of ingress-nginx.

---

## Table of Contents

1. [Architecture Overview: What Changes](#1-architecture-overview-what-changes)
2. [Key Decisions](#2-key-decisions)
3. [Ansible Bootstrap Layer](#3-ansible-bootstrap-layer)
4. [Networking: OpenShift Routes](#4-networking-openshift-routes)
5. [Security Contexts and SCCs](#5-security-contexts-and-sccs)
6. [CNI: OVN-Kubernetes](#6-cni-ovn-kubernetes)
7. [TLS: cert-manager on Both](#7-tls-cert-manager-on-both)
8. [Monitoring: OpenShift Built-in + Grafana](#8-monitoring-openshift-built-in--grafana)
9. [ArgoCD: Upstream Helm on Both](#9-argocd-upstream-helm-on-both)
10. [KEDA: Helm vs OpenShift Custom Metrics Autoscaler](#10-keda-helm-vs-openshift-custom-metrics-autoscaler)
11. [Backstage](#11-backstage)
12. [Multi-Cluster: Liqo and Tailscale](#12-multi-cluster-liqo-and-tailscale)
13. [Container Images and Registry](#13-container-images-and-registry)
14. [CI/CD Pipeline Changes](#14-cicd-pipeline-changes)
15. [Terraform / AWS Burst Target](#15-terraform--aws-burst-target)
16. [Implementation Strategy](#16-implementation-strategy)
17. [Proposed Directory Structure](#17-proposed-directory-structure)
18. [Decision Matrix: Component by Component](#18-decision-matrix-component-by-component)

---

## 1. Architecture Overview: What Changes

| Layer | Kubernetes (kubeadm) | OpenShift (on-prem) | AWS EKS (burst) |
|-------|---------------------|---------------------|-----------------|
| **Cluster Bootstrap** | Ansible + kubeadm | OpenShift installer (already done) | Terraform |
| **CNI** | Cilium (eBPF) | OVN-Kubernetes (built-in) | AWS VPC CNI |
| **Ingress** | ingress-nginx + Ingress objects | OpenShift Router + Route objects | - |
| **TLS** | cert-manager (Helm) | cert-manager (Helm, same chart) | - |
| **Monitoring** | kube-prometheus-stack (Helm) | Built-in cluster monitoring + Grafana | - |
| **GitOps** | ArgoCD (Helm) | ArgoCD (Helm, same chart) | - |
| **Autoscaling** | KEDA (Helm) | OpenShift Custom Metrics Autoscaler | - |
| **Security** | PodSecurity (PSA) | SecurityContextConstraints (SCCs) | PSA |
| **App Deployments** | Deployments, Services, HPAs | Same | Same |
| **Multi-cluster** | Liqo + Tailscale | Liqo + Tailscale | Tailscale + Karpenter |

---

## 2. Key Decisions

These decisions shape the implementation approach:

| Decision | Rationale |
|----------|-----------|
| **OpenShift on-prem only; EKS stays vanilla K8s** | Keeps the burst target simple; ROSA is expensive for a learning cluster |
| **Use OpenShift Routes** (not ingress-nginx) | Leverage the built-in HAProxy Router; skip deploying ingress-nginx entirely |
| **Keep upstream ArgoCD** (not OpenShift GitOps operator) | Consistent ArgoCD experience across both platforms; same Helm chart and values structure |
| **OVN-Kubernetes replaces Cilium** | OpenShift's default CNI; cannot swap it out without losing support |
| **Tailscale as privileged DaemonSet on RHCOS** | RHCOS is immutable; can't install packages at the OS level, so DaemonSet with privileged SCC |
| **Per-component `values-openshift.yaml` overlays** | Minimal divergence; shared base values with targeted overrides |
| **Separate `k8s/apps-openshift/` directory** | Clean separation of ArgoCD Application manifests per platform |

---

## 3. Ansible Bootstrap Layer

### What Changes

The `ansible/` directory is kubeadm-specific and **not used for OpenShift**. The OpenShift cluster is already running (3-node compact cluster via the OpenShift installer).

### What to Keep

- `ansible/` stays in the repo for the kubeadm path (documentation, potential future use)
- `ansible/playbooks/04-tailscale.yml` logic is reused — adapted as an OpenShift DaemonSet instead of an Ansible role

### OpenShift Post-Install

Since the cluster is already up, the remaining work is post-install configuration. Create an `openshift/` directory for post-install manifests:

```
openshift/
  post-install/
    01-tailscale-daemonset.yaml        # Tailscale with privileged SCC
    02-enable-user-workload-monitoring.yaml  # Prometheus user workload metrics
    03-grafana.yaml                    # Standalone Grafana (OpenShift removed built-in)
  README.md                            # Post-install steps
```

---

## 4. Networking: OpenShift Routes

### The Difference

- **Kubernetes:** `Ingress` resources + ingress-nginx controller (NodePort 30080/30443)
- **OpenShift:** Built-in HAProxy Router + `Route` resources (ports 80/443 natively)

### What This Means

- **Skip `ingress-nginx` entirely** on OpenShift — it's not in `k8s/apps-openshift/`
- **No more NodePort** — OpenShift Router handles ports 80/443 directly
- **Hostnames change** from `*.192.168.68.93.nip.io:30443` to `*.apps.<cluster-domain>`

### Routes for Platform Services

For Helm-deployed services (ArgoCD, Grafana, Backstage), create `Route` objects in the OpenShift values overlays or as standalone manifests:

```yaml
# Example: ArgoCD Route
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: argocd-server
  namespace: argocd
spec:
  host: argocd.apps.<cluster-domain>
  to:
    kind: Service
    name: argocd-server
  port:
    targetPort: https
  tls:
    termination: passthrough
```

### Hostname Mapping

| Component | Kubernetes | OpenShift |
|-----------|-----------|-----------|
| ArgoCD | `argocd.192.168.68.93.nip.io:30443` | `argocd.apps.<cluster-domain>` |
| Grafana | `grafana.192.168.68.93.nip.io:30443` | `grafana.apps.<cluster-domain>` |
| Backstage | `backstage.192.168.68.93.nip.io:30443` | `backstage.apps.<cluster-domain>` |

### Values Overlays

```yaml
# k8s/argocd/values-openshift.yaml
server:
  ingress:
    enabled: false   # Disable Ingress — using Route instead
  # Route created as a separate manifest or via Helm template
```

---

## 5. Security Contexts and SCCs

### The Difference

- **Kubernetes:** Pod Security Admission (PSA) with namespace labels (`restricted`, `baseline`, `privileged`)
- **OpenShift:** SecurityContextConstraints (SCCs) — RBAC-like model. Default is `restricted-v2`, which is stricter than K8s defaults.

### Current State: Already Compatible

Your app deployments already use best-practice security contexts:
```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: [ALL]
```

This is **compatible with OpenShift's `restricted-v2` SCC** out of the box. Your distroless/nonroot container images comply.

### Where Adjustments Are Needed

| Component | Issue on OpenShift | Fix |
|-----------|-------------------|-----|
| cert-manager | Hardcoded `runAsUser: 1001` / `fsGroup: 1001` | `values-openshift.yaml`: remove hardcoded UIDs, let OpenShift assign from namespace range |
| Tailscale DaemonSet | Needs network namespace access | Grant `privileged` SCC to Tailscale ServiceAccount |
| Liqo | Needs host networking for peering | Grant appropriate SCCs to Liqo service accounts |

### OpenShift Values Overlay for cert-manager

```yaml
# k8s/cert-manager/values-openshift.yaml
securityContext:
  runAsNonRoot: true
  # Do NOT set runAsUser — let OpenShift assign from namespace range

podSecurityContext: {}
  # Do NOT set fsGroup or runAsUser — OpenShift manages UID allocation
```

---

## 6. CNI: OVN-Kubernetes

OVN-Kubernetes is OpenShift's default CNI and is **already running** on your cluster. No action needed.

- Cilium + Hubble from the kubeadm setup are not applicable
- NetworkPolicy resources work the same on both platforms
- For Hubble-like network flow visualization, the **Network Observability Operator** from OperatorHub provides similar functionality (eBPF-based, feeds into Loki):

```bash
# Optional: install via OperatorHub console or CLI
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

---

## 7. TLS: cert-manager on Both

cert-manager works on both platforms. Use the same Helm chart with an OpenShift values overlay (to remove hardcoded UIDs — see Section 5).

The `selfsigned-issuer` ClusterIssuer works identically on both platforms. No changes to certificate workflow.

Alternatively, cert-manager is available as a Red Hat-supported operator from OperatorHub, but since we're keeping upstream ArgoCD + Helm patterns, the Helm chart is more consistent.

---

## 8. Monitoring: OpenShift Built-in + Grafana

### The Difference

This is one of the **biggest differences** between platforms.

- **Kubernetes:** kube-prometheus-stack via Helm (Prometheus + Grafana + Alertmanager)
- **OpenShift:** Ships with Prometheus + Alertmanager in `openshift-monitoring`. No Grafana since OpenShift 4.11+.

### Approach for OpenShift

**Step 1: Enable user workload monitoring** (so OpenShift Prometheus discovers your ServiceMonitors):

```yaml
# openshift/post-install/02-enable-user-workload-monitoring.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

**Step 2: Deploy Grafana standalone** (for your existing dashboards):

Install via Helm or the Grafana Operator from OperatorHub. Point it at OpenShift's built-in Prometheus as a data source. Your existing dashboard JSONs (`burst-demo.json`, `cluster-overview.json`) are reusable as-is.

**Step 3: Skip `monitoring.yaml` ArgoCD Application** on OpenShift. Create a `monitoring-openshift.yaml` that deploys only Grafana + the user workload monitoring ConfigMap.

### ServiceMonitors: No Changes

Your existing `ServiceMonitor` resources (`k8s/apps/*/servicemonitor.yaml`) work on both platforms — OpenShift's built-in Prometheus uses the same CRD.

---

## 9. ArgoCD: Upstream Helm on Both

**Decision: Keep upstream ArgoCD on both platforms** (not the OpenShift GitOps operator).

This means:
- Same Helm chart (`argo/argo-cd`)
- Same `values.yaml` base
- Same `argocd` namespace
- Same Application CRDs and app-of-apps pattern

### OpenShift-Specific Overlay

The only differences are routing and security context:

```yaml
# k8s/argocd/values-openshift.yaml
server:
  ingress:
    enabled: false   # Using OpenShift Route instead

  # ArgoCD server security - let OpenShift assign UIDs
  podSecurityContext: {}
```

Plus a Route manifest for the ArgoCD UI:

```yaml
# k8s/argocd/route-openshift.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: argocd-server
  namespace: argocd
spec:
  host: argocd.apps.<cluster-domain>
  to:
    kind: Service
    name: argocd-server
  port:
    targetPort: https
  tls:
    termination: passthrough
```

### App-of-Apps: Separate Directory

The OpenShift app-of-apps points to `k8s/apps-openshift/` instead of `k8s/apps/`:

```yaml
# k8s/argocd/application-openshift.yaml
spec:
  source:
    repoURL: https://github.com/jconover/platform-forge.git
    targetRevision: main
    path: k8s/apps-openshift    # Different directory
```

`k8s/apps-openshift/` contains the same Application manifests as `k8s/apps/` but:
- Excludes `ingress-nginx.yaml` (not needed)
- Excludes `monitoring.yaml` (replaced by `monitoring-openshift.yaml`)
- Uses `values-openshift.yaml` overlays in multi-source Application specs

---

## 10. KEDA: Helm vs OpenShift Custom Metrics Autoscaler

- **Kubernetes:** KEDA installed via Helm chart
- **OpenShift:** Custom Metrics Autoscaler Operator from OperatorHub (which **is** KEDA)

On OpenShift, install the operator instead of the Helm chart. Your `ScaledObject` CRD (`k8s/keda/scaledobject.yaml`) works identically — no changes needed to the scaling configuration.

In `k8s/apps-openshift/`, exclude the `keda.yaml` ArgoCD Application (the operator handles lifecycle).

---

## 11. Backstage

Backstage runs as a standard Deployment + Service + PostgreSQL. Works on both platforms with minor adjustments:

| Aspect | Kubernetes | OpenShift |
|--------|-----------|-----------|
| Deployment | Same | Same |
| Ingress | Ingress object | Route object |
| Security | Current securityContext | Works with `restricted-v2` SCC |
| PostgreSQL | Helm subchart | Same |
| Kubernetes plugin | In-cluster ServiceAccount | Same — works with OpenShift API |

### OpenShift Values Overlay

```yaml
# k8s/backstage/values-openshift.yaml
ingress:
  enabled: false   # Using Route instead

# Route manifest provided separately
```

### Bonus: Janus IDP / OpenShift Plugins

As you learn OpenShift, consider the `@janus-idp/backstage-plugin-topology` plugin for OpenShift topology views, Route visualization, and OpenShift-native resource browsing.

---

## 12. Multi-Cluster: Liqo and Tailscale

### Tailscale on OpenShift

RHCOS is immutable — you can't `apt install tailscale`. Deploy as a **privileged DaemonSet**:

```bash
# Grant privileged SCC to Tailscale service account
oc adm policy add-scc-to-user privileged -z tailscale -n tailscale
```

```yaml
# openshift/post-install/01-tailscale-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: tailscale
  namespace: tailscale
spec:
  selector:
    matchLabels:
      app: tailscale
  template:
    metadata:
      labels:
        app: tailscale
    spec:
      serviceAccountName: tailscale
      hostNetwork: true
      containers:
        - name: tailscale
          image: tailscale/tailscale:latest
          securityContext:
            privileged: true
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: tailscale-auth
                  key: authkey
            - name: TS_ROUTES
              value: "10.244.0.0/16"    # Advertise pod CIDR
            - name: TS_ACCEPT_ROUTES
              value: "true"
```

### Liqo on OpenShift

Liqo supports OpenShift. Use the Helm chart with an OpenShift values overlay that grants SCCs:

```yaml
# k8s/liqo/values-openshift.yaml
# Grant SCCs to Liqo service accounts (applied as a pre-sync hook or manually)
```

### Tailscale Mesh: Unchanged

The Tailscale mesh between on-prem (OpenShift) and AWS (EKS) works the same — the DaemonSet advertises pod CIDRs and accepts routes from the other cluster.

---

## 13. Container Images and Registry

**ghcr.io works on both platforms.** No changes needed.

OpenShift includes a built-in image registry (`image-registry.openshift-image-registry.svc:5000`) which is useful for local dev but not required.

---

## 14. CI/CD Pipeline Changes

**No changes needed.** The existing GitHub Actions pipelines are platform-agnostic:

1. Build image -> Push to ghcr.io -> Update K8s manifest -> ArgoCD syncs

The manifests being updated are the Deployment image tags, which are shared across both platforms.

If the OpenShift app-of-apps points to different Application manifests (in `k8s/apps-openshift/`), those manifests still reference the same Deployment YAML files — they just use different Helm values overlays.

---

## 15. Terraform / AWS Burst Target

**No changes.** The Terraform modules (VPC, EKS, IAM, Tailscale) are independent of the on-prem cluster type. EKS stays vanilla Kubernetes.

The Tailscale mesh connects the same way regardless of whether on-prem is kubeadm or OpenShift — the DaemonSet advertises the same pod CIDRs.

---

## 16. Implementation Strategy

### Phase 1: OpenShift Post-Install (immediate)

Since the cluster is already running, apply post-install configs:

1. Deploy Tailscale DaemonSet with privileged SCC
2. Enable user workload monitoring
3. Install upstream ArgoCD via Helm (same chart as K8s)
4. Install KEDA operator from OperatorHub

### Phase 2: Values Overlays

For each Helm-based component, create `values-openshift.yaml`:

```
k8s/argocd/values-openshift.yaml         # Disable Ingress, add Route
k8s/backstage/values-openshift.yaml       # Disable Ingress, add Route
k8s/cert-manager/values-openshift.yaml    # Remove hardcoded UIDs
k8s/monitoring/values-openshift.yaml      # Grafana-only (skip full prometheus stack)
k8s/liqo/values-openshift.yaml            # SCC grants
```

### Phase 3: OpenShift App-of-Apps

Create `k8s/apps-openshift/` with the OpenShift-specific ArgoCD Application set:

- Copy relevant apps from `k8s/apps/`
- Exclude: `ingress-nginx.yaml`, `keda.yaml` (operator), `monitoring.yaml` (built-in)
- Add: `monitoring-openshift.yaml` (Grafana + user workload monitoring)
- Update multi-source Applications to reference `values-openshift.yaml` overlays

Create `k8s/argocd/application-openshift.yaml` pointing to `k8s/apps-openshift/`.

### Phase 4: Route Manifests

Create Route objects for each exposed service:
- `k8s/argocd/route-openshift.yaml`
- `k8s/backstage/route-openshift.yaml`
- `k8s/monitoring/grafana-route-openshift.yaml`

---

## 17. Proposed Directory Structure

```
platform-forge/
├── ansible/                              # Kubernetes (kubeadm) bootstrap — KEPT FOR REFERENCE
│
├── openshift/                            # NEW — OpenShift post-install configs
│   ├── post-install/
│   │   ├── 01-tailscale-daemonset.yaml   # Tailscale with privileged SCC
│   │   ├── 02-enable-user-workload-monitoring.yaml
│   │   └── 03-grafana.yaml              # Standalone Grafana deploy
│   └── README.md
│
├── k8s/
│   ├── argocd/
│   │   ├── application.yaml              # K8s app-of-apps → k8s/apps/
│   │   ├── application-openshift.yaml    # OpenShift app-of-apps → k8s/apps-openshift/
│   │   ├── values.yaml                   # Shared ArgoCD Helm values
│   │   ├── values-openshift.yaml         # Disable Ingress
│   │   └── route-openshift.yaml          # ArgoCD Route
│   │
│   ├── monitoring/
│   │   ├── values.yaml                   # kube-prometheus-stack (K8s)
│   │   ├── values-openshift.yaml         # Grafana-only (OpenShift)
│   │   ├── grafana-route-openshift.yaml  # Grafana Route
│   │   └── dashboards/                   # Shared dashboards
│   │
│   ├── backstage/
│   │   ├── values.yaml                   # Shared base
│   │   ├── values-openshift.yaml         # Disable Ingress
│   │   └── route-openshift.yaml          # Backstage Route
│   │
│   ├── cert-manager/
│   │   ├── values.yaml                   # Shared base
│   │   └── values-openshift.yaml         # Remove hardcoded UIDs
│   │
│   ├── ingress-nginx/                    # K8s ONLY
│   │   └── values.yaml
│   │
│   ├── keda/
│   │   ├── values.yaml                   # K8s Helm values
│   │   └── scaledobject.yaml             # Shared — works on both
│   │
│   ├── liqo/
│   │   ├── values-onprem.yaml            # K8s
│   │   ├── values-openshift.yaml         # OpenShift (with SCC grants)
│   │   └── values-eks.yaml               # EKS burst target
│   │
│   ├── apps/                             # K8s ArgoCD Applications
│   │   ├── api-gateway.yaml
│   │   ├── backend-api.yaml
│   │   ├── worker.yaml
│   │   ├── backstage.yaml
│   │   ├── cert-manager.yaml
│   │   ├── monitoring.yaml
│   │   ├── ingress-nginx.yaml
│   │   ├── keda.yaml
│   │   └── liqo.yaml
│   │
│   └── apps-openshift/                   # OpenShift ArgoCD Applications
│       ├── api-gateway.yaml              # Same as K8s (shared Deployments)
│       ├── backend-api.yaml
│       ├── worker.yaml
│       ├── backstage.yaml                # Uses values-openshift.yaml overlay
│       ├── cert-manager.yaml             # Uses values-openshift.yaml overlay
│       ├── monitoring-openshift.yaml     # Grafana-only + user workload monitoring
│       └── liqo.yaml                     # Uses values-openshift.yaml overlay
│       # NOT included: ingress-nginx, keda (operator), monitoring (built-in)
│
├── terraform/                            # UNCHANGED — EKS burst stays vanilla K8s
├── apps/                                 # UNCHANGED — application code is portable
└── .github/workflows/                    # UNCHANGED — CI builds are platform-agnostic
```

---

## 18. Decision Matrix: Component by Component

| Component | On Kubernetes (kubeadm) | On OpenShift (on-prem) | On EKS (burst) | Changes Needed |
|-----------|------------------------|------------------------|----------------|----------------|
| **Cluster bootstrap** | Ansible + kubeadm | OpenShift installer (done) | Terraform | Separate paths |
| **CNI** | Cilium (eBPF) | OVN-Kubernetes (built-in) | AWS VPC CNI | Skip Cilium on OCP |
| **Ingress** | ingress-nginx (NodePort) | OpenShift Router + Routes | N/A | Route manifests |
| **TLS** | cert-manager (Helm) | cert-manager (Helm) | N/A | Values overlay (UIDs) |
| **Monitoring** | kube-prometheus-stack | Built-in + Grafana standalone | N/A | Different ArgoCD app |
| **ArgoCD** | Helm chart | Helm chart (same) | N/A | Values overlay + Route |
| **KEDA** | Helm chart | Operator (OperatorHub) | N/A | Skip Helm on OCP |
| **ScaledObject** | KEDA CRD | Same CRD | N/A | **No change** |
| **Liqo** | Helm | Helm + SCC grants | Helm | Values overlay |
| **Tailscale** | Ansible role | Privileged DaemonSet | Terraform DaemonSet | SCC + DaemonSet |
| **App Deployments** | Deployment + Svc + HPA | Same | Same | **No change** |
| **ServiceMonitors** | kube-prometheus-stack CRD | Built-in CRD (same) | N/A | **No change** |
| **HPAs** | autoscaling/v2 | Same | Same | **No change** |
| **Backstage** | Helm + Ingress | Helm + Route | N/A | Values overlay + Route |
| **CI/CD** | GitHub Actions | Same | N/A | **No change** |
| **Container images** | ghcr.io | ghcr.io | ghcr.io | **No change** |
| **Karpenter** | N/A | N/A | Same | **No change** |

---

## Summary

Platform Forge is **well-positioned** for dual-platform support because:

1. **App manifests are already portable** — Deployments, Services, HPAs, and ServiceMonitors follow standard Kubernetes APIs that OpenShift fully supports
2. **Security contexts are already strict** — they comply with OpenShift's `restricted-v2` SCC out of the box
3. **Container images are already rootless** — distroless/nonroot base images work on both
4. **CI/CD is platform-agnostic** — GitHub Actions builds and pushes to ghcr.io regardless of target
5. **Keeping upstream ArgoCD** means the GitOps layer is identical on both platforms

**Scope of changes:**
- New files: ~15 (`openshift/` post-install, `values-openshift.yaml` overlays, Route manifests, `k8s/apps-openshift/` Application manifests)
- Modified files: 0 (all existing K8s manifests stay as-is)
- Deleted files: 0 (kubeadm path preserved in `ansible/`)

**What stays exactly the same:**
- All application source code (`apps/`)
- All Dockerfiles
- All GitHub Actions workflows
- All Terraform modules (EKS burst)
- All Deployment, Service, HPA, and ServiceMonitor manifests
- The ArgoCD app-of-apps pattern (just different entry points per platform)
- The KEDA ScaledObject configuration
