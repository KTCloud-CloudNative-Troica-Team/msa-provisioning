### AWS Architecture
![AWS デプロイアーキテクチャ](images/AWS-arch.png)

### IAM 정책
- terraform을 실행하려면 이하와 같은 IAM 정책이 필요하다
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EC2AndVPCManagement",
            "Effect": "Allow",
            "Action": [
                "ec2:*Vpc*",
                "ec2:*Subnet*",
                "ec2:*Gateway*",
                "ec2:*Route*",
                "ec2:*Address*",
                "ec2:*Instance*",
                "ec2:*SecurityGroup*",
                "ec2:*NetworkInterface*",
                "ec2:*KeyPair*",
                "ec2:*Image*",
                "ec2:*Volume*",
                "ec2:*Tag*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "ELBManagement",
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "EFSManagement",
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:CreateFileSystem",
                "elasticfilesystem:CreateMountTarget",
                "elasticfilesystem:DeleteFileSystem",
                "elasticfilesystem:DeleteMountTarget",
                "elasticfilesystem:DescribeFileSystems",
                "elasticfilesystem:DescribeMountTargets",
                "elasticfilesystem:ModifyFileSystem",
                "elasticfilesystem:DescribeMountTargetSecurityGroups"
            ],
            "Resource": "*"
        }
    ]
}
```
- IAM Role관련 권한 정책
```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowReadSpecificRole",
			"Effect": "Allow",
			"Action": [
				"iam:GetRole",
				"iam:ListRoles",
				"iam:PassRole"
			],
			"Resource": "*"
		},
		{
			"Sid": "AllowInstanceProfileManagement",
			"Effect": "Allow",
			"Action": [
				"iam:GetInstanceProfile",
				"iam:CreateInstanceProfile",
				"iam:AddRoleToInstanceProfile",
				"iam:RemoveRoleFromInstanceProfile",
				"iam:DeleteInstanceProfile"
			],
			"Resource": "*"
		}
	]
}
```

### aws cli
- terraform에서는 aws-cli aws confiture을 통해서 확인정보를 읽어들임
```terminal
➜  ktcloud-sptingboot-msa-market-service git:(master) brew install aws-cli
```
- CLI전용의IAM Secret Key와ap-northeast-2리젼을 입력한다
```terminal
➜  ktcloud-sptingboot-msa-market-service git:(master) aws configure
```

### 키페어
- 키페어를 위한 쉘을 가동한다
```terminal
➜  provisioning git:(master) bash ssh-key-gen.bash
```

### NLB을 클러스터에 등록하기 위한 IAM 롤
- EKS가 아니라、EC2에서 구축한 클러스터는 NLB를 등록하기 위해 노드에 이하의 IAM정책이 필요하다
https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json
- 「ktcloud-cluster-node-role」의IAM Role에 아까 IAM정책을 붙여서 준비하자

### Terrafrom
```terminal
➜  terraform git:(master) terraform plan
```
```terminal
➜  terraform git:(master) terraform apply
```

---

## Phase 0 — AWS OIDC + ECR + VPC Endpoint (Troica polyrepo CI/CD 사전조건)

본 PR(`phase-0/aws-ecr-oidc`)이 추가하는 파일:

- `terraform/variables.tf` — `region`, `github_org`, `msa_services` 변수 + `aws_caller_identity` data source
- `terraform/oidc.tf` — GitHub Actions OIDC IdP + `troica-gha-ecr-push` IAM Role (KTCloud-CloudNative-Troica-Team Org의 `msa-*` 레포 main 브랜치만 assume 허용)
- `terraform/ecr.tf` — KMS key + 6개 ECR 레포 (`msa/{user,auth,product,inventory,order,api-gateway}-service`) + lifecycle (최근 30 이미지 유지)
- `terraform/vpc-endpoint.tf` — Security group + ECR Interface endpoint × 2 + S3 Gateway endpoint

비용 추정 (월): KMS $1 + ECR Interface endpoint × 2 ≈ $14 + ECR/KMS 사용 트래픽 = **약 $15~25/월** (사용량에 따라).

### apply 절차

```bash
cd terraform
terraform init
terraform plan          # 변경 사항 검토 — 신규 자원 ~13개
terraform apply         # AWS 자원 생성 (사용자 직접 컨펌)

# apply 후 output 값 확인
terraform output gha_ecr_push_role_arn     # ci.yml의 role-to-assume과 일치 확인
terraform output ecr_registry_url           # 매니페스트 values 의 image.repository ACCOUNT_ID 부분
```

### GitHub Org Secrets / Variables 등록

apply 성공 후 GitHub Organization Settings → Secrets and variables → Actions:

| 종류 | 이름 | 값 |
|------|------|----|
| Secret | `AWS_ACCOUNT_ID` | `terraform output gha_ecr_push_role_arn` 의 12자리 account_id |
| Secret | `MANIFEST_PAT` | fine-grained PAT (`msa-argocd-manifest` contents:write + pull-requests:write) |
| **Variable** | `AWS_DEPLOYMENTS_ENABLED` | `true` (BACKLOG R-19 활성화 — 6개 서비스 CI 일괄 활성) |

---

## Phase 0 — S3 backend + 영구/임시 자원 분리 (비용 사이클)

**왜 필요한가**: 1인당 예산 66,666원 제약 + 3인 협업. `terraform apply → 검증 → destroy` 사이클 반복으로 비용 최소화. 그러나 OIDC role ARN / ECR URL은 GitHub Org Secrets에 등록되므로 사이클마다 변경되면 안 됨.

### 자원 분류

| 분류 | 자원 | 보호 방식 | 월 비용 |
|------|------|-----------|---------|
| **영구** | OIDC Provider, IAM Role, IAM Role Policy | `lifecycle { prevent_destroy = true }` | ~$0 |
| **영구** | ECR KMS key + alias | `prevent_destroy = true` | ~$1 |
| **영구** | ECR 레포 × 6 + lifecycle policy | `prevent_destroy = true` + `force_delete = true` | ~$0 (이미지 적음) |
| **영구** | VPC, Subnet, RT, IGW, SG, Key Pair | (변경 없음, 비용 0) | $0 |
| **임시** | EC2 × 7, EBS × 3, EFS, NAT × 2, NLB, EIP × 4 | `scripts/destroy-temp.sh -target` | ~$300 |
| **임시** | VPC Endpoint Interface × 2 + S3 Gateway | `scripts/destroy-temp.sh -target` | ~$14 |
| **수동** | S3 backend bucket | Terraform 외부 1회 생성 (닭과 달걀 회피) | <$0.5 |

**ARN/URL 안정성**: 영구 자원은 모두 **name-based**. destroy → apply 후에도 ARN/URL 동일 → GitHub Secrets 영구 유효.

### S3 backend 부트스트랩 (1인이 1회 수행)

`terraform/backend.tf`에서 `<SUFFIX>` placeholder를 실제 값으로 치환. (예: `troica` 또는 account_id 끝 6자리. 글로벌 유니크하면 됨.)

```bash
# 1) S3 bucket 1회 수동 생성 — terraform 외부 (닭과 달걀 회피)
SUFFIX=<your-suffix>    # 예: SUFFIX=troica-2026
BUCKET="troica-tfstate-${SUFFIX}"
REGION=ap-northeast-2

aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# 2) Versioning (state 실수 복구용 — 강력 권장)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# 3) 서버 측 암호화 (SSE-S3)
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# 4) Public Access Block
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicAccess=true"

# 5) terraform/backend.tf의 <SUFFIX>를 위 SUFFIX 값으로 치환 (커밋)
#    (편집기로 직접 또는 sed -i "s|troica-tfstate-<SUFFIX>|$BUCKET|" terraform/backend.tf)
```

### 첫 init + migrate (1인 1회)

이미 기존에 로컬 `.tfstate`로 apply한 적이 있다면 migrate:

```bash
cd terraform
terraform init -migrate-state
# "Do you want to copy existing state to the new backend?" → yes
```

처음부터 S3로 가는 경우:

```bash
cd terraform
terraform init
```

### 협업자 (2~3인)

backend.tf가 커밋되어 있으므로 각자 로컬에서:

```bash
git pull
cd terraform
terraform init
# S3에서 state 자동 다운로드. apply/plan 시 native lockfile로 동시 작업 보호.
```

`use_lockfile = true` (Terraform 1.10+)가 켜져 있어 DynamoDB 별도 운영 불필요.

### 비용 사이클 워크플로우

```bash
# (1) 검증 시작 — 영구 + 임시 자원 모두 apply
cd terraform
terraform apply

# (2) 검증 작업 (Ansible로 클러스터 구축, ArgoCD 동기화, 서비스 배포 확인 등)

# (3) 검증 종료 — 임시 자원만 destroy
bash scripts/destroy-temp.sh
# 또는: bash scripts/destroy-temp.sh --auto-approve

# (4) 다음날 재개 — apply 한 번이면 임시 자원만 재생성 (영구는 unchanged)
terraform apply
```

이 사이클에서 GitHub Org Secret `AWS_ACCOUNT_ID`와 ECR 이미지는 그대로 유지됨. CI workflow는 영향 없음.

### prevent_destroy 일시 해제 (정말 필요한 경우만)

프로젝트 종료 등으로 영구 자원도 destroy해야 한다면:

1. `oidc.tf`, `ecr.tf`의 모든 `prevent_destroy = true`를 `false`로 변경 (commit 권장)
2. `terraform destroy` 전체 (또는 -target 지정)
3. 끝난 후 S3 bucket도 수동 삭제: `aws s3 rb s3://$BUCKET --force`

ECR 레포는 `force_delete = true` 덕분에 안에 이미지가 있어도 destroy 가능.

---

### Ansible — kubelet ECR credential provider (`phase-0/kubelet-ecr-credential-provider`)

PR 1, PR 3 머지 후 main에 rebase + 머지.

추가 파일:
- `terraform/iam.tf` — node role에 `AmazonEC2ContainerRegistryReadOnly` 부여
- `terraform/ansible.tf` + `terraform/inventory.tftpl` — `aws_account_id`, `aws_region`을 ansible inventory에 주입
- `ansible/ecr-credential-provider-setup.yaml` — 신규 playbook
- `ansible/configuration/credential-provider-config.yaml.j2` — kubelet 설정 템플릿
- `ansible/main.yaml` — argocd-setup 이후 import 추가

Playbook 동작:
1. `ecr-credential-provider` 바이너리 다운로드 (`v1.30.5`, cloud-provider-aws 릴리스)
2. `/etc/kubernetes/credential-provider-config.yaml` 배포
3. kubelet systemd drop-in 추가 (`--image-credential-provider-config` + `--image-credential-provider-bin-dir`)
4. systemd daemon-reload + kubelet 재시작

```bash
# PR 1 머지 + terraform apply 후
terraform apply         # iam attach 반영
ansible-playbook -i ../ansible/inventory.ini ../ansible/main.yaml
# 또는 ecr playbook만 단독:
ansible-playbook -i ../ansible/inventory.ini ../ansible/ecr-credential-provider-setup.yaml
```

**주의**: kubelet 재시작은 노드 단위로 일시적 영향. 운영 클러스터라면 `serial: 1`로 rolling 적용 권장.
- Ansible의Playbook을 기동하기위한 리모트 호스트의 Fingerprint를 로컬 머신에 등록할 필요가 있다. 양쪽의 bastion에 ssh접속해서「yes」를 입력하자
```terraform
output "ap-northeast-2a-bastion-node-connect-command" {
  value = "ssh ec2-user@${aws_instance.ap-northeast-2a-bastion-node.public_ip} -i ~/.ssh/ktcloud-bastion-node-key"
}

output "ap-northeast-2b-bastion-node-connect-command" {
  value = "ssh ec2-user@${aws_instance.ap-northeast-2b-bastion-node.public_ip} -i ~/.ssh/ktcloud-bastion-node-key"
}
```

### Ansible
- inventory.ini가terraform의.tftpl에서 작성되어
- ping이 도달하는지 확인하다.
```terminal
➜  ansible git:(master) ansible all -m ping -i inventory.ini
```
- K8S의 클러스터 셋업하는 Playbook을 기동한다.
```terminal
➜  ansible git:(master) ansible-playbook -i inventory.ini main.yaml
```

### K8S Cluster
- 키페어는 같기 때문에 ssh에이전트를 등록한다
```terminal
➜  ktcloud-sptingboot-msa-market-service git:(master) ✗ ssh-add ~/.ssh/ktcloud-bastion-node-key
Identity added: /Users/kanei/.ssh/ktcloud-bastion-node-key (kanei@gim-yeonghoui-MacBookPro.local)
```
- 이하의output의 결과를 한번에 확인가능하다
```terraform
output "main-master-node-connect-command" {
  value = "ssh -A -J ec2-user@${aws_instance.ap-northeast-2b-bastion-node.public_ip} ec2-user@${aws_instance.ap-northeast-2b-master-node-01.private_ip}"
}
```
- 실제로 접속해서 확인하면
```terminal
[ec2-user@ip-10-0-4-212 ~]$ kubectl get nodes
NAME                                            STATUS   ROLES           AGE   VERSION
ip-10-0-2-149.ap-northeast-2.compute.internal   Ready    <none>          39m   v1.30.14
ip-10-0-2-63.ap-northeast-2.compute.internal    Ready    control-plane   40m   v1.30.14
ip-10-0-2-81.ap-northeast-2.compute.internal    Ready    control-plane   40m   v1.30.14
ip-10-0-4-196.ap-northeast-2.compute.internal   Ready    <none>          39m   v1.30.14
ip-10-0-4-212.ap-northeast-2.compute.internal   Ready    control-plane   40m   v1.30.14
ip-10-0-4-6.ap-northeast-2.compute.internal     Ready    <none>          39m   v1.30.14
```
- alb을 사용하기위한 로드밸런서도 기동중인 것을 확인할 수 있다.
```terminal
[ec2-user@ip-10-0-4-126 ~]$ kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
NAME                                            READY   STATUS    RESTARTS   AGE
aws-load-balancer-controller-5cdc56445f-9xn6t   1/1     Running   0          2m15s
aws-load-balancer-controller-5cdc56445f-gmrcr   1/1     Running   0          2m15s
```
- argocd cli를 설치
```terminal
sudo curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

sudo chmod +x /usr/local/bin/argocd

argocd version --client
```
- argocd login
```terminal
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

argocd login <b-master-01-ip>:30080 --username admin --insecure
```
- argocd command, Traefik은 Degraded에서 Healthy 까지 5분 이상 걸린다
```terminal
argocd app list

argocd app get argocd/root-app

argocd app sync root-app --prune
```