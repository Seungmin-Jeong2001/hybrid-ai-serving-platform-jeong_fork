# Argo CD Image Updater

This addon installs Argo CD Image Updater into the existing `platform-addons` app-of-apps structure, keeps ECR authentication on IRSA, and uses a GitHub App plus SSM Parameter Store SecureString for Git write-back credentials.

## Scope of the current implementation

Implemented in the current code:

- Argo CD `Application` for Image Updater
- vendored `v1.2.1` install manifest
- IRSA patch for `argocd-image-updater-controller`
- Terraform IAM role and ECR read policy for the controller
- minimal controller `ConfigMap` patch
- GitHub App metadata sync to SSM Parameter Store SecureString
- SSM bootstrap host retrieval of GitHub App values and Kubernetes Secret creation
- `pdm-serving` write-back-method update to use the GitHub App secret

Explicitly **not** implemented in the current code:

- GitHub App private key storage in Git
- Terraform-managed secret values
- ECR IAM User based docker-registry Secret automation

## Installation structure

```text
platform-addons
  -> public/k8s/argocd/apps
    -> argocd-image-updater-app.yaml
      -> public/k8s/argocd/addons/argocd-image-updater
        -> install-v1.2.1.yaml
        -> serviceaccount-irsa-patch.yaml
        -> configmap-patch.yaml
```

## Why this addon exists

Manual GitOps deployment for `pdm-serving` has already been validated:

1. update `public/k8s/serving/predictive-model/kustomization.yaml`
2. Argo CD detects the Git change
3. Argo CD syncs
4. `pdm-predictor` rolls to the new image

So the missing piece for automation was the Image Updater controller itself, not the Kustomize-based deployment path.

## Effective deployment file

For `pdm-serving`, the real image update target is:

- `public/k8s/serving/predictive-model/kustomization.yaml`

not:

- `public/k8s/serving/predictive-model/pdm-isvc.yaml`

That means Image Updater should ultimately change `images[].newTag` in the `kustomization.yaml` file.

## ECR authentication

The default and intended ECR authentication model is IRSA.

Why:

1. ECR login tokens expire.
2. Static docker-registry secrets are awkward to rotate.
3. This repository already uses Terraform-managed IRSA patterns.

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

## Git write-back authentication

Git write-back uses a GitHub App.

The Kubernetes Secret created for Image Updater is:

- namespace: `argocd`
- secret name: `argocd-image-updater-github-app-creds`

Secret keys:

- `githubAppID`
- `githubAppInstallationID`
- `githubAppPrivateKey`

The `pdm-serving` Application uses:

```yaml
argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/argocd-image-updater-github-app-creds
```

## SSM Parameter Store SecureString

GitHub App data is stored in SSM Parameter Store as `SecureString` values:

- `/hasp/argocd/image-updater/github-app/id`
- `/hasp/argocd/image-updater/github-app/installation-id`
- `/hasp/argocd/image-updater/github-app/private-key`

Default behavior:

1. If a parameter does not exist, create it
2. If a parameter already exists, keep the existing value
3. Only overwrite when `rotate_github_app_secret=true`

This keeps normal bootstrap runs idempotent while still supporting explicit GitHub App key rotation.

## Bootstrap secret flow

The workflow stores GitHub App values in Parameter Store from GitHub Secrets.

The SSM-managed bootstrap host then:

1. assumes `eks-bootstrap-admin`
2. reads the three parameter values with `aws ssm get-parameter --with-decryption`
3. creates or updates the Kubernetes Secret `argocd-image-updater-github-app-creds`

Only the parameter names are embedded into the SSM Run Command payload. The actual private key value is not.

## Security model

The GitHub App private key must not be written to:

- Git
- Terraform state
- `commands.json`
- SSM Run Command payload
- GitHub Actions logs

That is why the current implementation:

1. writes secret values to Parameter Store from GitHub Actions
2. reads them inside the SSM-managed instance
3. uses Terraform only for IAM permissions, not for secret values

The GitHub Actions AWS role used by `setup-argocd.yml` is not managed in this directory. It must already have:

1. `ssm:PutParameter`
2. `ssm:GetParameter`

for:

- `arn:aws:ssm:ap-northeast-2:808379768010:parameter/hasp/argocd/image-updater/github-app/*`

If you later switch these parameters to a customer-managed KMS key, that role and `eks-bootstrap-admin` will also need the matching KMS decrypt or encrypt permissions. With the default AWS-managed SSM key path, no extra KMS policy is added here.

## ECR IAM User fallback

The repository secrets `AWS_ECR_IAM_ID` and `AWS_ECR_IAM_PASS` are **not** used in the current automation path.

They should be treated only as a fallback/manual option because:

1. they reintroduce static credentials into the path
2. they still rely on expiring ECR login tokens
3. they are inferior to IRSA for normal operation

If needed, that path should remain documented as a manual or exceptional fallback, not the default bootstrap behavior.

## ConfigMap scope

`configmap-patch.yaml` should only contain non-secret controller-wide settings, such as:

- log level
- polling interval
- git commit user/email

It should not contain:

- GitHub App private key material
- GitHub tokens
- AWS keys
- ECR passwords
- uncertain credential-specific settings

## Out of scope

This addon does not address the current KServe status issue:

- `InferenceService Ready=False`
- `Predictor ingress not created`

That remains a separate ingress/gateway problem.

## Suggested verification

```bash
kubectl kustomize public/k8s/argocd/addons/argocd-image-updater
terraform -chdir=public/terraform fmt
kubectl -n argocd get application argocd-image-updater
kubectl -n argocd get sa argocd-image-updater-controller -o yaml | grep -A5 eks.amazonaws.com/role-arn
kubectl -n argocd get secret argocd-image-updater-github-app-creds
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=300
kubectl -n inference get isvc pdm
```
