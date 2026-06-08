# GitHub-hosted runner는 private EKS API에 접근할 수 없으므로, 이 Kubernetes/Helm Terraform 리소스는 SSM 관리 인스턴스에서 실행
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 900

  values = [
    yamlencode({
      global = {
        nodeSelector = {
          workload = "system"
        }
      }
      controller = {
        nodeSelector = {
          workload = "system"
        }
      }
      dex = {
        nodeSelector = {
          workload = "system"
        }
      }
      redis = {
        nodeSelector = {
          workload = "system"
        }
      }
      repoServer = {
        nodeSelector = {
          workload = "system"
        }
      }
      server = {
        nodeSelector = {
          workload = "system"
        }
      }
      applicationSet = {
        nodeSelector = {
          workload = "system"
        }
      }
      notifications = {
        nodeSelector = {
          workload = "system"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    time_sleep.wait_for_aws_load_balancer_controller_webhook,
  ]
}
