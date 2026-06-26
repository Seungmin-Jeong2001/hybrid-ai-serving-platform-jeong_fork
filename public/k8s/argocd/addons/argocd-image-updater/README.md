# Argo CD Image Updater

This addon installs Argo CD Image Updater into the existing `platform-addons` app-of-apps structure, keeps ECR authentication on IRSA, and uses a GitHub App secret for Git write-back.

## Scope of the current implementation

Implemented in the current code:

- Argo CD `Application` for Image Updater
- vendored `v1.2.1` install manifest
- IRSA patch for `argocd-image-updater-controller`
- Terraform IAM role and ECR read policy for the controller
- `ImageUpdater` CR for `pdm-serving`
- controller `ConfigMap` patch with `registries.conf`
- external ECR credential script `ecr-login.sh`
- Deployment patch to mount `ecr-login.sh`
- GitHub App metadata sync to SSM Parameter Store SecureString
- SSM bootstrap host retrieval of GitHub App values and Kubernetes Secret creation

Explicitly **not** implemented in the current code:

- GitHub App private key storage in Git
- Terraform-managed secret values
- AWS access key or secret key based ECR authentication

## Installation structure

```text
platform-addons
  -> public/k8s/argocd/apps
    -> argocd-image-updater-app.yaml
      -> public/k8s/argocd/addons/argocd-image-updater
        -> install-v1.2.1.yaml
        -> pdm-serving-image-updater.yaml
        -> serviceaccount-irsa-patch.yaml
        -> configmap-patch.yaml
        -> deployment-ecr-auth-patch.yaml
```

## Why this addon exists

Manual GitOps deployment for `pdm-serving` has already been validated:

1. update `public/k8s/serving/predictive-model/kustomization.yaml`
2. Argo CD detects the Git change
3. Argo CD syncs
4. `pdm-predictor` rolls to the new image

So the remaining automation work is:

1. install Image Updater
2. let it query private ECR tags
3. let it write updated tags back to Git

## Effective deployment file

For `pdm-serving`, the real image update target is:

- `public/k8s/serving/predictive-model/kustomization.yaml`

not:

- `public/k8s/serving/predictive-model/pdm-isvc.yaml`

That means Image Updater ultimately changes `images[].newTag` in the `kustomization.yaml` file.

## ImageUpdater CR

With the current `v1.2.1` CRD layout, the managed image configuration for this repository is defined with an `ImageUpdater` custom resource.

The addon now ships:

- `pdm-serving-image-updater.yaml`

This CR targets:

- Argo CD Application name pattern: `pdm-serving`
- image: `808379768010.dkr.ecr.ap-northeast-2.amazonaws.com/predictive-model`
- strategy: `newest-build`
- tag filter: `regexp:^v[0-9]+\.[0-9]+\.[0-9]+$`
- write-back target: `kustomization`
- Git branch: `main`

Application annotations may still exist on `pdm-serving`, but the ECR registry lookup and write-back behavior for this flow is defined by the `ImageUpdater` CR instead of relying on Application annotations alone.

## ECR authentication

The default and intended ECR authentication model is:

- IRSA for AWS identity
- external registry credential script for Image Updater

Why:

1. ECR login tokens expire.
2. Static docker-registry secrets are awkward to rotate.
3. This repository already uses Terraform-managed IRSA patterns.
4. The controller image already contains the AWS CLI, so `aws ecr get-login-password` can be used directly.

The controller ServiceAccount name expected by the install manifest is:

- `argocd-image-updater-controller`

The IRSA trust subject is:

- `system:serviceaccount:argocd:argocd-image-updater-controller`

The Terraform policy grants:

- `ecr:GetAuthorizationToken` on `*`
- `ecr:DescribeImages`
- `ecr:DescribeRepositories`
- `ecr:ListImages`
- `ecr:BatchGetImage`

Repository-scoped ECR access is limited to:

- `predictive-model`

## Registry configuration

`configmap-patch.yaml` now provides:

```yaml
registries.conf: |
  registries:
    - name: AWS ECR
      api_url: https://808379768010.dkr.ecr.ap-northeast-2.amazonaws.com
      prefix: 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com
      credentials: ext:/app/config/ecr-login.sh
      credsexpire: 12h
```

The important part is:

- `credentials: ext:/app/config/ecr-login.sh`

This tells Image Updater to execute the mounted script instead of expecting static basic auth credentials.

## External credential script

The addon also provides:

```sh
#!/bin/sh
set -eu
export HOME=/tmp
echo "AWS:$(aws ecr get-login-password --region ap-northeast-2)"
```

Why `HOME=/tmp` matters:

1. the Image Updater container uses `readOnlyRootFilesystem: true`
2. the AWS CLI can fail if it tries to use a non-writable home directory
3. `/tmp` is already mounted as writable in the Deployment

The Deployment patch mounts `ecr-login.sh` from the ConfigMap into `/app/config` with mode `0555`.

## Git write-back authentication

Git write-back uses a GitHub App.

The Kubernetes Secret created for Image Updater is:

- namespace: `argocd`
- secret name: `argocd-image-updater-github-app-creds`

Secret keys:

- `githubAppID`
- `githubAppInstallationID`
- `githubAppPrivateKey`

The `ImageUpdater` CR uses:

- `method: git:secret:argocd/argocd-image-updater-github-app-creds`

## SSM Parameter Store SecureString

GitHub App data is stored in SSM Parameter Store as `SecureString` values:

- `/hasp/argocd/image-updater/github-app/id`
- `/hasp/argocd/image-updater/github-app/installation-id`
- `/hasp/argocd/image-updater/github-app/private-key`

Default behavior:

1. If a parameter does not exist, create it
2. If a parameter already exists, keep the existing value
3. Only overwrite when `rotate_github_app_secret=true`

The workflow stores GitHub App values in Parameter Store from GitHub Secrets.

The SSM-managed bootstrap host then:

1. assumes `eks-bootstrap-admin`
2. reads the three parameter values with `aws ssm get-parameter --with-decryption`
3. creates or updates the Kubernetes Secret `argocd-image-updater-github-app-creds`

Only the parameter names are embedded into the SSM Run Command payload. The actual private key value is not.

## Security model

The following must never be committed:

- GitHub App private key
- AWS access key
- AWS secret access key
- ECR login password
- Kubernetes Secret values

That is why the current implementation:

1. uses IRSA for AWS identity
2. generates ECR auth at runtime with `aws ecr get-login-password`
3. stores GitHub App values in Parameter Store instead of Git
4. uses Terraform only for IAM permissions, not for secret values

The GitHub Actions AWS role used by `setup-argocd.yml` is not managed in this directory. It must already have:

1. `ssm:PutParameter`
2. `ssm:GetParameter`

for:

- `arn:aws:ssm:ap-northeast-2:808379768010:parameter/hasp/argocd/image-updater/github-app/*`

If you later switch these parameters to a customer-managed KMS key, that role and `eks-bootstrap-admin` will also need matching KMS permissions. With the default AWS-managed SSM key path, no extra KMS policy is added here.

## Out of scope

This addon does not address the current KServe status issue:

- `InferenceService Ready=False`
- `Predictor ingress not created`

That remains a separate ingress or gateway problem.

## Suggested verification

```bash
kubectl kustomize public/k8s/argocd/addons/argocd-image-updater
kubectl -n argocd get application argocd-image-updater
kubectl -n argocd get imageupdater pdm-serving-image-updater
kubectl -n argocd get sa argocd-image-updater-controller -o yaml | grep -A5 eks.amazonaws.com/role-arn
kubectl -n argocd get secret argocd-image-updater-github-app-creds
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=300
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=500 | egrep -i "pdm-serving|predictive-model|ecr|error|warn|git|commit|push|tag|updated|credentials|auth"
kubectl -n inference get deploy pdm-predictor -o wide
kubectl -n inference get isvc pdm
```
