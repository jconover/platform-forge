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
kubectl version      # >= 1.32
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
1. **00-prerequisites.yml** — Disables swap, loads kernel modules, installs containerd + kubeadm/kubelet/kubectl 1.32.x
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
# k8s-master-01   Ready    control-plane   v1.32.x   192.168.68.93   Ubuntu 24.04
# k8s-worker-01   Ready    <none>          v1.32.x   192.168.68.84   Ubuntu 24.04
# k8s-worker-02   Ready    <none>          v1.32.x   192.168.68.88   Ubuntu 24.04

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

Some services need secrets that aren't in Git:

```bash
# Backstage GitHub token (for catalog discovery)
kubectl create namespace backstage 2>/dev/null
kubectl create secret generic backstage-github-token \
  --namespace backstage \
  --from-literal=GITHUB_TOKEN=ghp_your_github_pat_here

# Grafana admin password (optional, Helm chart generates one if not set)
# Retrieve auto-generated:
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d && echo
```

### Wait for Everything to Sync

```bash
# Watch ArgoCD sync all apps (takes 5-10 minutes)
watch kubectl get applications -n argocd

# All apps should show:
# SYNC STATUS: Synced
# HEALTH STATUS: Healthy
```

### Verify Platform Services

```bash
# ArgoCD UI
echo "https://argocd.192.168.68.93.nip.io:30443"

# Grafana dashboards
echo "https://grafana.192.168.68.93.nip.io:30443"

# Backstage portal
echo "https://backstage.192.168.68.93.nip.io:30443"

# All microservices healthy
kubectl get pods -l 'app in (api-gateway, backend-api, worker)'
curl http://192.168.68.93:30080/health  # via ingress
```

## Troubleshooting Rebuild Issues

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
| Bootstrap ArgoCD | `helm install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml` |
| Deploy everything | `kubectl apply -f k8s/argocd/application.yaml` |
| Check cluster | `kubectl get nodes -o wide` |
| Check Cilium | `cilium status` |
| Check ArgoCD apps | `kubectl get applications -n argocd` |
| Nuclear reset | See "Full Nuclear Reset" section above |
