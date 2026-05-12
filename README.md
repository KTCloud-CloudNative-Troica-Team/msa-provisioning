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

### 후속 — Ansible (별도 PR)

kubelet이 ECR private 레포에서 image pull하려면 `image-credential-provider-config` 설정 필요. EC2 instance profile에 `AmazonEC2ContainerRegistryReadOnly` managed policy도 부여. 본 PR에는 미포함 — 클러스터 실 적용은 더 신중한 별도 PR로.
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