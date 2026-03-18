# ---------------------------------------------------------------------------
# Tailscale DaemonSet Module
#
# Deploys Tailscale on every EKS node as a DaemonSet. Each node joins the
# Tailscale mesh, advertises the pod CIDR, and accepts routes from on-prem
# nodes. This creates a zero-trust overlay network for hybrid cloud bursting.
#
# Architecture:
#   EKS node (Tailscale) <--WireGuard--> on-prem node (Tailscale)
#   Pods on EKS reachable from on-prem via advertised pod CIDR
#   On-prem services reachable from EKS pods via accepted routes
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "tailscale" {
  metadata {
    name = var.tailscale_namespace
    labels = {
      name                           = var.tailscale_namespace
      environment                    = var.environment
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# ServiceAccount
# Tailscale pods use this SA. No special AWS permissions needed since
# Tailscale operates at the network layer, not AWS API layer.
# ---------------------------------------------------------------------------
resource "kubernetes_service_account_v1" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "tailscale"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# RBAC: Role and RoleBinding
# Tailscale needs to read/write secrets in its own namespace to store node keys.
# ---------------------------------------------------------------------------
resource "kubernetes_role_v1" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "get", "update", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.tailscale.metadata[0].name
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# Secret: Tailscale Auth Key
# Stored as a Kubernetes secret. The DaemonSet mounts this as an env var.
# The auth key should be a reusable, ephemeral key from the Tailscale admin console.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "tailscale"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    TS_AUTHKEY = var.tailscale_auth_key
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# DaemonSet: Tailscale on every EKS node
# ---------------------------------------------------------------------------
resource "kubernetes_daemon_set_v1" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "tailscale"
      "app.kubernetes.io/component"  = "node-agent"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "tailscale"
      }
    }

    template {
      metadata {
        labels = merge(
          {
            "app.kubernetes.io/name"      = "tailscale"
            "app.kubernetes.io/component" = "node-agent"
          },
          var.tags
        )
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.tailscale.metadata[0].name
        automount_service_account_token = true
        host_network                    = false
        dns_policy                      = "ClusterFirstWithHostNet"

        # Tailscale requires NET_ADMIN to configure the WireGuard interface
        security_context {
          run_as_non_root = false
        }

        init_container {
          name  = "tailscale-init"
          image = var.tailscale_image

          # Enable IP forwarding so the node can forward traffic for other pods
          command = ["/bin/sh", "-c", "sysctl -w net.ipv4.ip_forward=1 || true; sysctl -w net.ipv6.conf.all.forwarding=1 || true"]

          security_context {
            privileged = true
          }
        }

        container {
          name  = "tailscale"
          image = var.tailscale_image

          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }

          # Hostname in the Tailscale admin console: eks-<node-name>
          env {
            name = "TS_HOSTNAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          # Store Tailscale state (node keys) in the Kubernetes secret
          env {
            name  = "TS_KUBE_SECRET"
            value = "tailscale-state-$(NODE_NAME)"
          }

          # Advertise pod CIDR routes to the Tailscale mesh
          # On-prem nodes will be able to route to EKS pods via these routes
          env {
            name  = "TS_ROUTES"
            value = var.eks_pod_cidr
          }

          # Accept routes from other Tailscale nodes (e.g., on-prem cluster subnets)
          env {
            name  = "TS_ACCEPT_ROUTES"
            value = var.accept_routes ? "true" : "false"
          }

          # Extra args: run as a subnet router, not an exit node
          env {
            name  = "TS_EXTRA_ARGS"
            value = "--advertise-tags=tag:eks-node"
          }

          env {
            name  = "TS_USERSPACE"
            value = "false" # Use kernel WireGuard for better performance
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN", "NET_RAW"]
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }

          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }
        }

        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }

        volume {
          name = "tailscale-state"
          empty_dir {}
        }

        # Tolerate all taints so Tailscale runs on every node including tainted ones
        toleration {
          operator = "Exists"
          effect   = "NoSchedule"
        }

        toleration {
          operator = "Exists"
          effect   = "NoExecute"
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.tailscale,
    kubernetes_service_account_v1.tailscale,
    kubernetes_secret_v1.tailscale_auth,
  ]
}
