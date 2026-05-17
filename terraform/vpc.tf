resource "aws_vpc" "kt-cloud-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.kt-cloud-vpc.id
}

resource "aws_eip" "nlb_eip_2a" {
  domain = "vpc"
}

resource "aws_eip" "nlb_eip_2b" {
  domain = "vpc"
}

resource "aws_lb" "kt-cloud-nlb" {
  name               = "kt-cloud-nlb"
  internal           = false
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_subnet.public-ap-northeast-2a.id
    allocation_id = aws_eip.nlb_eip_2a.id
  }

  subnet_mapping {
    subnet_id     = aws_subnet.public-ap-northeast-2b.id
    allocation_id = aws_eip.nlb_eip_2b.id
  }
}

resource "aws_lb_target_group" "k8s-api-tg" {
  name     = "k8s-api-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.kt-cloud-vpc.id

  health_check {
    protocol = "TCP"
    port     = "6443"
    interval = 10
  }
}

resource "aws_lb_listener" "k8s-api-listener" {
  load_balancer_arn = aws_lb.kt-cloud-nlb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  }
}

resource "aws_lb_target_group_attachment" "ap-northeast-2a-master-node-01-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2a-master-node-01.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2a-master-node-02-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2a-master-node-02.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-master-node-01-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2b-master-node-01.id
  port             = 6443
}

# ===== Istio Ingress Gateway NLB path =====
#
# R-35 (d) Istio Gateway 의 외부 진입점. 첫 사이클까지 terraform 측에 누락 →
# cluster destroy + apply 후 NLB 가 k8s-api-tg (6443) listener 만 들고 만들어짐
# → 외부에서 platform/11-istio-cp/application.yaml 의 NodePort 30080/30443
# 으로 접근 불가 (NLB 측 listener 없음). 평가 시연 (R-41 Discovery / R-42
# Newman E2E) 의 외부 client → cluster 진입 path 차단.
#
# 설계:
#   외부 client → NLB DNS:80/443 → NLB listener → target group (TCP 30080/30443)
#   → worker 3 노드 중 하나의 NodePort 30080/30443 → kube-proxy DNAT →
#   istio-ingressgateway pod (worker B1 의 envoy) → VirtualService routing
#   → market-{dev,prod} 의 backend service pod (api-gateway 등).
#
# 외부 port = 80/443 결정 사유: client 가 표준 port 사용 (URL 깔끔 + 평가 데모
# 가독성). NLB 가 80/443 받아서 NodePort 30080/30443 으로 forward.
#
# target = worker 3 만: master 는 control-plane 전담 유지. kube-proxy 가
# cluster-wide DNAT 라 worker 어느 노드든 traffic 받으면 istio-ingressgateway
# pod (worker B1) 로 forward. master 에 외부 data-plane traffic 직접 안 보냄.
#
# NLB target type = instance (default) + source IP preservation (default true).
# = client source IP 가 그대로 instance 까지 전달됨. instance SG 가 client IP
# (0.0.0.0/0) 의 NodePort (30080/30443) 을 받아야 함. 아래 cluster_node_istio_*
# _ingress 가 그 SG rule.
#
# 다른 코드 영향:
#   - ansible argocd-setup.yaml: ArgoCD nodePort 30090/30493 양보 결정 유지 (영향 X)
#   - platform/11-istio-cp/application.yaml: NodePort 30080/30443 그대로 (영향 X)
#   - 다른 SG / instance / VPC 자원: 무영향 (NLB resource 만 추가 + SG 에 ingress 만 추가)

resource "aws_lb_target_group" "istio-http-tg" {
  name     = "istio-http-tg"
  port     = 30080
  protocol = "TCP"
  vpc_id   = aws_vpc.kt-cloud-vpc.id

  health_check {
    protocol = "TCP"
    port     = "30080"
    interval = 10
  }
}

resource "aws_lb_target_group" "istio-https-tg" {
  name     = "istio-https-tg"
  port     = 30443
  protocol = "TCP"
  vpc_id   = aws_vpc.kt-cloud-vpc.id

  health_check {
    # TLS 측 health check 는 envoy 의 plain TCP accept 로 충분 (PoC).
    # 실 production 이면 HTTPS health check + TLS cert 검증 분리.
    protocol = "TCP"
    port     = "30443"
    interval = 10
  }
}

resource "aws_lb_listener" "istio-http-listener" {
  load_balancer_arn = aws_lb.kt-cloud-nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.istio-http-tg.arn
  }
}

resource "aws_lb_listener" "istio-https-listener" {
  load_balancer_arn = aws_lb.kt-cloud-nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.istio-https-tg.arn
  }
}

# Worker 3 노드 attach — HTTP target group (port 30080)
resource "aws_lb_target_group_attachment" "ap-northeast-2a-worker-node-01-istio-http-attach" {
  target_group_arn = aws_lb_target_group.istio-http-tg.arn
  target_id        = aws_instance.ap-northeast-2a-worker-node-01.id
  port             = 30080
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-worker-node-01-istio-http-attach" {
  target_group_arn = aws_lb_target_group.istio-http-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-01.id
  port             = 30080
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-worker-node-02-istio-http-attach" {
  target_group_arn = aws_lb_target_group.istio-http-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-02.id
  port             = 30080
}

# Worker 3 노드 attach — HTTPS target group (port 30443)
resource "aws_lb_target_group_attachment" "ap-northeast-2a-worker-node-01-istio-https-attach" {
  target_group_arn = aws_lb_target_group.istio-https-tg.arn
  target_id        = aws_instance.ap-northeast-2a-worker-node-01.id
  port             = 30443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-worker-node-01-istio-https-attach" {
  target_group_arn = aws_lb_target_group.istio-https-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-01.id
  port             = 30443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-worker-node-02-istio-https-attach" {
  target_group_arn = aws_lb_target_group.istio-https-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-02.id
  port             = 30443
}

resource "aws_route_table" "kt-cloud-public-rt" {
  vpc_id = aws_vpc.kt-cloud-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }
}

resource "aws_security_group" "cluster-node-sg" {
  name   = "cluster-node-sg"
  vpc_id = aws_vpc.kt-cloud-vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion-node-sg.id]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "cluster_node_self_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.cluster-node-sg.id
  source_security_group_id = aws_security_group.cluster-node-sg.id
}

# Istio Gateway 외부 NodePort 30080/30443 — NLB 가 source IP preservation
# (instance target + default attribute) 로 client IP 그대로 전달하므로 SG 에
# 외부 client IP (0.0.0.0/0) 의 NodePort 명시 허용 필수. 없으면 NLB listener
# 추가해도 instance SG 단계에서 drop → timeout.
#
# 보안 노트: NodePort 외부 노출은 평가 시연 path 단순화 용. 평가 후 단계에
# Istio gateway 의 PeerAuthentication STRICT mTLS + AuthorizationPolicy 로
# 7계층 인증 + ratelimit. NLB SG 측 0.0.0.0/0 는 4계층 path 유지.
resource "aws_security_group_rule" "cluster_node_istio_http_ingress" {
  type              = "ingress"
  from_port         = 30080
  to_port           = 30080
  protocol          = "tcp"
  security_group_id = aws_security_group.cluster-node-sg.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "cluster_node_istio_https_ingress" {
  type              = "ingress"
  from_port         = 30443
  to_port           = 30443
  protocol          = "tcp"
  security_group_id = aws_security_group.cluster-node-sg.id
  cidr_blocks       = ["0.0.0.0/0"]
}

data "http" "my_ip" {
  url = "https://ifconfig.me/ip"
}

locals {
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

resource "aws_security_group" "bastion-node-sg" {
  name   = "bastion-node-sg"
  vpc_id = aws_vpc.kt-cloud-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
