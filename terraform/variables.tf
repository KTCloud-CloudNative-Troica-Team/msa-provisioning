variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "github_org" {
  description = "GitHub organization name (OIDC subject scoping)"
  type        = string
  default     = "KTCloud-CloudNative-Troica-Team"
}

variable "msa_services" {
  description = "ECR 레포 + IAM scoping 대상 서비스 목록 (D6 후: notification 제외)"
  type        = list(string)
  default = [
    "user-service",
    "auth-service",
    "product-service",
    "inventory-service",
    "order-service",
    "api-gateway",
  ]
}

# Account ID는 변수 대신 data source로 (Phase 0 — 어차피 같은 AWS 자격으로 apply하므로)
data "aws_caller_identity" "current" {}
