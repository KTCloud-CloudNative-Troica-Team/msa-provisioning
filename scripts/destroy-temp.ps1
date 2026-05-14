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
Write-Host "==> Cleanup orphan Kubernetes-created EBS volumes" -ForegroundColor Cyan
# PVCs that were dynamically provisioned by the EBS CSI driver create EBS
# volumes with the tag "kubernetes.io/created-for/pvc/name". When the cluster
# is destroyed before PVCs are cleaned up, those EBS volumes become orphans
# (CSI controller is gone, so they are never released). This step deletes
# them explicitly. Cost-critical -- a missed orphan EBS keeps charging.
$region = "ap-northeast-2"
$orphans = aws ec2 describe-volumes `
    --filters Name=status,Values=available Name=tag-key,Values=kubernetes.io/created-for/pvc/name `
    --query 'Volumes[].VolumeId' `
    --output text `
    --region $region
if ($orphans -and $orphans.Trim()) {
    $orphans -split '\s+' | Where-Object { $_ } | ForEach-Object {
        Write-Host "    Deleting EBS $_"
        aws ec2 delete-volume --volume-id $_ --region $region | Out-Null
    }
} else {
    Write-Host "    No orphan EBS volumes found."
}

Write-Host ""
Write-Host "==> Verify no billable resources remain" -ForegroundColor Cyan
# Quick sanity check -- if any of these are non-empty, investigate manually.
$checks = @(
    @{ name = "EBS volumes (available)"; cmd = "aws ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)' --output text --region $region" },
    @{ name = "Snapshots"; cmd = "aws ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)' --output text --region $region" },
    @{ name = "Load Balancers v2"; cmd = "aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text --region $region" },
    @{ name = "Unassociated EIPs"; cmd = "aws ec2 describe-addresses --query 'length(Addresses[?AssociationId==null])' --output text --region $region" },
    @{ name = "NAT Gateways"; cmd = "aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text --region $region" },
    @{ name = "EFS file systems"; cmd = "aws efs describe-file-systems --query 'length(FileSystems)' --output text --region $region" }
)
foreach ($c in $checks) {
    $count = Invoke-Expression $c.cmd
    $color = if ($count -eq "0") { "Green" } else { "Red" }
    Write-Host ("    {0}: {1}" -f $c.name, $count) -ForegroundColor $color
}

Write-Host ""
Write-Host "==> Done. Permanent resources (OIDC/IAM/ECR/KMS) preserved." -ForegroundColor Green
Write-Host "    Resume next cycle:  terraform apply"

Pop-Location
