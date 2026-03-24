# Cluster Rebuild Guide

How to rebuild the Platform Forge Kubernetes cluster from scratch on wiped nodes. This guide assumes all three MiniPCs have a fresh Ubuntu 24.04 LTS install and nothing else.

## Estimated Time

- Full rebuild (all phases): ~45-60 minutes
- K8s cluster only (Phase 1): ~15-20 minutes
- Platform services (Phase 2+): ~20-30 minutes after cluster is up

## Before You Start

### 1. Verify SSH Access

From your workstation, confirm passwordless SSH to all three nodes:

```bash
ssh justin@192.168.68.93 "hostname"  # → k8s-master-01
ssh justin@192.168.68.84 "hostname"  # → k8s-worker-01
ssh justin@192.168.68.88 "hostname"  # → k8s-worker-02
```

If SSH fails, re-copy your key:

```bash
ssh-copy-id justin@192.168.68.93
ssh-copy-id justin@192.168.68.84
ssh-copy-id justin@192.168.68.88
```

### 2. Set Hostnames (if fresh OS install)

On each node, set the correct hostname so Ansible inventory matches:

```bash
# On 192.168.68.93:
sudo hostnamectl set-hostname k8s-master-01

# On 192.168.68.84:
sudo hostnamectl set-hostname k8s-worker-01

# On 192.168.68.88:
sudo hostnamectl set-hostname k8s-worker-02
```

### 3. Verify Workstation Tools

```bash
ansible --version    # >= 2.15
helm version         # >= 3.12
kubectl version      # >= 1.34
cilium version       # >= 0.15 (optional, for verification)
```

Install missing tools:

```bash
# Ansible
sudo apt install ansible

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# Cilium CLI (optional)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

### 4. Prepare Secrets

```bash
cd ansible

# If you don't already have secrets.yml:
cp secrets.example.yml secrets.yml
```

Edit `secrets.yml` and add your Tailscale auth key:

```yaml
tailscale_auth_key: "tskey-auth-YOUR-KEY-HERE"
```

Generate a reusable auth key at: https://login.tailscale.com/admin/settings/keys

Encrypt the file:

```bash
ansible-vault encrypt secrets.yml
```

## Phase 1: Rebuild the Kubernetes Cluster

### Option A: Run Everything at Once

```bash
cd ansible
ansible-playbook playbooks/site.yml --ask-vault-pass
```

This runs all 5 phases in order:
1. **00-prerequisites.yml** — Disables swap, loads kernel modules, installs containerd + kubeadm/kubelet/kubectl 1.34.x
2. **01-master-init.yml** — Runs `kubeadm init` on k8s-master-01 (skips kube-proxy, Cilium replaces it)
3. **02-worker-join.yml** — Joins both workers to the cluster
4. **03-cni-cilium.yml** — Installs Cilium via Helm with Hubble UI and eBPF kube-proxy replacement
5. **04-tailscale.yml** — Installs Tailscale on all nodes, advertises pod CIDR on master

### Option B: Run Phase by Phase

If you prefer to verify each step:

```bash
cd ansible

# Step 1: OS prerequisites on all nodes (swap, kernel modules, containerd, kubeadm)
ansible-playbook playbooks/00-prerequisites.yml --ask-vault-pass

# Step 2: Initialize the control plane
ansible-playbook playbooks/01-master-init.yml --ask-vault-pass

# Step 3: Join workers
ansible-playbook playbooks/02-worker-join.yml --ask-vault-pass

# Step 4: Install Cilium CNI
ansible-playbook playbooks/03-cni-cilium.yml --ask-vault-pass

# Step 5: Set up Tailscale mesh
ansible-playbook playbooks/04-tailscale.yml --ask-vault-pass
```

### Verify the Cluster

```bash
# Copy the kubeconfig fetched by Ansible
export KUBECONFIG=$(pwd)/kubeconfig

# Or copy it to your default location
cp kubeconfig ~/.kube/config

# Check nodes
kubectl get nodes -o wide
# Expected:
# NAME             STATUS   ROLES           VERSION   INTERNAL-IP      OS-IMAGE
# k8s-master-01   Ready    control-plane   v1.34.x   192.168.68.93   Ubuntu 24.04
# k8s-worker-01   Ready    <none>          v1.34.x   192.168.68.84   Ubuntu 24.04
# k8s-worker-02   Ready    <none>          v1.34.x   192.168.68.88   Ubuntu 24.04

# Check Cilium
cilium status
# All components should be OK

# Check Hubble
cilium hubble ui
# Opens browser to Hubble network observability UI

# Check Tailscale
ssh k8s-master-01 "tailscale status"
# All 3 nodes should appear as mesh peers

# Check pods are running
kubectl get pods -A
# cilium, cilium-operator, hubble-relay, hubble-ui should all be Running
```

## Phase 2: Restore Platform Services

Once the cluster is up, ArgoCD bootstraps everything else.

### Install Local Path Provisioner

The cluster needs a storage provisioner for PersistentVolumeClaims (Prometheus metrics, etc.). Install Rancher's local-path-provisioner and set it as the default StorageClass:

```bash
cd ../
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

# Set as default StorageClass
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify
kubectl get storageclass
# local-path (default)   rancher.io/local-path   Delete   WaitForFirstConsumer   false
```

### Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  -f k8s/argocd/values.yaml
```

Wait for ArgoCD to be ready:

```bash
kubectl -n argocd rollout status deployment/argocd-server
```

Get the admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Bootstrap App-of-Apps

This single command deploys everything else:

```bash
kubectl apply -f k8s/argocd/application.yaml
```

ArgoCD will now auto-deploy (in order of dependency):
- cert-manager + self-signed ClusterIssuer
- ingress-nginx (NodePort 30080/30443)
- kube-prometheus-stack (Prometheus + Grafana)
- Backstage IDP
- KEDA autoscaler
- Liqo multi-cluster federation
- api-gateway, backend-api, worker microservices

### Create Required Secrets

Some services need secrets that aren't in Git. Create these **before** or shortly after the app-of-apps bootstrap:

```bash
# Grafana admin credentials (required — monitoring won't start without this)
kubectl create namespace monitoring 2>/dev/null
kubectl create secret generic grafana-admin-secret \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<your-password>

# Backstage secrets (GitHub token + ArgoCD auth)
# 1. Create a GitHub PAT at https://github.com/settings/tokens (repo read access)
# 2. Generate an ArgoCD API token:
kubectl port-forward svc/argocd-server -n argocd 8080:80 &
argocd login localhost:8080 --insecure --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd account generate-token
# 3. Create the secret with both values:
kubectl create namespace backstage 2>/dev/null
kubectl create secret generic backstage-secrets \
  --namespace backstage \
  --from-literal=github-token=ghp_your_github_pat_here \
  --from-literal=argocd-auth-token=your_argocd_token_here
```

### Build and Push Service Images (First Time Only)

On a fresh cluster, the container images don't exist in ghcr.io yet. The CI pipelines trigger automatically on code changes to `apps/`, but for the initial build you need to trigger them manually.

**Option A: Trigger CI via GitHub Actions (recommended)**

```bash
# Trigger the Backstage build (has workflow_dispatch)
gh workflow run ci-backstage.yml

# Trigger microservice builds via a trivial code change
for svc in api-gateway backend-api worker; do
  echo "// initial build $(date +%s)" >> "apps/${svc}/src/main.go" 2>/dev/null || \
  echo "# initial build $(date +%s)" >> "apps/${svc}/src/main.py" 2>/dev/null
done
git add apps/
git commit -m "ci: trigger initial image builds for fresh cluster"
git push

# Watch the builds
gh run list --workflow=ci-api-gateway.yml
gh run list --workflow=ci-backend-api.yml
gh run list --workflow=ci-worker.yml
```

**Option B: Build and push locally**

If you prefer to build locally (faster, no GitHub Actions required):

```bash
# Log in to ghcr.io
echo $GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin

# Build and push each service
for svc in api-gateway backend-api worker; do
  docker build -t ghcr.io/jconover/platform-forge/${svc}:latest apps/${svc}/
  docker push ghcr.io/jconover/platform-forge/${svc}:latest
done
```

**Backstage image:** Backstage requires a custom build (see `apps/backstage/` if present, or the [Backstage docs](https://backstage.io/docs/deployment/docker)). Until the image is built and pushed to `ghcr.io/jconover/platform-forge/backstage:latest`, the Backstage pod will remain in ImagePullBackOff.

After images are pushed, ArgoCD will detect the manifest updates (from CI) or you can restart the deployments:

```bash
kubectl rollout restart deployment api-gateway
kubectl rollout restart deployment -n backstage backstage
kubectl rollout restart deployment worker
```

### Wait for Everything to Sync

```bash
# Watch ArgoCD sync all apps (takes 5-10 minutes)
watch kubectl get applications -n argocd

# All apps should show:
# SYNC STATUS: Synced
# HEALTH STATUS: Healthy
```

### Access Platform Services

Services are exposed via ingress-nginx on NodePort 30080 (HTTP) / 30443 (HTTPS).
If nip.io DNS doesn't resolve (e.g., Tailscale DNS override), use port-forwarding:

```bash
# ArgoCD UI (port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:80 &
# Open http://localhost:8080
# Login: admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Grafana (port-forward)
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80 &
# Open http://localhost:3000

# Backstage (port-forward)
kubectl port-forward svc/backstage -n backstage 7007:7007 &
# Open http://localhost:7007

# Or via ingress (requires nip.io DNS resolution)
echo "https://argocd.192.168.68.93.nip.io:30443"
echo "https://grafana.192.168.68.93.nip.io:30443"
echo "https://backstage.192.168.68.93.nip.io:30443"

# All microservices healthy
kubectl get pods -l 'app in (api-gateway, backend-api, worker)'
curl http://192.168.68.93:30080/health  # via ingress
```

## Troubleshooting Rebuild Issues

### nip.io URLs don't resolve (DNS rebinding protection)

If `https://argocd.192.168.68.93.nip.io:30443` fails with "Could not resolve host", your
router's DNS servers are blocking nip.io responses because they point to private IPs. This is
DNS rebinding protection — common on home routers.

**Verify the issue:**

```bash
# This will fail (uses your router DNS):
nslookup argocd.192.168.68.93.nip.io

# This will succeed (uses Google DNS directly):
nslookup argocd.192.168.68.93.nip.io 8.8.8.8
```

**Fix: Route nip.io queries to Google DNS via systemd-resolved:**

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/nip-io.conf > /dev/null <<'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
Domains=~nip.io
EOF
sudo systemctl restart systemd-resolved
```

This only affects `*.nip.io` lookups — all other DNS queries continue using your normal DNS
servers. Each workstation that needs to access the cluster URLs needs this fix applied.

**Alternative:** Use `kubectl port-forward` instead — see [docs/port-forward-access.md](port-forward-access.md).

### kubeadm init fails: "port 6443 already in use"

A previous install wasn't fully cleaned. Reset first:

```bash
# On ALL nodes:
ssh k8s-master-01 "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d /var/lib/etcd"
ssh k8s-worker-01 "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d"
ssh k8s-worker-02 "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d"

# Then re-run the playbooks
ansible-playbook playbooks/site.yml --ask-vault-pass
```

### Workers fail to join: "token expired"

kubeadm tokens expire after 24 hours. Re-run master-init to generate a fresh token:

```bash
# On master, generate new join command
ssh k8s-master-01 "sudo kubeadm token create --print-join-command"

# Or re-run the playbook (it regenerates the token)
ansible-playbook playbooks/01-master-init.yml --ask-vault-pass
ansible-playbook playbooks/02-worker-join.yml --ask-vault-pass
```

### Cilium pods in CrashLoopBackOff

Usually a kernel module issue. Verify:

```bash
ssh k8s-master-01 "lsmod | grep -E 'overlay|br_netfilter'"
# Both should be loaded

ssh k8s-master-01 "uname -r"
# Should be 6.x (Ubuntu 24.04 ships 6.8+, which supports Cilium eBPF)
```

If modules are missing, re-run prerequisites:

```bash
ansible-playbook playbooks/00-prerequisites.yml --ask-vault-pass
```

### Tailscale "not authenticated"

Auth key may have expired or been single-use. Generate a new reusable key at https://login.tailscale.com/admin/settings/keys and update `secrets.yml`:

```bash
ansible-vault edit secrets.yml
# Update tailscale_auth_key
ansible-playbook playbooks/04-tailscale.yml --ask-vault-pass
```

### ArgoCD apps stuck in "Unknown" or "OutOfSync"

```bash
# Force a sync
kubectl -n argocd exec -it deployment/argocd-server -- argocd app sync app-of-apps --force

# Or via the CLI
argocd login argocd.192.168.68.93.nip.io:30443 --insecure
argocd app sync --all
```

### Pods can't pull images from ghcr.io

If your repo is private, create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=jconover \
  --docker-password=ghp_your_token_here

# Patch the default service account
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "ghcr-pull-secret"}]}'
```

### containerd not starting

```bash
ssh k8s-master-01 "sudo systemctl status containerd"
ssh k8s-master-01 "sudo journalctl -u containerd --no-pager -n 50"

# Common fix: regenerate the config
ssh k8s-master-01 "sudo containerd config default | sudo tee /etc/containerd/config.toml"
ssh k8s-master-01 "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
ssh k8s-master-01 "sudo systemctl restart containerd"
```

## Full Nuclear Reset

If everything is broken and you want to start completely fresh:

```bash
# On ALL 3 nodes (run via SSH or ansible ad-hoc):
ansible all -m shell -a "
  sudo kubeadm reset -f
  sudo systemctl stop kubelet containerd tailscaled
  sudo apt-mark unhold kubelet kubeadm kubectl
  sudo apt purge -y kubelet kubeadm kubectl containerd.io
  sudo rm -rf /etc/cni /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/containerd
  sudo rm -rf /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/docker.list
  sudo rm -rf /etc/apt/keyrings/kubernetes*.gpg /etc/apt/keyrings/docker*.gpg
  sudo rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf
  sudo tailscale logout 2>/dev/null
  sudo apt purge -y tailscale 2>/dev/null
  sudo apt autoremove -y
" --ask-vault-pass

# Then rebuild from scratch
ansible-playbook playbooks/site.yml --ask-vault-pass
```

## Quick Reference

| Task | Command |
|------|---------|
| Full cluster rebuild | `ansible-playbook playbooks/site.yml --ask-vault-pass` |
| Just prerequisites | `ansible-playbook playbooks/00-prerequisites.yml` |
| Just master init | `ansible-playbook playbooks/01-master-init.yml` |
| Just worker join | `ansible-playbook playbooks/02-worker-join.yml` |
| Just Cilium install | `ansible-playbook playbooks/03-cni-cilium.yml` |
| Just Tailscale setup | `ansible-playbook playbooks/04-tailscale.yml --ask-vault-pass` |
| Install storage provisioner | `kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml` |
| Bootstrap ArgoCD | `helm install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml` |
| Create Grafana secret | `kubectl create secret generic grafana-admin-secret -n monitoring --from-literal=admin-user=admin --from-literal=admin-password=<pw>` |
| Deploy everything | `kubectl apply -f k8s/argocd/application.yaml` |
| Check cluster | `kubectl get nodes -o wide` |
| Check Cilium | `cilium status` |
| Check ArgoCD apps | `kubectl get applications -n argocd` |
| Nuclear reset | See "Full Nuclear Reset" section above |
