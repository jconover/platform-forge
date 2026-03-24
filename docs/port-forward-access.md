# Accessing Cluster Services via kubectl port-forward

When nip.io URLs (e.g., `https://argocd.192.168.68.93.nip.io:30443`) don't resolve — typically
due to router DNS rebinding protection blocking responses that point to private IPs — use
`kubectl port-forward` to access services directly.

## Port-Forward Commands

### ArgoCD (GitOps Dashboard)
```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443
# Access: https://localhost:8443
# Note: self-signed cert, accept the browser warning
```

### Grafana (Monitoring Dashboards)
```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# Access: http://localhost:3000
# Credentials: stored in grafana-admin-secret
```

### Prometheus (Metrics)
```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
# Access: http://localhost:9090
```

### Alertmanager
```bash
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093
# Access: http://localhost:9093
```

### Backstage (Developer Portal)
```bash
kubectl port-forward svc/backstage -n backstage 7007:7007
# Access: http://localhost:7007
```

### Hubble UI (Cilium Network Observability)
```bash
kubectl port-forward svc/hubble-ui -n kube-system 12000:80
# Access: http://localhost:12000
```

### api-gateway (Demo Microservice)
```bash
kubectl port-forward svc/api-gateway -n default 8080:8080
# Access: http://localhost:8080
# Health: http://localhost:8080/health
```

### backend-api (Demo Microservice)
```bash
kubectl port-forward svc/backend-api -n default 8081:8081
# Access: http://localhost:8081
# Health: http://localhost:8081/health
```

### worker (Demo Microservice)
```bash
kubectl port-forward svc/worker -n default 8082:8082
# Access: http://localhost:8082
# Health: http://localhost:8082/health
```

## Run All Port-Forwards at Once

```bash
# Run each in a separate terminal, or background them:
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80 &
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090 &
kubectl port-forward svc/backstage -n backstage 7007:7007 &
kubectl port-forward svc/hubble-ui -n kube-system 12000:80 &

# To stop all port-forwards:
# kill %1 %2 %3 %4 %5
# or: pkill -f "kubectl port-forward"
```

## Why nip.io URLs Don't Work

The ingress URLs like `https://argocd.192.168.68.93.nip.io:30443` rely on nip.io, a wildcard
DNS service that maps `<anything>.<IP>.nip.io` to that IP. This works with public DNS (e.g.,
Google's 8.8.8.8) but fails when your router's DNS has **DNS rebinding protection** enabled.

**Your DNS servers (192.168.1.254, 192.168.68.1)** block nip.io responses because they resolve
to private IPs (192.168.68.93), which triggers rebinding protection.

### Fix Option 1: Configure systemd-resolved to use public DNS for nip.io

```bash
# Create a drop-in config for nip.io domains
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/nip-io.conf > /dev/null <<'EOF'
[Resolve]
DNS=8.8.8.8 8.8.4.4
Domains=~nip.io
EOF
sudo systemctl restart systemd-resolved
```

This routes only `*.nip.io` queries to Google DNS while leaving all other DNS unchanged.

### Fix Option 2: Disable DNS rebinding protection on your router

Look for "DNS Rebinding Protection" or similar in your router's admin interface and add
`nip.io` to an allowlist, or disable the feature entirely (less recommended).

### Fix Option 3: Use /etc/hosts entries instead of nip.io

```bash
sudo tee -a /etc/hosts > /dev/null <<'EOF'
192.168.68.93 argocd.192.168.68.93.nip.io
192.168.68.93 grafana.192.168.68.93.nip.io
192.168.68.93 backstage.192.168.68.93.nip.io
192.168.68.93 liqo-auth.192.168.68.93.nip.io
EOF
```
