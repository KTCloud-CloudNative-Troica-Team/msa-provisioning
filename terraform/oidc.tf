# GitHub Actions OIDC Provider + IAM Role
# SPEC §11.1 — long-lived AWS key 미사용.
# CI 워크플로우(.github/workflows/ci.yml)의 aws-actions/configure-aws-credentials@v4가
# 본 role을 STS AssumeRoleWithWebIdentity로 가져가서 ECR push 권한 획득.

# GitHub의 OIDC IdP 등록.
# thumbprint는 token.actions.githubusercontent.com 인증서 (변경 시 갱신 필요 — drift 모니터링).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  # 영구 자원 — 비용 사이클(apply/destroy 반복)에서도 절대 destroy되지 않도록.
  # 본 자원의 ARN은 IAM Role의 Federated Principal에 hardcoded되어 있으므로
  # 재생성 시 ARN이 바뀌면 GitHub Org Secret AWS_ACCOUNT_ID + ci.yml role 신뢰관계가 모두 깨짐.
  # destroy가 정말 필요한 경우 (e.g. 프로젝트 종료) prevent_destroy = false로 일시 변경 후 destroy.
  lifecycle {
    prevent_destroy = true
  }
}

# CI가 assume할 IAM role. 이름은 SPEC §11.1과 ci.yml의 hardcoded ARN과 일치해야 함:
#   arn:aws:iam::${AWS_ACCOUNT_ID}:role/troica-gha-ecr-push
resource "aws_iam_role" "gha_ecr_push" {
  name = "troica-gha-ecr-push"

  # 영구 자원 — IAM Role 이름은 name-based ARN이라 destroy → apply 후에도 ARN 동일.
  # 그러나 destroy 시 GitHub Org Secret AWS_ACCOUNT_ID와의 연관이 일시적으로 끊기고,
  # 그 사이 CI가 모두 red가 되므로 prevent_destroy로 봉인.
  # 비용은 IAM Role 자체 무료 (정책 사용량 무관).
  lifecycle {
    prevent_destroy = true
  }

  # Trust policy — KTCloud-CloudNative-Troica-Team Org의 msa-* 레포의 main 브랜치만 허용.
  # PR 빌드는 OIDC 발급 자체는 가능하지만 ci.yml의 push-gated step만 본 role을 사용.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/msa-*:ref:refs/heads/main"
        }
      }
    }]
  })
}

# ECR push 권한. msa/* 레포로만 scope.
resource "aws_iam_role_policy" "gha_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.gha_ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/msa/*"
      },
    ]
  })
}

output "gha_ecr_push_role_arn" {
  value       = aws_iam_role.gha_ecr_push.arn
  description = "GitHub Org Secret AWS_ACCOUNT_ID에 등록할 값 (account_id 부분)을 확인하기 위한 ARN. ci.yml의 role-to-assume과 일치 여부 검증용"
}
