# ECR-over-VPN 런북 (실 push까지)

목표: 내부 노드(10.42.0.0/24)에서 **VPN으로만** ECR에 push. 일반 egress 금지.
검증 도구: `private/ci/model-build-vpn-ecr-pipeline-mock.sh` (train/package mock + 실제 promote 프로브).

## 0. 두 갈래
- **manifest-only** (수정 0): 이미 ECR에 있는 이미지에 태그만 put → `ecr.api`/`sts`만 사용, S3 불필요. VPN 경로 실증용.
- **full push**: 새 레이어 업로드 → S3 인터페이스 엔드포인트 **필수** (= tfvars 수정 + apply).

## 1. (full push만) S3 인터페이스 엔드포인트 켜기 — IaC
`PUBLIC_TERRAFORM_TFVARS` 변수에 추가:
```hcl
enable_s3_interface_endpoint = true
```
명령:
```bash
gh api repos/SGS-Strategy/hybrid-ai-serving-platform/actions/variables/PUBLIC_TERRAFORM_TFVARS --jq '.value' > /tmp/tfvars.cur
{ cat /tmp/tfvars.cur; printf '\nenable_s3_interface_endpoint = true\n'; } > /tmp/tfvars.new
gh variable set PUBLIC_TERRAFORM_TFVARS --repo SGS-Strategy/hybrid-ai-serving-platform < /tmp/tfvars.new
# plan으로 "s3_interface 1개 create, 그 외 no-op" 확인 후 apply
gh workflow run public-terraform-deploy.yml --repo SGS-Strategy/hybrid-ai-serving-platform -f action=plan
gh workflow run public-terraform-deploy.yml --repo SGS-Strategy/hybrid-ai-serving-platform -f action=apply
```
> 이 엔드포인트는 `private_dns_only_for_inbound_resolver_endpoint = true`라 **resolver inbound 경유 질의에서만** 사설 IP로 풀린다(아래 2번 필수). VPCE SG는 `private_cloud_cidrs`(10.42)에서 443 이미 허용.

## 2. 노드 DNS 포워딩 — 노드 설정(IaC 아님)
노드/CoreDNS가 `*.amazonaws.com`을 **resolver inbound IP**로 포워딩해야 ecr/sts/s3가 사설 IP로 풀린다.
resolver IP 확인(apply마다 바뀜):
```bash
# OIDC 자격증명 있는 곳에서
terraform -chdir=public/terraform output -json resolver_inbound_ips
```
노드 예시(dnsmasq):
```
server=/amazonaws.com/<resolver_inbound_ip_1>
server=/amazonaws.com/<resolver_inbound_ip_2>
```
미설정 시 공인 IP로 풀려 mock이 "일반 egress"로 차단한다.

## 3. 데이터플레인 (호스트 route + qrouter no-SNAT) — **자동화 스크립트**
IPsec selector가 `10.42.0.0/24 === 10.0.0.0/16`이라 패킷 소스가 10.42로 유지돼야 터널을 탄다.
`private/ci/ecr-vpn-dataplane.sh`가 ① 호스트 라우트(VPC→MacMini) ② ip_forward ③ qrouter no-SNAT를 idempotent하게 처리한다. qrouter는 Neutron 재생성 시 규칙이 사라지므로 systemd timer로 주기 재적용.
```bash
# kt-cloud 호스트에서 (root)
sudo VPC_CIDR=10.0.0.0/16 BASTION_IP=192.168.0.30 \
  private/ci/ecr-vpn-dataplane.sh apply      # 1회 적용
sudo VPC_CIDR=10.0.0.0/16 BASTION_IP=192.168.0.30 \
  private/ci/ecr-vpn-dataplane.sh install    # systemd timer 영구화(2분 주기 재적용)
private/ci/ecr-vpn-dataplane.sh status       # 확인
```
> kt-cloud 호스트는 NOPASSWD 아님 → root(sudo)로 1회 install 하면 이후 자동 유지.

## 4. 검증/실행 — build-worker(10.42)에서
```bash
# (a) readiness만 (아무것도 push 안 함)
./private/ci/model-build-vpn-ecr-pipeline-mock.sh
# (b) 수정 없이 진짜 VPN 검증 (S3 불필요) — 기존 이미지 retag
AWS_ACCOUNT_ID=<acct> ./private/ci/model-build-vpn-ecr-pipeline-mock.sh \
  --manifest-only --ecr-repo inference-api --src-tag latest --new-tag vpn-test
# (c) 풀 push (1번 S3 엔드포인트 + 2·3번 완료 후)
AWS_ACCOUNT_ID=<acct> ./private/ci/model-build-vpn-ecr-pipeline-mock.sh --push
```
프로브가 `FAIL: ... 공인 IP`면 2번(DNS), `해석은 사설인데 timeout`이면 3번(라우팅/SNAT) 문제다.

## 현재 상태(2026-06-30)
- VPN 터널: ESTABLISHED (메모리 기준)
- ECR api/dkr/sts 인터페이스 엔드포인트: 있음 / S3 인터페이스 엔드포인트: **OFF** (1번 미적용)
- 2·3번: 미적용/미검증
→ 지금은 **manifest-only(b)로 VPN 경로 실증**이 수정 없이 가능한 최대치. full push(c)는 1·2·3 선행 필요.
