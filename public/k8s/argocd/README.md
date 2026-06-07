# Argo CD Platform Add-ons

This directory contains Argo CD `Application` manifests for cluster add-ons used by this project.

## Included add-ons

- `cert-manager`
- `aws-load-balancer-controller`
- `metrics-server`
- `keda`
- `inference-api`
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

Review the following values before syncing:

1. `aws-load-balancer-controller-app.yaml`
   - This manifest is pinned to the current public AWS account and IRSA role ARN.
   - If the target AWS account or Terraform role name changes, update the ARN accordingly.
2. `kube-prometheus-stack-app.yaml`
   - The Grafana admin password is currently set to a bootstrap value for initial setup.
   - Rotate it later or move it to an ExternalSecret/Secret management flow.
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
