# ECR repositories — SPEC §11.2.
# 6개 서비스(D6 후: notification 폐기 반영) 각각 별도 레포.
# - IMMUTABLE: 같은 tag 재push 금지 (CI에서 main-<sha7> 사용 → 충돌 시 새 commit으로 재시도)
# - 이미지 레이어 자동 스캔 (push 시 ECR이 기본 스캔 + Trivy는 CI에서 추가 검증)
# - KMS 암호화 (rest at rest 표준)

resource "aws_kms_key" "ecr" {
  description             = "Troica ECR encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags = {
    Project = "troica"
  }

  # 영구 자원 — KMS key는 ECR 레포 암호화에 묶여있어서,
  # KMS key가 destroy되면 ECR 안의 이미지가 복호화 불가 (deletion_window 동안만 복구 가능).
  # 또한 ECR 레포가 동일 key를 참조하므로 key 변경 시 ECR 재생성 cascade 발생.
  # 비용 ~$1/월 (사용량 매우 적음).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/troica-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "service" {
  for_each             = toset(var.msa_services)
  name                 = "msa/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  # force_delete = true:
  # prevent_destroy를 일시 false로 변경한 후 의도적으로 destroy하는 경우,
  # 레포 안에 이미지가 들어있어도 강제 삭제 가능하도록.
  # 평소에는 prevent_destroy가 우선 작동하므로 안전.
  force_delete = true

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "troica"
    Service = each.value
  }

  # 영구 자원 — ECR 레포 URL은 매니페스트 values의 image.repository에 hardcoded.
  # name-based (account_id.dkr.ecr.region.amazonaws.com/msa/<service>) 이므로
  # destroy → apply 후 동일 URL 복원되지만, 이미지 자체가 모두 사라지므로
  # 다음 apply 후 6개 서비스 모두 재push 필요 (CI workflow_dispatch로 가능하지만 번거로움).
  # → prevent_destroy로 봉인.
  # 비용 ~$0.1/GB/월 (이미지 30개 보존 lifecycle 적용됨, 실제 매우 적음).
  lifecycle {
    prevent_destroy = true
  }
}

# 보존 정책 — 각 레포 최근 30 이미지 유지, 그 이상은 자동 만료.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_registry_url" {
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  description = "매니페스트 레포 applications/values/*/values.yaml의 image.repository ACCOUNT_ID 부분에 적용"
}

output "ecr_repository_uris" {
  value       = { for k, r in aws_ecr_repository.service : k => r.repository_url }
  description = "각 서비스별 ECR 레포 URI"
}
