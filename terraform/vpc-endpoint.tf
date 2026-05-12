# VPC Endpoint for ECR — SPEC §11.3 / §11 일관성.
# kubelet이 private subnet에서 ECR private 레포에서 image를 pull할 수 있도록.
# 별도 Interface endpoint 없으면 NAT Gateway 경유 (트래픽 비용 + 외부 인터넷 의존).
#
# 비용 추정 (us/ap region 기준):
# - Interface endpoint × 2 (ecr.api, ecr.dkr): ~$7/월 × 2 = $14/월 (시간당 fixed + 데이터 트래픽)
# - S3 Gateway endpoint: 무료
# 총 ~$14/월 (Phase 0 비용의 거의 전부)

resource "aws_security_group" "vpc_endpoint" {
  name        = "troica-vpc-endpoint-sg"
  description = "Allow HTTPS from VPC to AWS service endpoints"
  vpc_id      = aws_vpc.kt-cloud-vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = "troica" }
}

# ECR API (인증·메타데이터)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id            = aws_vpc.kt-cloud-vpc.id
  service_name      = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type = "Interface"
  subnet_ids = [
    aws_subnet.private-ap-northeast-2a.id,
    aws_subnet.private-ap-northeast-2b.id,
  ]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true
  tags                = { Project = "troica" }
}

# ECR DKR (Docker Registry API — 이미지 layer pull)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id            = aws_vpc.kt-cloud-vpc.id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
  subnet_ids = [
    aws_subnet.private-ap-northeast-2a.id,
    aws_subnet.private-ap-northeast-2b.id,
  ]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true
  tags                = { Project = "troica" }
}

# S3 Gateway endpoint — ECR이 내부적으로 S3에 이미지 레이어를 저장.
# Interface endpoint와 달리 무료 + route table 기반.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.kt-cloud-vpc.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private-ap-northeast-2a-rt.id,
    aws_route_table.private-ap-northeast-2b-rt.id,
  ]
  tags = { Project = "troica" }
}
