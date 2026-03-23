# Platform Forge

Enterprise-grade Internal Developer Platform on bare metal Kubernetes with hybrid cloud bursting to AWS EKS.

A self-hosted [Backstage](https://backstage.io) portal running on a kubeadm cluster, wired to ArgoCD for GitOps, GitHub Actions for CI/CD, and real metrics-driven workload bursting to AWS EKS over Tailscale mesh networking.

## Architecture

```
                                    ┌─────────────────────────┐
                                    │     GitHub (SaaS)       │
                                    │  ┌───────────────────┐  │
                         ┌──push───>│  │  GitHub Actions CI │  │
                         │          │  │  (build + push to  │  │
                         │          │  │   ghcr.io + update │  │
                         │          │  │   K8s manifests)   │  │
                         │          │  └───────────────────┘  │
                         │          │  ┌───────────────────┐  │
                         │          │  │  ghcr.io Registry  │  │
                         │          │  │  (container images)│  │
                         │          │  └───────┬───────────┘  │
                         │          └──────────┼──────────────┘
                         │                     │ pull
     ┌───────────────────┼─────────────────────┼──────────────────────────┐
     │  On-Prem Homelab (kubeadm)              │                          │
     │                                         ▼                          │
     │  ┌────────────┐  ┌──────────────┐  ┌──────────┐  ┌─────────────┐  │
     │  │  Backstage  │  │   ArgoCD     │──│ Services │  │ Prometheus  │  │
     │  │  (IDP)      │  │   (GitOps)   │  │ api-gw   │  │ + Grafana   │  │
     │  │  - K8s plg  │  │   app-of-apps│  │ backend  │  │ (monitoring)│  │
     │  │  - Argo plg │  │              │  │ worker   │  │             │  │
     │  │  - GH plg   │  └──────────────┘  └──────────┘  └──────┬──────┘  │
     │  └────────────┘                                          │         │
     │                                                          │         │
     │  ┌────────────────┐    ┌──────────┐    CPU > 80%         │         │
     │  │ Cilium (eBPF)  │    │  KEDA     │◄───────────────────┘         │
     │  │ + Hubble UI    │    │ (scaler)  │                               │
     │  └────────────────┘    └─────┬─────┘                               │
     │                              │ scale worker replicas               │
     │  k8s-master-01  k8s-worker-01  k8s-worker-02                      │
     │  192.168.68.93  192.168.68.84   192.168.68.88                     │
     └──────────┬─────────────────────────────────────────────────────────┘
                │
                │ Tailscale Mesh (WireGuard)
                │
     ┌──────────▼─────────────────────────────────────────────────────────┐
     │  AWS EKS (Burst Target)                                            │
     │                                                                    │
     │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
     │  │  Liqo Agent  │  │  Karpenter   │  │ Spot Nodes (m5.large)   │  │
     │  │  (federation)│  │  (autoscaler)│  │ Scale: 0-5 nodes        │  │
     │  └──────────────┘  └──────────────┘  │ (scale-to-zero default) │  │
     │                                      └──────────────────────────┘  │
     │  Tailscale DaemonSet (mesh connectivity)                           │
     └────────────────────────────────────────────────────────────────────┘
```

### Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Kubernetes** | kubeadm 1.34.x | Production-grade cluster bootstrap |
| **CNI** | Cilium + Hubble | eBPF networking with observability |
| **GitOps** | ArgoCD | Declarative app delivery via app-of-apps |
| **IDP** | Backstage | Developer portal with K8s/ArgoCD/GitHub plugins |
| **CI** | GitHub Actions | Build, test, push images, update manifests |
| **Registry** | ghcr.io | Container image storage |
| **Monitoring** | Prometheus + Grafana | Metrics, dashboards, alerting |
| **Burst Trigger** | KEDA | Scale worker replicas on cluster CPU > 80% |
| **Multi-Cluster** | Liqo | Federation between on-prem and EKS |
| **Cloud** | AWS EKS + Karpenter | Spot instance burst nodes, scale-to-zero |
| **Mesh** | Tailscale | WireGuard VPN connecting on-prem and EKS |
| **IaC** | Ansible + Terraform | On-prem bootstrap + AWS provisioning |
| **TLS** | cert-manager | Self-signed certificates for ingress |
| **Ingress** | ingress-nginx | NodePort controller for bare metal |

### Demo Microservices

| Service | Language | Port | Purpose |
|---------|----------|------|---------|
| **api-gateway** | Go | 8080 | HTTP router, reverse proxy to backend |
| **backend-api** | Python/FastAPI | 8081 | REST API with mock CRUD data |
| **worker** | Go | 8082 | CPU-intensive background processor (burst demo target) |

All services expose `/health` and `/metrics` (Prometheus format) endpoints.

## Prerequisites

### Hardware

3x Beelink SER5 MAX MiniPCs (or equivalent):
- CPU: AMD Ryzen 7 6800U (8C/16T)
- RAM: 32GB LPDDR5
- Storage: 1TB NVMe SSD
- OS: Ubuntu 24.04 LTS

### Network

| Node | IP | Role |
|------|----|------|
| k8s-master-01 | 192.168.68.93 | Control plane |
| k8s-worker-01 | 192.168.68.84 | Worker |
| k8s-worker-02 | 192.168.68.88 | Worker |

### Accounts & Credentials

| Service | What You Need |
|---------|---------------|
| **Tailscale** | Free account + auth key from [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) |
| **GitHub** | Repository + fine-grained PAT with repo read access |
| **AWS** | Account with IAM credentials for Terraform. Budget: $75-250/mo |

### Workstation Tools

```bash
# Required
sudo apt install ansible terraform kubectl helm
curl -fsSL https://tailscale.com/install.sh | sh

# Optional
brew install cilium-cli argocd gh
```

### SSH Access

Passwordless SSH from your workstation to all 3 nodes:

```bash
ssh-copy-id justin@192.168.68.93
ssh-copy-id justin@192.168.68.84
ssh-copy-id justin@192.168.68.88
```

## Quick Start

```bash
git clone https://github.com/jconover/platform-forge.git
cd platform-forge

# 1. Set up secrets
cp ansible/secrets.example.yml ansible/secrets.yml
# Edit secrets.yml with your Tailscale auth key
ansible-vault encrypt ansible/secrets.yml

# 2. Bootstrap the Kubernetes cluster
cd ansible && ansible-playbook playbooks/site.yml

# 3. Verify the cluster
kubectl get nodes    # 3 nodes, all Ready
cilium status        # Cilium healthy
tailscale status     # All nodes connected

# 4. Install storage provisioner (required for Prometheus PVCs)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 5. Bootstrap ArgoCD (everything else deploys automatically)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml

# 6. Create required secrets and deploy
kubectl create namespace monitoring
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password=<your-password>
kubectl apply -f k8s/argocd/application.yaml

# 7. Access the dashboards
# ArgoCD:   https://argocd.192.168.68.93.nip.io:30443
# Grafana:  https://grafana.192.168.68.93.nip.io:30443
# Backstage: https://backstage.192.168.68.93.nip.io:30443
```

## Deployment Guide (Phase by Phase)

### Phase 1: Kubernetes Cluster Bootstrap

Ansible playbooks provision a 3-node kubeadm cluster with Cilium CNI and Tailscale mesh.

```bash
cd ansible

# Review the inventory
cat inventory/hosts.yml

# Set up secrets (Tailscale auth key)
cp secrets.example.yml secrets.yml
vim secrets.yml  # Add your tailscale_auth_key
ansible-vault encrypt secrets.yml

# Run all playbooks in order
ansible-playbook playbooks/site.yml --ask-vault-pass

# Or run individual phases:
ansible-playbook playbooks/00-prerequisites.yml  # OS prep, containerd, kubeadm
ansible-playbook playbooks/01-master-init.yml     # kubeadm init on master
ansible-playbook playbooks/02-worker-join.yml     # Join workers to cluster
ansible-playbook playbooks/03-cni-cilium.yml      # Install Cilium + Hubble
ansible-playbook playbooks/04-tailscale.yml       # Tailscale mesh on all nodes
```

**Verify:**
```bash
kubectl get nodes -o wide
# NAME             STATUS   ROLES           VERSION   OS-IMAGE
# k8s-master-01   Ready    control-plane   v1.34.x   Ubuntu 24.04
# k8s-worker-01   Ready    <none>          v1.34.x   Ubuntu 24.04
# k8s-worker-02   Ready    <none>          v1.34.x   Ubuntu 24.04

cilium connectivity test    # All tests pass
cilium hubble ui            # Opens Hubble network observability
tailscale status            # All 3 nodes visible as mesh peers
```

### Phase 2: Core Platform (ArgoCD + Monitoring)

ArgoCD manages all cluster workloads via the app-of-apps pattern. Once bootstrapped, every other component deploys through Git.

```bash
# Install local-path-provisioner (required for Prometheus/Alertmanager PVCs)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  -f k8s/argocd/values.yaml

# Get the ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Create Grafana admin secret (required before monitoring stack starts)
kubectl create namespace monitoring
kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<your-password>

# Bootstrap app-of-apps (deploys everything else)
kubectl apply -f k8s/argocd/application.yaml
```

This single `application.yaml` tells ArgoCD to watch `k8s/apps/` in the repo. ArgoCD discovers and deploys:
- `monitoring.yaml` -> kube-prometheus-stack (Prometheus + Grafana)
- `cert-manager.yaml` -> cert-manager + self-signed ClusterIssuer
- `ingress-nginx.yaml` -> ingress controller (NodePort 30080/30443)
- `backstage.yaml` -> Backstage IDP
- `keda.yaml` -> KEDA event-driven autoscaler
- `liqo.yaml` -> Liqo multi-cluster federation
- `api-gateway.yaml`, `backend-api.yaml`, `worker.yaml` -> demo microservices

**Verify:**
```bash
# ArgoCD UI
open https://argocd.192.168.68.93.nip.io:30443

# Grafana dashboards
open https://grafana.192.168.68.93.nip.io:30443
# Admin credentials: from the grafana-admin-secret created above

# Prometheus targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090
open http://localhost:9090/targets
```

### Phase 3a: Backstage IDP

Backstage is deployed via its Helm chart through ArgoCD (already triggered by app-of-apps in Phase 2).

The Backstage instance includes:
- **Kubernetes plugin**: shows pod/deployment status per service
- **ArgoCD plugin**: shows GitOps sync state per service
- **GitHub integration**: discovers `catalog-info.yaml` entities from the repo

**Configure GitHub integration:**
```bash
# Create a GitHub PAT with repo read access, then:
kubectl create secret generic backstage-github-token \
  --namespace backstage \
  --from-literal=GITHUB_TOKEN=ghp_your_token_here
```

**Verify:**
```bash
open https://backstage.192.168.68.93.nip.io:30443
# Software catalog should show: idp-platform system, platform-engineering domain
```

### Phase 4: Demo Microservices + CI/CD

The 3 microservices deploy automatically via ArgoCD (triggered in Phase 2).

**CI/CD pipeline flow:**
```
Push code to apps/api-gateway/ on main
  -> GitHub Actions triggers ci-api-gateway.yml
  -> Calls ci-reusable.yml: test, build Docker image, push to ghcr.io
  -> Updates image tag in k8s/apps/api-gateway/deployment.yaml
  -> Commits manifest change back to repo
  -> ArgoCD detects Git change, syncs the deployment
  -> New pods roll out on the cluster
  -> Backstage reflects the updated version
```

**Initial image build (fresh cluster only):**

On a fresh cluster, the container images don't exist in ghcr.io yet. Trigger the CI pipelines:

```bash
# Option A: Trigger CI via a trivial code change
for svc in api-gateway backend-api worker; do
  echo "// initial build $(date +%s)" >> "apps/${svc}/src/main.go" 2>/dev/null || \
  echo "# initial build $(date +%s)" >> "apps/${svc}/src/main.py" 2>/dev/null
done
git add apps/ && git commit -m "ci: trigger initial image builds" && git push

# Option B: Build and push locally
echo $GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
for svc in api-gateway backend-api worker; do
  docker build -t ghcr.io/jconover/platform-forge/${svc}:latest apps/${svc}/
  docker push ghcr.io/jconover/platform-forge/${svc}:latest
done
```

**Verify the pipeline:**
```bash
# Make a small change to a service
echo "// trigger build" >> apps/api-gateway/src/main.go
git add . && git commit -m "test: trigger CI pipeline" && git push

# Watch the pipeline
gh run watch

# Verify ArgoCD synced the new image
argocd app get api-gateway
kubectl get pods -l app=api-gateway -o jsonpath='{.items[0].spec.containers[0].image}'
```

### Phase 5: AWS EKS Infrastructure

Terraform provisions the EKS burst target cluster with cost-optimized spot instances.

```bash
cd terraform/environments/prod

# Create the S3 state backend (one-time)
aws s3 mb s3://platform-forge-terraform-state --region us-east-1
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Initialize Terraform
terraform init

# Review the plan
terraform plan \
  -var="tailscale_auth_key=tskey-auth-XXXX" \
  -var="budget_alert_email=you@example.com"

# Apply (creates VPC + EKS + IAM + Tailscale DaemonSet)
terraform apply \
  -var="tailscale_auth_key=tskey-auth-XXXX" \
  -var="budget_alert_email=you@example.com"

# Get kubeconfig for EKS
aws eks update-kubeconfig --name platform-forge-eks --region us-east-1
```

**Cost model:**

| Mode | Monthly Cost | When to Use |
|------|-------------|-------------|
| Always-on dev | $110-200/mo | Active development of burst features |
| Demo-only | $0-5/mo | `terraform destroy` when not in use |

```bash
# Tear down EKS when not needed (saves ~$105/mo)
terraform destroy -var="tailscale_auth_key=tskey-auth-XXXX" -var="budget_alert_email=you@example.com"

# Bring it back up before a demo (~15-20 min)
terraform apply -var="tailscale_auth_key=tskey-auth-XXXX" -var="budget_alert_email=you@example.com"
```

**Verify:**
```bash
# Tailscale mesh includes EKS
tailscale status  # EKS subnet router visible

# EKS cluster exists with 0 nodes (scale-to-zero)
kubectl --context eks get nodes  # No nodes (Karpenter provisions on demand)
```

### Phase 6: Hybrid Cloud Burst

This is the flagship feature: when on-prem cluster CPU exceeds 80%, worker pods automatically burst to EKS.

**Install Liqo for multi-cluster federation:**
```bash
# Install Liqo on on-prem cluster
helm repo add liqo https://helm.liqo.io
helm install liqo liqo/liqo -n liqo-system --create-namespace \
  -f k8s/liqo/values-onprem.yaml

# Install Liqo on EKS
helm install liqo liqo/liqo -n liqo-system --create-namespace \
  -f k8s/liqo/values-eks.yaml

# Peer the clusters
liqoctl generate peer-command --kubeconfig ~/.kube/config-eks
# Run the output command on the on-prem cluster
```

**KEDA is already deployed via ArgoCD.** The ScaledObject in `k8s/keda/scaledobject.yaml` watches Prometheus for cluster-wide CPU utilization and scales the worker deployment when it exceeds 80%.

**Demo the burst:**
```bash
# Enable stress mode on the worker (simulates CPU-intensive workload)
kubectl set env deployment/worker STRESS_MODE=true

# Watch cluster CPU in Grafana (burst-demo dashboard)
open https://grafana.192.168.68.93.nip.io:30443/d/burst-demo

# When CPU > 80%:
#   1. KEDA scales worker replicas up
#   2. On-prem nodes are full -> pods go Pending
#   3. Liqo schedules overflow pods to EKS virtual node
#   4. Karpenter provisions a spot instance on EKS (~3-5 min)
#   5. Worker pods run on EKS, connected via Tailscale mesh

# Verify burst pods are on EKS
kubectl get pods -o wide | grep worker
# Some pods show the Liqo virtual node as their node

# Verify cross-cluster connectivity
kubectl exec -it deployment/worker -- curl http://backend-api:8081/health

# Disable stress mode to trigger scale-down
kubectl set env deployment/worker STRESS_MODE=false
# Karpenter removes EKS nodes after consolidation (60s idle)
```

**Timing expectations:**
- Cold-start burst (0 EKS nodes): ~10 minutes
- Warm burst (EKS nodes already running): ~3 minutes
- Scale-to-zero after load drops: ~15 minutes

## Repository Structure

```
platform-forge/
├── .github/workflows/          # CI/CD pipelines
│   ├── ci-reusable.yml         #   Reusable: test, build, push, update manifests
│   ├── ci-api-gateway.yml      #   Trigger: apps/api-gateway/**
│   ├── ci-backend-api.yml      #   Trigger: apps/backend-api/**
│   └── ci-worker.yml           #   Trigger: apps/worker/**
│
├── ansible/                    # Phase 1: On-prem K8s bootstrap
│   ├── inventory/hosts.yml     #   Node inventory (IPs, groups)
│   ├── playbooks/              #   Ordered playbook sequence
│   │   ├── site.yml            #     Master playbook (runs all)
│   │   ├── 00-prerequisites.yml#     OS prep, containerd, kubeadm
│   │   ├── 01-master-init.yml  #     kubeadm init
│   │   ├── 02-worker-join.yml  #     kubeadm join
│   │   ├── 03-cni-cilium.yml   #     Cilium + Hubble install
│   │   └── 04-tailscale.yml    #     Tailscale mesh setup
│   ├── roles/                  #   Reusable Ansible roles
│   │   ├── prerequisites/
│   │   ├── master-init/
│   │   ├── worker-join/
│   │   ├── cni-cilium/
│   │   └── tailscale/
│   └── secrets.example.yml     #   Vault template (copy to secrets.yml)
│
├── terraform/                  # Phase 5: AWS/EKS infrastructure
│   ├── environments/prod/      #   Root module (backend, variables, outputs)
│   └── modules/
│       ├── vpc/                #   VPC, subnets, NAT instance
│       ├── eks/                #   EKS cluster, spot node groups
│       ├── iam/                #   IAM roles, Karpenter IRSA
│       └── tailscale/          #   Tailscale DaemonSet for EKS
│
├── k8s/                        # Kubernetes manifests (GitOps via ArgoCD)
│   ├── argocd/                 #   ArgoCD config + app-of-apps bootstrap
│   ├── monitoring/             #   kube-prometheus-stack + Grafana dashboards
│   │   ├── values.yaml
│   │   └── dashboards/         #     cluster-overview.json, burst-demo.json
│   ├── backstage/              #   Backstage Helm values
│   ├── cert-manager/           #   cert-manager + self-signed ClusterIssuer
│   ├── ingress-nginx/          #   Ingress controller (NodePort)
│   ├── liqo/                   #   Multi-cluster federation (on-prem + EKS)
│   ├── keda/                   #   Event-driven autoscaler + ScaledObject
│   ├── karpenter/              #   EKS spot node provisioner
│   └── apps/                   #   ArgoCD Application manifests + service K8s manifests
│       ├── monitoring.yaml     #     ArgoCD app: kube-prometheus-stack
│       ├── backstage.yaml      #     ArgoCD app: Backstage
│       ├── cert-manager.yaml   #     ArgoCD app: cert-manager
│       ├── ingress-nginx.yaml  #     ArgoCD app: ingress-nginx
│       ├── keda.yaml           #     ArgoCD app: KEDA
│       ├── liqo.yaml           #     ArgoCD app: Liqo
│       ├── api-gateway.yaml    #     ArgoCD app: api-gateway service
│       ├── backend-api.yaml    #     ArgoCD app: backend-api service
│       ├── worker.yaml         #     ArgoCD app: worker service
│       ├── api-gateway/        #     K8s manifests: Deployment, Service, HPA, ServiceMonitor
│       ├── backend-api/        #     K8s manifests: Deployment, Service, HPA, ServiceMonitor
│       └── worker/             #     K8s manifests: Deployment, Service, HPA, ServiceMonitor
│
├── apps/                       # Application source code
│   ├── api-gateway/            #   Go HTTP gateway (:8080)
│   │   ├── src/main.go
│   │   ├── Dockerfile
│   │   └── catalog-info.yaml   #   Backstage entity descriptor
│   ├── backend-api/            #   Python/FastAPI REST API (:8081)
│   │   ├── src/main.py
│   │   ├── Dockerfile
│   │   └── catalog-info.yaml
│   └── worker/                 #   Go background worker (:8082)
│       ├── src/main.go         #     STRESS_MODE=true for burst demos
│       ├── Dockerfile
│       └── catalog-info.yaml
│
├── catalog-info.yaml           # Root Backstage catalog (system + domain)
└── docs/                       # Documentation
```

## Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| CNI | Cilium over Calico | eBPF networking + Hubble observability, stronger portfolio narrative |
| Burst mechanism | Liqo (with fallback) | Purpose-built multi-cluster federation; custom KEDA+Karpenter as backup |
| Container registry | ghcr.io over ECR | GitHub-native, no AWS coupling, free for public repos |
| Backstage deploy | Helm chart | Community-maintained, handles PostgreSQL dependency |
| Image updates | CI-driven manifests | Clean Git audit trail, simpler than ArgoCD Image Updater |
| Burst trigger | KEDA + Prometheus | Cluster-wide CPU scaling (HPA only does per-pod) |
| EKS networking | Tailscale DaemonSet | Simpler than per-pod sidecars, one mesh agent per node |

See the full Architecture Decision Record in `.omc/plans/idp-backstage-hybrid-plan.md`.

## Cost Breakdown

| Component | Always-On | Demo-Only |
|-----------|-----------|-----------|
| EKS Control Plane | $73/mo | $0 (destroyed) |
| NAT Instance (spot t3.micro) | ~$3/mo | $0 (destroyed) |
| Spot Nodes (m5.large) | $25-60/mo when bursting | $0 |
| S3 + DynamoDB | ~$2/mo | ~$2/mo |
| CloudWatch | ~$5/mo | $0 |
| **Total** | **$110-200/mo** | **$0-5/mo** |

On-prem cluster costs only electricity. Tailscale free tier covers up to 100 devices.

## Troubleshooting

**Ansible playbook fails on kubeadm init:**
```bash
# Check if cluster is already initialized
ssh k8s-master-01 "ls /etc/kubernetes/admin.conf"
# If exists, reset first:
ssh k8s-master-01 "sudo kubeadm reset -f"
ansible-playbook playbooks/site.yml --ask-vault-pass
```

**ArgoCD not syncing:**
```bash
# Check ArgoCD app status
argocd app list
argocd app get <app-name>
# Force sync
argocd app sync <app-name>
```

**Tailscale nodes not connecting:**
```bash
# Check Tailscale status on each node
ssh k8s-master-01 "tailscale status"
# Re-authenticate if needed
ssh k8s-master-01 "sudo tailscale up --auth-key=tskey-auth-XXXX --advertise-routes=10.244.0.0/16"
```

**Burst not triggering:**
```bash
# Check KEDA scaler status
kubectl get scaledobject worker-burst-scaler -o yaml
# Check Prometheus query
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090
# Query: 1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

## License

MIT
