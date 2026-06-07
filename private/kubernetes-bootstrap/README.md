# OpenStack Kubernetes Bootstrap

이 디렉터리는 `private/openstack` Terraform output을 읽어서
OpenStack VM에 kubeadm 기반 Kubernetes를 설치하는 bootstrap 도구를 제공합니다.

## 전제 조건

- Terraform apply가 완료되어 `control_plane_nodes` output이 있어야 합니다.
- VM image는 SSH, cloud-init, systemd, curl, apt를 지원하는 Ubuntu 계열 image를 사용합니다.
- `cirros` image는 OpenStack smoke provisioning 확인용이며 Kubernetes node로 쓰지 않습니다.
- bootstrap 실행 위치에서 VM의 private IP 또는 floating IP로 SSH가 가능해야 합니다.

로컬 DevStack처럼 호스트가 floating IP 대역에 직접 접근하지 못하는 경우에는 LXD 컨테이너를
SSH proxy로 사용합니다.

```sh
export HA_OPENSTACK_SSH_PROXY_CONTAINER=ha-openstack
```

## Terraform 값 예시

```sh
source .ha/openstack-local/openrc.sh
export HA_PROVIDER=openstack
export TF_VAR_project_name=hybrid-ai-dev
export TF_VAR_external_network_id="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && source openrc admin admin && openstack network show public -f value -c id')"
export TF_VAR_floating_ip_pool=public
export TF_VAR_assign_floating_ips=true
export TF_VAR_ssh_allowed_cidrs='["0.0.0.0/0"]'
export TF_VAR_control_plane_count=1
export TF_VAR_build_worker_count=0
export TF_VAR_gpu_worker_count=0
export TF_VAR_control_plane_image_name=ubuntu-24.04
export TF_VAR_control_plane_flavor_name=m1.medium
./ha up openstack --auto-approve
```

## 실행

먼저 inventory가 맞는지 확인합니다.

```sh
private/kubernetes-bootstrap/bootstrap-k8s.sh --dry-run
```

문제가 없으면 `ha`에서 실행합니다.

```sh
export HA_OPENSTACK_SSH_USER=ubuntu
export HA_OPENSTACK_SSH_TARGET=auto
export HA_OPENSTACK_SSH_PROXY_CONTAINER=ha-openstack
export HA_OPENSTACK_TFSTATE=.ha/tfstate/private-cloud-foundation.tfstate
./ha up openstack-kubernetes --auto-approve
```

선택적으로 Kubernetes 버전과 CNI를 조정할 수 있습니다.

```sh
export HA_K8S_VERSION_MINOR=v1.36
export HA_K8S_POD_CIDR=192.168.0.0/16
export HA_K8S_CNI_MANIFEST=https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml
```

성공하면 아래 파일이 생성됩니다.

```txt
.ha/openstack/kubeconfig
.ha/handoff/openstack-kubernetes.env
```

이후 baseline manifest를 적용합니다.

```sh
KUBECONFIG=.ha/openstack/kubeconfig ./ha up kubernetes
```

로컬 DevStack처럼 호스트가 floating IP로 직접 라우팅되지 않는 경우에는 manifest를 렌더링한 뒤
SSH proxy를 통해 control-plane에서 적용합니다.

```sh
kubectl kustomize private/kubernetes \
  | ssh -o ProxyCommand='lxc exec ha-openstack -- nc %h %p' \
      -i .ha/ssh/hybrid-ai-private-admin \
      ubuntu@<floating-ip> \
      'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -'
```

GitHub Actions의 `bootstrap_kubernetes=true` 경로도 같은 방식을 사용합니다. runner가 Kubernetes API
endpoint에 직접 접속할 수 없어도 SSH proxy가 가능하면 baseline manifest 적용까지 이어갈 수 있습니다.

## 운영 기준

로컬 DevStack에서는 1대 control-plane으로 end-to-end 흐름만 검증합니다.
production 기준은 control-plane 3대 이상, worker 분리, replicated/external storage,
ingress, cert-manager, monitoring, backup 구성이 필요하며 `ha prod check` 기준을 통과해야 합니다.
