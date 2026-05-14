data "aws_iam_role" "ktcloud-cluster-node-role" {
  name = "ktcloud-cluster-node-role"
}

resource "aws_iam_instance_profile" "ktcloud-cluster-node-profile" {
  name = "ktcloud-node-profile"
  role = data.aws_iam_role.ktcloud-cluster-node-role.name
}

# Phase 0 — kubelet의 ecr-credential-provider가 ECR private 레포에서 image pull 받기 위해
# 노드 role에 ECR ReadOnly 부여. SPEC §11.4. AWS managed policy.
resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = data.aws_iam_role.ktcloud-cluster-node-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Phase 5 R-25/R-33 — ExternalSecrets Operator(ESO)가 cluster 위에서 AWS Secrets
# Manager를 호출할 때 사용. ESO operator pod가 호출하는 AWS SDK는 default
# credential provider chain으로 IMDS → EC2 node IAM role을 자동 선택함
# (self-managed kubeadm 클러스터라 EKS IRSA / OIDC provider 부재).
#
# 매니페스트 측 짝: msa-argocd-manifest PR #85 — ClusterSecretStore의
# spec.provider.aws.auth 섹션을 제거하여 IMDS 인증 경로 활성화.
#
# 권한 범위: troica/* prefix 만. 다른 계정 또는 다른 prefix secret 은 접근 불가.
# - DescribeSecret = ESO 가 metadata 조회 단계에 호출
# - GetSecretValue = 실 시크릿 값 조회
#
# AWS managed policy(SecretsManagerReadWrite)는 *=Resource 라 과도 → 직접 정의.
resource "aws_iam_policy" "node_secretsmanager_troica" {
  name        = "ktcloud-node-secretsmanager-troica"
  description = "Allow EC2 node IAM role to read SecretsManager secrets under troica/* prefix (ESO IMDS auth path)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadTroicaSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:troica/*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_secretsmanager_troica" {
  role       = data.aws_iam_role.ktcloud-cluster-node-role.name
  policy_arn = aws_iam_policy.node_secretsmanager_troica.arn
}

# Phase 5 — AWS EBS CSI driver 가 PVC 요청 시 EBS volume create / attach / detach /
# delete / snapshot 호출 시 사용. self-managed kubeadm cluster 라 EKS 처럼 자동
# 설치되지 않으므로 platform/05-ebs-csi/ (msa-argocd-manifest) 가 helm chart 로
# 설치. EBS CSI controller pod 는 default credential provider chain 으로 IMDS →
# EC2 node IAM role 자동 사용 (ESO 와 동일 패턴, R-25).
#
# AWS managed AmazonEBSCSIDriverPolicy 가 CSI driver 가 필요한 최소 권한 정의:
#   ec2:CreateVolume, DeleteVolume, AttachVolume, DetachVolume,
#   DescribeVolumes, DescribeInstances, CreateTags, CreateSnapshot,
#   DeleteSnapshot, DescribeSnapshots 등.
#
# 매니페스트 측 짝: msa-argocd-manifest PR-B — platform/05-ebs-csi/ +
# gp3 StorageClass (default).
resource "aws_iam_role_policy_attachment" "node_ebs_csi" {
  role       = data.aws_iam_role.ktcloud-cluster-node-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
