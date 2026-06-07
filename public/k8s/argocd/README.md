# Argo CD Platform Add-ons

This directory contains Argo CD `Application` manifests for cluster add-ons used by this project.

## Included add-ons

- `cert-manager`
- `aws-load-balancer-controller`
- `metrics-server`
- `keda`
- `kube-prometheus-stack`
- `loki`
- `promtail`
- `chaos-mesh`
- `kserve-crd`
- `kserve`

## Excluded add-on

- `ebs-csi-driver`
  - This repository manages EBS CSI through Terraform in [public/terraform/ebs_csi.tf](C:/git_clone/hybrid-ai-serving-platform/public/terraform/ebs_csi.tf), so it is intentionally excluded from Argo CD.

## Before sync

Update the following values before syncing:

1. `aws-load-balancer-controller-app.yaml`
   - Replace `REPLACE_ME_WITH_AWS_LB_CONTROLLER_ROLE_ARN` with the Terraform output `aws_load_balancer_controller_role_arn`.
2. `kube-prometheus-stack-app.yaml`
   - Replace `CHANGE_ME_GRAFANA_ADMIN_PASSWORD` with the actual Grafana admin password, or move the password handling to an ExternalSecret/Secret management flow.
3. `kserve-app.yaml`
   - This manifest assumes KServe Standard mode.
   - If the cluster standardizes on `RawDeployment`/older KServe behavior, align this value with the deployed KServe version and the `InferenceService` manifests in [public/k8s/serving/predictive-model/pdm-isvc.yaml](C:/git_clone/hybrid-ai-serving-platform/public/k8s/serving/predictive-model/pdm-isvc.yaml).

## Apply after Argo CD is installed

```powershell
kubectl apply -k public/k8s/argocd/apps
```

## Notes

- `loki-gateway` is not a separate Argo CD application here. It is deployed as a component of the Loki Helm chart.
- `promtail` is configured to push logs to `http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push`.
- `metrics-server` is configured with EKS-friendly kubelet flags.
