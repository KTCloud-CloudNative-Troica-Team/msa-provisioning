# destroy-temp.ps1 — PowerShell 버전.
# Windows에서 destroy-temp.sh를 직접 못 돌리는 두 가지 이유 회피:
#   1) git autocrlf로 .sh가 CRLF 저장 → bash가 못 읽음 ($'\r' 에러)
#   2) PowerShell이 `-flag=value` 형태 인수를 깨뜨림 → array splatting으로 우회
#
# 사용:
#   cd msa-provisioning
#   .\scripts\destroy-temp.ps1
#   또는:
#   .\scripts\destroy-temp.ps1 -AutoApprove   # 무인 (확인 없이 destroy)

param(
    [switch]$AutoApprove
)

# PowerShell 5.1 default output encoding 은 시스템 코드페이지 (한국 환경 CP949) →
# 스크립트 안의 UTF-8 한글이 콘솔에 깨져 표시됨 ("?꾩떆 ?먯썝留?" 등).
# Console + 파이프 양쪽 모두 UTF-8 강제.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# native exe (terraform 등) 의 stdout 도 UTF-8 로 받기 위해 코드페이지도 변경.
$null = chcp 65001

$ErrorActionPreference = "Stop"

# 본 스크립트 위치 기준으로 terraform 디렉토리 진입
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location (Join-Path $scriptDir "..\terraform")

$targets = @(
    # EC2 인스턴스
    "-target=aws_instance.ap-northeast-2a-master-node-01",
    "-target=aws_instance.ap-northeast-2a-master-node-02",
    "-target=aws_instance.ap-northeast-2a-worker-node-01",
    "-target=aws_instance.ap-northeast-2a-bastion-node",
    "-target=aws_instance.ap-northeast-2b-master-node-01",
    "-target=aws_instance.ap-northeast-2b-worker-node-01",
    "-target=aws_instance.ap-northeast-2b-worker-node-02",
    "-target=aws_instance.ap-northeast-2b-bastion-node",
    # EBS 볼륨 + 부착
    "-target=aws_ebs_volume.ap-northeast-2a-worker-01-ebs",
    "-target=aws_ebs_volume.ap-northeast-2b-worker-01-ebs",
    "-target=aws_ebs_volume.ap-northeast-2b-worker-02-ebs",
    "-target=aws_volume_attachment.ap-northeast-2a-worker-01-ebs-att",
    "-target=aws_volume_attachment.ap-northeast-2b-worker-01-ebs-att",
    "-target=aws_volume_attachment.ap-northeast-2b-worker-02-ebs-att",
    # NAT Gateway + EIP
    "-target=aws_nat_gateway.ap-northeast-2a-nat-gw",
    "-target=aws_nat_gateway.ap-northeast-2b-nat-gw",
    "-target=aws_eip.ap-northeast-2a-nat-eip",
    "-target=aws_eip.ap-northeast-2b-nat-eip",
    # NLB + Target Group + Listener + Attachments + EIP
    "-target=aws_lb.kt-cloud-nlb",
    "-target=aws_lb_target_group.k8s-api-tg",
    "-target=aws_lb_listener.k8s-api-listener",
    "-target=aws_lb_target_group_attachment.ap-northeast-2a-master-node-01-attach",
    "-target=aws_lb_target_group_attachment.ap-northeast-2a-master-node-02-attach",
    "-target=aws_lb_target_group_attachment.ap-northeast-2b-master-node-01-attach",
    "-target=aws_eip.nlb_eip_2a",
    "-target=aws_eip.nlb_eip_2b",
    # VPC Endpoint
    "-target=aws_vpc_endpoint.ecr_api",
    "-target=aws_vpc_endpoint.ecr_dkr",
    "-target=aws_vpc_endpoint.s3",
    # EFS
    "-target=aws_efs_mount_target.private-ap-northeast-2a-mt",
    "-target=aws_efs_mount_target.private-ap-northeast-2b-mt",
    "-target=aws_efs_file_system.kt-cloud-cluster-efs",
    # ansible inventory 로컬 파일 (EC2 destroy 시 의존성)
    "-target=local_file.ansible_inventory"
)

Write-Host "==> Plan (임시 자원만 destroy)" -ForegroundColor Cyan
terraform plan -destroy @targets

Write-Host ""
Write-Host "==> Apply destroy" -ForegroundColor Yellow
if ($AutoApprove) {
    terraform destroy @targets -auto-approve
} else {
    terraform destroy @targets
}

Write-Host ""
Write-Host "==> 완료. 영구 자원(OIDC/IAM/ECR/KMS)은 유지됨." -ForegroundColor Green
Write-Host "    다음 사이클 재개:  terraform apply"

Pop-Location
