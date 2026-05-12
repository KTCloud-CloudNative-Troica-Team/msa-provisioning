# Terraform remote state — S3 backend with native state locking.
#
# 왜 S3 backend?
# - 3인 협업: 로컬 .tfstate를 git에 두면 sensitive output(role ARN, account_id 등) 노출 + concurrent apply 위험.
# - 비용 사이클: apply → 검증 → destroy(임시 자원만) 반복 시 state 안정적 보관 필요.
# - destroy 후에도 영구 자원(OIDC/IAM/ECR/KMS)의 lifecycle/import 정보를 잃지 않음.
#
# 왜 use_lockfile = true (DynamoDB X)?
# - Terraform 1.10+ 부터 S3 backend에 native object-lockfile lock 지원.
# - DynamoDB table을 별도 운영하지 않아도 됨 → 비용 절감 + 변경 면적 축소.
# - 닭과 달걀 문제 해소: backend 인프라(bucket 자체) 이외에 의존성 없음.
#
# Bootstrap 절차 (README의 "S3 backend 부트스트랩" 섹션 참조):
#   1) AWS Console 또는 aws-cli로 S3 bucket 1회 수동 생성 (Versioning + KMS 권장)
#   2) 본 파일의 <SUFFIX>를 실제 값으로 치환 (또는 -backend-config로 주입)
#   3) terraform init -migrate-state (로컬 → S3)
#
# bucket suffix는 글로벌 유니크 (예: account_id 일부, team identifier 등). 팀 결정 사항.

terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "troica-tfstate-troica-2026"
    key          = "phase-0/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true # Terraform 1.10+ native S3 lockfile — DynamoDB 불필요
  }
}
