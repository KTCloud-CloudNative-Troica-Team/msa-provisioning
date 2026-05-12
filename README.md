# msa-provisioning

Troica Market Service MSA의 **AWS 인프라 (Terraform) + Kubernetes 클러스터 셋업 (Ansible)** 단일 진실의 원천.

> 매니페스트 + SPEC + ADR: [msa-argocd-manifest](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest)
> 트러블슈팅: [TROUBLESHOOTING.md](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md)

## 시스템 아키텍처

![AWS 배포 아키텍처](https://raw.githubusercontent.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/main/docs/images/AWS-arch.png)

> 모든 다이어그램은 `msa-argocd-manifest/docs/images/`에 단일 위치 보관.

---

## 빠른 시작 (3인 협업, L3 — 클러스터 부트스트랩까지)

본 레포만으로 AWS Phase 0 영구 자원 → 임시 클러스터 자원 → k8s/ArgoCD 셋업까지.

### 사전 요구사항

| 항목 | 버전 / 설정 |
|---|---|
| AWS CLI | 2.x + `aws configure`로 IAM 자격 등록 |
| Terraform | **1.10.0+** (S3 backend native lockfile 요구) |
| Ansible | 2.16+ (WSL Ubuntu 또는 Linux/Mac) |
| Go | 1.22+ — `ecr-credential-provider` 빌드용 (R-29) |
| SSH key | `~/.ssh/ktcloud-bastion-node-key` (저장소 루트 `ssh-key-gen.bash` 참조) |
| IAM 정책 | [상세 정책](#iam-정책-aws-cli-사용자에-부착) — EC2/ELB/EFS/IAM Role 최소 권한 |

### 작업 흐름

```
1. (1인, 1회) S3 backend bucket 수동 생성 — terraform 외부
2. (1인, 1회) terraform apply — 영구 + 임시 자원 일괄
3. (1인, 1회) GitHub Org Secrets/Variables 등록 — AWS_ACCOUNT_ID / MANIFEST_PAT / AWS_DEPLOYMENTS_ENABLED=true
4. (1인) Go 빌드 — ecr-credential-provider 바이너리
5. (1인) Ansible 실행 — k8s + ArgoCD + ECR credential provider 셋업
6. (검증 후) destroy-temp.sh — 임시 자원만 정리 (영구 자원 유지)
```

각 단계 상세는 아래 섹션.

---

## Phase 0 — AWS 인프라 자원 분류

비용 사이클 가능하도록 **영구 / 임시 / 수동** 자원 분리.

| 분류 | 자원 | 보호 방식 | 월 비용 |
|------|------|-----------|---------|
| **영구** | OIDC Provider, IAM Role, IAM Role Policy | `lifecycle { prevent_destroy = true }` | ~$0 |
| **영구** | ECR KMS key + alias | `prevent_destroy = true` | ~$1 |
| **영구** | ECR 레포 × 6 + lifecycle policy | `prevent_destroy = true` + `force_delete = true` | ~$0 (이미지 적음) |
| **영구** | VPC, Subnet, RT, IGW, SG, Key Pair | (변경 없음, 비용 0) | $0 |
| **임시** | EC2 × 8, EBS × 3, EFS, NAT × 2, NLB, EIP × 4 | `scripts/destroy-temp.{sh,ps1} -target` | ~$300 |
| **임시** | VPC Endpoint Interface × 2 + S3 Gateway | `scripts/destroy-temp.{sh,ps1} -target` | ~$14 |
| **수동** | S3 backend bucket | Terraform 외부 1회 생성 (닭과 달걀 회피) | <$0.5 |

**ARN/URL 안정성**: 영구 자원은 모두 **name-based**. destroy → apply 후에도 ARN/URL 동일 → GitHub Secrets 영구 유효.

---

## STEP 1 — S3 backend 부트스트랩 (1인, 1회)

`terraform/backend.tf`에서 `<SUFFIX>` placeholder를 실제 값으로 치환 (예: `troica-2026`).

### Linux/Mac (bash)

```bash
SUFFIX=troica-2026
BUCKET="troica-tfstate-${SUFFIX}"
REGION=ap-northeast-2

# 1) bucket 생성
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# 2) Versioning (state 실수 복구용 — 강력 권장)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# 3) SSE-S3 암호화
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]'

# 4) Public Access Block
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 5) terraform/backend.tf의 <SUFFIX> 치환 (편집기 또는 sed)
sed -i "s|troica-tfstate-<SUFFIX>|$BUCKET|" terraform/backend.tf
```

### Windows PowerShell

```powershell
$SUFFIX = "troica-2026"
$BUCKET = "troica-tfstate-$SUFFIX"
$REGION = "ap-northeast-2"

aws s3api create-bucket --bucket $BUCKET --region $REGION `
  --create-bucket-configuration LocationConstraint=$REGION

aws s3api put-bucket-versioning --bucket $BUCKET `
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket $BUCKET `
  --server-side-encryption-configuration "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]"

aws s3api put-public-access-block --bucket $BUCKET `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

(PowerShell의 JSON 따옴표 보존 문제 회피를 위해 AWS CLI shorthand 사용.)

---

## STEP 2 — terraform init + apply

### 첫 init (이전 로컬 state가 있는 경우 마이그레이션)

```bash
cd terraform
terraform init -migrate-state
# 프롬프트: "Do you want to copy existing state to the new backend?" → yes
```

처음부터 S3 backend 사용 시:
```bash
cd terraform
terraform init
```

### 협업자 (다른 멤버, 1회)

backend.tf가 main에 머지된 후:
```bash
git pull
cd terraform
terraform init
```

S3 lockfile (`use_lockfile = true`)로 동시 apply 방지. DynamoDB 불필요.

### apply

```bash
terraform plan -out phase-0.tfplan
terraform apply phase-0.tfplan
```

기대: ~71개 자원 생성 (영구 17 + 임시 ~45 + 부수). 약 5-15분.

### output 확인 + Org Secrets 등록

```bash
terraform output gha_ecr_push_role_arn
# arn:aws:iam::<ACCOUNT_ID>:role/troica-gha-ecr-push

terraform output ecr_registry_url
# <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com
```

**GitHub Organization Settings → Secrets and variables → Actions**:

| 종류 | 이름 | 값 |
|------|------|----|
| Secret | `AWS_ACCOUNT_ID` | 위 ARN의 12자리 account_id |
| Secret | `MANIFEST_PAT` | fine-grained PAT (`msa-argocd-manifest` contents:write + pull-requests:write) |
| **Variable** | `AWS_DEPLOYMENTS_ENABLED` | `true` (BACKLOG R-19 활성화 — 6개 서비스 CI 일괄 활성) |

---

## STEP 3 — ecr-credential-provider 바이너리 빌드 (R-29)

`cloud-provider-aws`는 GitHub Release에 binary asset 미게시 (assets=0). Go 소스에서 직접 빌드:

```bash
# WSL/Linux/Mac
sudo apt install -y golang-go    # 또는 brew install go
mkdir -p /tmp/build && cd /tmp/build
git clone --depth 1 --branch v1.30.10 https://github.com/kubernetes/cloud-provider-aws.git
cd cloud-provider-aws
CGO_ENABLED=0 go build -o /tmp/ecr-credential-provider ./cmd/ecr-credential-provider

# 검증
ls -la /tmp/ecr-credential-provider
# -rwxr-xr-x ... 30033150 ... /tmp/ecr-credential-provider (~30MB)
```

ansible의 `ecr-credential-provider-setup.yaml`이 위 binary를 모든 노드에 copy.

---

## STEP 4 — Ansible 실행 (k8s + ArgoCD + ECR credential provider)

### 사전 — Bastion fingerprint 등록 (PowerShell 또는 bash, 1회)

```bash
# terraform output ap-northeast-2a-bastion-node-connect-command 참조
ssh ec2-user@<2a-bastion-ip> -i ~/.ssh/ktcloud-bastion-node-key
# "yes" 입력 후 exit

ssh ec2-user@<2b-bastion-ip> -i ~/.ssh/ktcloud-bastion-node-key
# "yes" 입력 후 exit
```

### Ansible ping

WSL/Linux/Mac에서:
```bash
cd ansible
ansible all -m ping -i inventory.ini -o
```

기대: 6개 노드 모두 `pong`. 실패 시 ssh key 권한 (`chmod 600 ~/.ssh/ktcloud-bastion-node-key`) 또는 bastion fingerprint 미등록 확인.

### 전체 playbook 실행

```bash
ansible-playbook -i inventory.ini main.yaml
```

소요: ~10-15분. 단계:
1. k8s-pre-setup, k8s-pkg-install, containerd-setup (모든 노드)
2. master-init (첫 master), master-cni-setup (Calico), master-python-setup
3. join-master (HA), join-worker (worker)
4. helm-setup → nlb-setup (AWS LB Controller) → argocd-setup
5. **ecr-credential-provider-setup** — `/tmp/ecr-credential-provider` binary가 있어야 작동

마지막 단계가 kubelet에 ECR 인증 설정 + 재시작. 검증: 어느 워커 노드에서:
```bash
ps aux | grep '[k]ubelet' | grep image-credential-provider-config
```
→ `--image-credential-provider-config=/etc/kubernetes/credential-provider-config.yaml` 보여야 정상.

---

## STEP 5 — 클러스터 검증

```bash
# bastion 경유 master 접속
ssh-add ~/.ssh/ktcloud-bastion-node-key
ssh -A -J ec2-user@<2b-bastion-ip> ec2-user@<b-master-01-private-ip>

# 클러스터 상태
kubectl get nodes        # 6개 노드 Ready (master 3 + worker 3)
kubectl get pods -A      # argocd, kube-system, aws-load-balancer-system 모두 Running

# ArgoCD root-app 자동 생성됨 (argocd-setup playbook이 fetch + apply)
kubectl -n argocd get application

# admin 비밀번호
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

ArgoCD UI / CLI 접근은 [msa-argocd-manifest README](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest) 참조.

---

## 비용 사이클 — apply / destroy 반복 (예산 제약 대응)

영구 자원 (~$1/월)은 유지하고 임시 자원만 destroy → 다음 작업 시 다시 apply.

### 임시 자원 destroy (검증 종료 시)

#### Linux/Mac (bash)
```bash
bash scripts/destroy-temp.sh
# 또는 무인:
bash scripts/destroy-temp.sh --auto-approve
```

#### Windows PowerShell
```powershell
.\scripts\destroy-temp.ps1
# 또는 무인:
.\scripts\destroy-temp.ps1 -AutoApprove
```

소요: ~5-10분. 결과: ~33개 자원 destroyed, 영구 자원 (OIDC/IAM/ECR/KMS/VPC/Subnet/SG)은 유지.

### 다음 사이클 재개

```bash
terraform apply         # 임시 자원만 재생성 (영구는 unchanged)
# 그 후 STEP 4의 ansible main.yaml 다시 실행
```

ECR 이미지는 그대로 보존 → 서비스 재빌드 불필요.

### prevent_destroy 일시 해제 (정말 필요한 경우만)

프로젝트 종료 등 영구 자원도 destroy해야 하면:
1. `oidc.tf`, `ecr.tf`의 모든 `prevent_destroy = true` → `false` (commit 권장)
2. `terraform destroy` 전체
3. S3 backend bucket 수동 삭제: `aws s3 rb s3://$BUCKET --force`

ECR 레포는 `force_delete = true`로 이미지 들어있어도 destroy 가능.

---

## IAM 정책 (AWS CLI 사용자에 부착)

terraform apply 실행자가 가져야 할 최소 권한:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2AndVPCManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:*Vpc*", "ec2:*Subnet*", "ec2:*Gateway*", "ec2:*Route*",
        "ec2:*Address*", "ec2:*Instance*", "ec2:*SecurityGroup*",
        "ec2:*NetworkInterface*", "ec2:*KeyPair*", "ec2:*Image*",
        "ec2:*Volume*", "ec2:*Tag*"
      ],
      "Resource": "*"
    },
    {"Sid": "ELBManagement", "Effect": "Allow", "Action": ["elasticloadbalancing:*"], "Resource": "*"},
    {
      "Sid": "EFSManagement", "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateFileSystem", "elasticfilesystem:CreateMountTarget",
        "elasticfilesystem:DeleteFileSystem", "elasticfilesystem:DeleteMountTarget",
        "elasticfilesystem:DescribeFileSystems", "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:ModifyFileSystem", "elasticfilesystem:DescribeMountTargetSecurityGroups"
      ],
      "Resource": "*"
    }
  ]
}
```

IAM Role 관련 (별도 attach):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "AllowReadSpecificRole", "Effect": "Allow",
     "Action": ["iam:GetRole", "iam:ListRoles", "iam:PassRole"], "Resource": "*"},
    {"Sid": "AllowInstanceProfileManagement", "Effect": "Allow",
     "Action": [
       "iam:GetInstanceProfile", "iam:CreateInstanceProfile",
       "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
       "iam:DeleteInstanceProfile"
     ], "Resource": "*"}
  ]
}
```

NLB를 클러스터에 등록하기 위한 IAM Role: [kubernetes-sigs/aws-load-balancer-controller iam_policy.json](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json)을 `ktcloud-cluster-node-role`에 부착.

---

## 키페어 (1인이 1회 생성)

```bash
bash ssh-key-gen.bash
```

`~/.ssh/ktcloud-bastion-node-key{,.pub}` 생성. 협업자는 동일 private key 안전 채널로 공유.

---

## 트러블슈팅

- **`.sh` 스크립트가 PowerShell에서 안 돌아감** → CRLF 변환. `.gitattributes`로 LF 강제됨 (재clone 권장). 또는 PowerShell native `destroy-temp.ps1` 사용. [TROUBLESHOOTING §6.3](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#63-sh-파일이-git에서-crlf로-저장--bash-실패)
- **AWS s3api JSON 따옴표 깨짐 (PowerShell)** → shorthand 사용 (위 STEP 1의 PowerShell 예제). [TROUBLESHOOTING §6.2](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#62-powershell-json-quoting-aws-s3api)
- **terraform `-flag=value` 파싱 깨짐 (PowerShell)** → 공백 분리 또는 array splatting. [TROUBLESHOOTING §6.1](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#61-powershell--flagvalue-인수-파싱-깨짐)
- **cloud-provider-aws release에 binary 없음 (404)** → Go 빌드로 우회 (STEP 3). [TROUBLESHOOTING §5.1](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#51-cloud-provider-aws-release에-binary-asset-없음)
- **kubelet ECR pull 실패 (`no basic auth credentials`)** → drop-in이 systemd에 평가 안 됨. ansible playbook이 `kubeadm-flags.env` 직접 수정 fallback 포함 (R-30). [TROUBLESHOOTING §8.1](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#81-kubelet-kubelet_extra_args-drop-in-미평가)
- **K8S_VARS_HOLDER unreachable** → `join-master.yaml`의 vars 저장용 가상 호스트. 다른 노드 task 정상이면 무시 가능. [TROUBLESHOOTING §7.5](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md#75-k8s_vars_holder-unreachable)

---

## 관련 문서

- [msa-argocd-manifest](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest) — GitOps 매니페스트 + SPEC + ADR
- [TROUBLESHOOTING.md](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/TROUBLESHOOTING.md) — 디버깅 자료
- [BACKLOG.md](https://github.com/KTCloud-CloudNative-Troica-Team/msa-argocd-manifest/blob/main/docs/BACKLOG.md) — 작업 진행 상태 (Phase 0 완료)
