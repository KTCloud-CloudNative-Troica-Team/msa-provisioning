#!/usr/bin/env bash
# destroy-temp.sh
#
# 비용 사이클(apply → 검증 → destroy)에서 **임시 자원만** destroy.
# 영구 자원(OIDC/IAM/ECR/KMS)은 prevent_destroy lifecycle로 보호되어 있어
# 본 스크립트로도, 일반 `terraform destroy`로도 destroy되지 않음.
#
# **유지되는 자원 (Apply 후 그대로):**
# - aws_iam_openid_connect_provider.github        (영구, prevent_destroy)
# - aws_iam_role.gha_ecr_push                     (영구, prevent_destroy)
# - aws_iam_role_policy.gha_ecr_push              (영구 — role에 종속)
# - aws_kms_key.ecr / aws_kms_alias.ecr           (영구, prevent_destroy)
# - aws_ecr_repository.service (× 6)              (영구, prevent_destroy + force_delete)
# - aws_ecr_lifecycle_policy.service (× 6)        (영구 — repo에 종속)
# - aws_iam_instance_profile.*                    (영구 — IAM, 비용 없음)
# - aws_key_pair.bastion-node-key                 (영구 — 비용 없음)
# - aws_vpc.kt-cloud-vpc + subnet/RT/IGW          (영구로 둘 만큼 비용 없음. 재 apply 시간 단축)
# - aws_security_group.*                          (영구 — 비용 없음)
#
# **destroy되는 자원 (월 비용 대부분):**
# - EC2 instances × 7 (master/worker/bastion)
# - EBS volumes × 3 + attachments
# - NAT Gateway × 2 + EIP × 2
# - NLB + Target Group + Listener + Attachments × 3 + NLB EIP × 2
# - VPC Endpoint Interface × 2 (ecr.api, ecr.dkr) + S3 Gateway
# - EFS File System + Mount Targets × 2 + EFS SG
#
# 비용 효과: 월 ~$320 (24/7 기준) → $0 (destroy 기간 동안).
# 검증 후 다음날 다시 `terraform apply` (영구 자원은 변경 없음, 임시만 재생성, 15~20분 소요).
#
# 사용:
#   bash scripts/destroy-temp.sh                  # 확인 후 destroy
#   bash scripts/destroy-temp.sh --auto-approve   # 무인 (CI 등)

set -euo pipefail

cd "$(dirname "$0")/../terraform"

TARGETS=(
  # Compute (EC2 + EBS + 부속)
  "-target=aws_instance.ap-northeast-2a-master-node-01"
  "-target=aws_instance.ap-northeast-2a-master-node-02"
  "-target=aws_instance.ap-northeast-2a-worker-node-01"
  "-target=aws_instance.ap-northeast-2a-bastion-node"
  "-target=aws_instance.ap-northeast-2b-master-node-01"
  "-target=aws_instance.ap-northeast-2b-worker-node-01"
  "-target=aws_instance.ap-northeast-2b-worker-node-02"
  "-target=aws_instance.ap-northeast-2b-bastion-node"
  "-target=aws_ebs_volume.ap-northeast-2a-worker-01-ebs"
  "-target=aws_ebs_volume.ap-northeast-2b-worker-01-ebs"
  "-target=aws_ebs_volume.ap-northeast-2b-worker-02-ebs"
  "-target=aws_volume_attachment.ap-northeast-2a-worker-01-ebs-att"
  "-target=aws_volume_attachment.ap-northeast-2b-worker-01-ebs-att"
  "-target=aws_volume_attachment.ap-northeast-2b-worker-02-ebs-att"

  # NAT (가장 비싼 시간당 자원 중 하나)
  "-target=aws_nat_gateway.ap-northeast-2a-nat-gw"
  "-target=aws_nat_gateway.ap-northeast-2b-nat-gw"
  "-target=aws_eip.ap-northeast-2a-nat-eip"
  "-target=aws_eip.ap-northeast-2b-nat-eip"

  # NLB + EIP + Target Group + Listener + Attachments
  "-target=aws_lb.kt-cloud-nlb"
  "-target=aws_lb_target_group.k8s-api-tg"
  "-target=aws_lb_listener.k8s-api-listener"
  "-target=aws_lb_target_group_attachment.ap-northeast-2a-master-node-01-attach"
  "-target=aws_lb_target_group_attachment.ap-northeast-2a-master-node-02-attach"
  "-target=aws_lb_target_group_attachment.ap-northeast-2b-master-node-01-attach"
  "-target=aws_eip.nlb_eip_2a"
  "-target=aws_eip.nlb_eip_2b"

  # VPC Endpoint (Interface ~$7/월 × 2)
  "-target=aws_vpc_endpoint.ecr_api"
  "-target=aws_vpc_endpoint.ecr_dkr"
  "-target=aws_vpc_endpoint.s3"

  # EFS (스토리지 사용량 비례)
  "-target=aws_efs_mount_target.private-ap-northeast-2a-mt"
  "-target=aws_efs_mount_target.private-ap-northeast-2b-mt"
  "-target=aws_efs_file_system.kt-cloud-cluster-efs"

  # ansible inventory 로컬 파일 (EC2 ip 참조 → EC2 destroy 시 함께)
  "-target=local_file.ansible_inventory"
)

AUTO_APPROVE=""
if [[ "${1:-}" == "--auto-approve" ]]; then
  AUTO_APPROVE="-auto-approve"
fi

echo "==> Plan (임시 자원만 destroy)"
terraform plan -destroy "${TARGETS[@]}"

echo ""
echo "==> Apply destroy"
terraform destroy "${TARGETS[@]}" $AUTO_APPROVE

echo ""
echo "==> 완료. 영구 자원(OIDC/IAM/ECR/KMS)은 그대로 유지됨."
echo "    다음 사이클 재개:  terraform apply"
