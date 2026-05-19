#!/usr/bin/env bash
# Verify that terraform-managed AWS resources are in place
# before running ansible cluster bootstrap. Output is intended
# for inclusion in the recorded demo video.
set -euo pipefail

VPC_ID="${VPC_ID:-vpc-09d75ee107f77f89e}"
REGION="${AWS_REGION:-ap-northeast-2}"

echo ">>> Verifying terraform-managed AWS resources (VPC=$VPC_ID, region=$REGION)"
echo ""

echo "[1/4] EC2 instances (expected: 3 master[t3.medium] + 3 worker[t3.large] + 2 bastion[t3.nano] = 8 running)"
aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,PrivateIpAddress,Placement.AvailabilityZone,State.Name]' \
  --output table
echo ""

echo "[2/4] Network Load Balancer (external entry point)"
aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerName,DNSName,State.Code,Scheme]" \
  --output table
echo ""

echo "[3/4] EFS file system (shared storage)"
aws efs describe-file-systems \
  --region "$REGION" \
  --query 'FileSystems[*].[FileSystemId,Name,LifeCycleState,NumberOfMountTargets]' \
  --output table
echo ""

echo "[4/4] ECR repositories (msa-* container images)"
aws ecr describe-repositories \
  --region "$REGION" \
  --query 'repositories[?starts_with(repositoryName, `msa/`)].[repositoryName,createdAt]' \
  --output table
echo ""

echo ">>> AWS resource verification done. Proceeding to ansible bootstrap."
