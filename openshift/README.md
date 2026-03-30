# Platform Forge — OpenShift Deployment Guide

This guide covers deploying Platform Forge on an existing OpenShift cluster. It assumes a 3-node compact cluster is already running.

For the full architecture comparison between Kubernetes and OpenShift, see [docs/kubernetes-openshift-compatibility.md](../docs/kubernetes-openshift-compatibility.md).

## Prerequisites

- OpenShift 4.14+ cluster running and accessible via `oc`
- `oc` CLI authenticated as cluster-admin
- GitHub PAT with repo read access (for Backstage)
- Tailscale auth key (for mesh networking to EKS)

## Before You Begin: Replace CLUSTER_DOMAIN

Many manifests use `CLUSTER_DOMAIN` as a placeholder. Replace it with your actual OpenShift apps domain:

```bash
# Find your cluster domain
oc get ingresses.config cluster -o jsonpath='{.spec.domain}'
# Example output: apps.ocp.example.com

# Replace in all OpenShift manifests
find k8s/ openshift/ -name '*openshift*' -exec sed -i 's/CLUSTER_DOMAIN/<your-domain>/g' {} +
```

## Step 1: Tailscale Mesh Networking

Tailscale provides the encrypted WireGuard overlay between OpenShift and EKS.

```bash
# Edit the auth key
vi openshift/post-install/01-tailscale-namespace.yaml
# Replace REPLACE_WITH_TAILSCALE_AUTH_KEY with your Tailscale auth key

# Apply namespace, service account, and secret
oc apply -f openshift/post-install/01-tailscale-namespace.yaml

# Grant privileged SCC (RHCOS is immutable — DaemonSet needs host networking)
oc adm policy add-scc-to-user privileged -z tailscale -n tailscale

# Deploy the DaemonSet
oc apply -f openshift/post-install/02-tailscale-daemonset.yaml

# Verify Tailscale is running on all nodes
oc get pods -n tailscale -o wide
```

## Step 2: Enable User Workload Monitoring

OpenShift ships with Prometheus and Alertmanager. Enable user workload monitoring so your app ServiceMonitors are discovered:

```bash
oc apply -f openshift/post-install/03-enable-user-workload-monitoring.yaml

# Verify user workload monitoring pods start
oc get pods -n openshift-user-workload-monitoring
```

## Step 3: Deploy Grafana

OpenShift removed bundled Grafana in 4.11+. Deploy standalone:

```bash
# Create Grafana admin credentials
oc create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<your-password> \
  -n monitoring

# Deploy Grafana with OpenShift Route
oc apply -f openshift/post-install/04-grafana.yaml

# Access at: https://grafana.apps.<cluster-domain>
```

To load the existing dashboards, create ConfigMaps from the dashboard JSON files:

```bash
oc create configmap burst-demo-dashboard \
  --from-file=burst-demo.json=k8s/monitoring/dashboards/burst-demo.json \
  -n monitoring
oc label configmap burst-demo-dashboard grafana_dashboard=1 -n monitoring

oc create configmap cluster-overview-dashboard \
  --from-file=cluster-overview.json=k8s/monitoring/dashboards/cluster-overview.json \
  -n monitoring
oc label configmap cluster-overview-dashboard grafana_dashboard=1 -n monitoring
```

## Step 4: Install ArgoCD

We use the upstream ArgoCD Helm chart (not the OpenShift GitOps operator) for consistency with the K8s path:

```bash
# Add the ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD with base + OpenShift overlay values
helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f k8s/argocd/values.yaml \
  -f k8s/argocd/values-openshift.yaml

# Apply the ArgoCD Route
oc apply -f k8s/argocd/route-openshift.yaml

# Get the initial admin password
oc get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Access at: https://argocd.apps.<cluster-domain>
```

## Step 5: Install KEDA Operator

Install from OperatorHub (not Helm):

```bash
# Via OpenShift console: Operators > OperatorHub > search "Custom Metrics Autoscaler"
# Or via CLI:
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: custom-metrics-autoscaler
  namespace: openshift-keda
spec:
  channel: stable
  name: custom-metrics-autoscaler
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Create the KedaController instance
cat <<EOF | oc apply -f -
apiVersion: keda.sh/v1alpha1
kind: KedaController
metadata:
  name: keda
  namespace: openshift-keda
spec:
  watchNamespace: ""
EOF
```

Then apply the ScaledObject (works identically on both platforms):

```bash
oc apply -f k8s/keda/scaledobject.yaml
```

**Note:** The ScaledObject references Prometheus at `prometheus-kube-prometheus-prometheus.monitoring:9090`. On OpenShift, update this to point to the built-in Prometheus:

```
thanos-querier.openshift-monitoring.svc:9091
```

## Step 6: Liqo (Multi-Cluster Federation)

```bash
# Grant SCCs to Liqo service accounts
oc adm policy add-scc-to-user privileged -z liqo-gateway -n liqo
oc adm policy add-scc-to-user anyuid -z liqo-controller-manager -n liqo

# Install Liqo with base + OpenShift overlay values
helm repo add liqo https://helm.liqo.io
helm install liqo liqo/liqo \
  -n liqo --create-namespace \
  -f k8s/liqo/values-onprem.yaml \
  -f k8s/liqo/values-openshift.yaml

# Apply the Liqo auth Route
oc apply -f k8s/liqo/route-openshift.yaml
```

## Step 7: Create Secrets

```bash
# Backstage secrets
oc create namespace backstage
oc create secret generic backstage-secrets \
  --from-literal=github-token=<your-github-token> \
  --from-literal=argocd-auth-token=<your-argocd-token> \
  -n backstage

# Backstage PostgreSQL secret
oc create secret generic backstage-postgresql \
  --from-literal=password=<db-password> \
  --from-literal=postgres-password=<admin-password> \
  -n backstage
```

## Step 8: Bootstrap App-of-Apps

Apply the OpenShift app-of-apps to let ArgoCD manage everything:

```bash
oc apply -f k8s/argocd/application-openshift.yaml
```

This deploys:
- api-gateway, backend-api, worker (same Deployments as K8s)
- Backstage (with OpenShift values overlay)
- cert-manager (with OpenShift values overlay)
- Liqo (with OpenShift values overlay)
- OpenShift Routes (for ArgoCD, Backstage, Liqo)

**Not deployed** (handled by OpenShift natively or via Operators):
- ingress-nginx (OpenShift Router replaces it)
- kube-prometheus-stack (OpenShift built-in monitoring)
- KEDA Helm chart (Custom Metrics Autoscaler Operator)

## Step 9: Verify

```bash
# Check all ArgoCD apps are synced
oc get applications -n argocd

# Check pods across namespaces
oc get pods -A | grep -E '(argocd|backstage|cert-manager|liqo|default|tailscale|monitoring)'

# Check Routes
oc get routes -A

# Verify Tailscale mesh
oc exec -n tailscale $(oc get pods -n tailscale -o name | head -1) -- tailscale status
```

## Access Points

| Component | URL |
|-----------|-----|
| ArgoCD | `https://argocd.apps.<cluster-domain>` |
| Backstage | `https://backstage.apps.<cluster-domain>` |
| Grafana | `https://grafana.apps.<cluster-domain>` |
| OpenShift Console | `https://console-openshift-console.apps.<cluster-domain>` |

## What's Different from Kubernetes

| Aspect | K8s (kubeadm) | OpenShift |
|--------|--------------|-----------|
| Bootstrap | `ansible/playbooks/site.yml` | OpenShift installer (already done) |
| App-of-apps | `k8s/argocd/application.yaml` | `k8s/argocd/application-openshift.yaml` |
| ArgoCD apps | `k8s/apps/` | `k8s/apps-openshift/` |
| Ingress | ingress-nginx + Ingress objects | Built-in Router + Route objects |
| Monitoring | kube-prometheus-stack (Helm) | Built-in + standalone Grafana |
| KEDA | Helm chart | OperatorHub operator |
| CNI | Cilium | OVN-Kubernetes (built-in) |
| Tailscale | Ansible role | Privileged DaemonSet |
