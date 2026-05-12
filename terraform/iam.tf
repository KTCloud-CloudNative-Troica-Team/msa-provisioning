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
