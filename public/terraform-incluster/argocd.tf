# GitHub-hosted runner는 private EKS API에 접근할 수 없으므로, 이 Kubernetes/Helm Terraform 리소스는 SSM 관리 인스턴스에서 실행

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true  # namespace는 terraform이 아닌 helm이 직접 생성 (finalizer 문제 방지)
  wait             = true
  timeout          = 900

  values = [
    yamlencode({
      global = {
        nodeSelector = {
          workload = "general"
        }
      }
      controller = {
        nodeSelector = {
          workload = "general"
        }
      }
      dex = {
        nodeSelector = {
          workload = "general"
        }
      }
      redis = {
        nodeSelector = {
          workload = "general"
        }
      }
      repoServer = {
        nodeSelector = {
          workload = "general"
        }
      }
      server = {
        nodeSelector = {
          workload = "general"
        }
      }
      applicationSet = {
        nodeSelector = {
          workload = "general"
        }
      }
      notifications = {
        nodeSelector = {
          workload = "general"
        }
      }
    })
  ]

  depends_on = [
    time_sleep.wait_for_aws_load_balancer_controller_webhook,
  ]
}
