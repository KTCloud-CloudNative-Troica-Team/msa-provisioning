# destroy-temp.ps1 — PowerShell version.
# Reason for two workarounds when running destroy on Windows:
#   1) git autocrlf saves .sh with CRLF -> bash can't read ($'\r' error)
#   2) PowerShell breaks `-flag=value` style args -> use array splatting
#
# Note: Korean characters in Write-Host previously got mangled on PowerShell 5.1
# under CP949 locale because the parser decodes the script file as ANSI before
# applying any chcp / OutputEncoding setting. Switched all user-facing strings
# to English to avoid the issue entirely.
#
# Usage:
#   cd msa-provisioning
#   .\scripts\destroy-temp.ps1
#   or:
#   .\scripts\destroy-temp.ps1 -AutoApprove   # unattended (no prompt)

param(
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"

# Enter the terraform directory relative to this script's location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location (Join-Path $scriptDir "..\terraform")

$targets = @(
    # EC2 instances
    "-target=aws_instance.ap-northeast-2a-master-node-01",
    "-target=aws_instance.ap-northeast-2a-master-node-02",
    "-target=aws_instance.ap-northeast-2a-worker-node-01",
    "-target=aws_instance.ap-northeast-2a-bastion-node",
    "-target=aws_instance.ap-northeast-2b-master-node-01",
    "-target=aws_instance.ap-northeast-2b-worker-node-01",
    "-target=aws_instance.ap-northeast-2b-worker-node-02",
    "-target=aws_instance.ap-northeast-2b-bastion-node",
    # EBS volumes + attachments
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
    # ansible inventory local file (EC2 destroy dependency)
    "-target=local_file.ansible_inventory"
)

Write-Host "==> Plan (destroy temporary resources only)" -ForegroundColor Cyan
terraform plan -destroy @targets

Write-Host ""
Write-Host "==> Apply destroy" -ForegroundColor Yellow
if ($AutoApprove) {
    terraform destroy @targets -auto-approve
} else {
    terraform destroy @targets
}

Write-Host ""
Write-Host "==> Done. Permanent resources (OIDC/IAM/ECR/KMS) preserved." -ForegroundColor Green
Write-Host "    Resume next cycle:  terraform apply"

Pop-Location
