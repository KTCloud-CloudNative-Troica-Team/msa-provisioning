resource "aws_instance" "ap-northeast-2a-master-node-01" {
  ami                  = "ami-087e08db3e40f7429"
  instance_type        = "t3.medium"
  subnet_id            = aws_subnet.private-ap-northeast-2a.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname a-master-01
              EOF
}

resource "aws_instance" "ap-northeast-2a-master-node-02" {
  ami                  = "ami-087e08db3e40f7429"
  instance_type        = "t3.medium"
  subnet_id            = aws_subnet.private-ap-northeast-2a.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname a-master-02
              EOF
}

resource "aws_instance" "ap-northeast-2a-worker-node-01" {
  ami = "ami-087e08db3e40f7429"
  # Phase 5 platform 매니페스트 (Prometheus / Kafka / Postgres / Istio CP /
  # AlertManager / Loki / Tempo + 6 polyrepo × 2 환경) 메모리 합산이 4 GB 초과 →
  # t3.medium (4 GB) 에서는 schedule 실패 / OOM 위험. worker 만 t3.large (8 GB)
  # 로 상향. master 는 control plane 만 띄우므로 t3.medium 유지.
  instance_type        = "t3.large"
  subnet_id            = aws_subnet.private-ap-northeast-2a.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false
}

resource "aws_ebs_volume" "ap-northeast-2a-worker-01-ebs" {
  availability_zone = "ap-northeast-2a"
  size              = 20
}

resource "aws_volume_attachment" "ap-northeast-2a-worker-01-ebs-att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ap-northeast-2a-worker-01-ebs.id
  instance_id = aws_instance.ap-northeast-2a-worker-node-01.id
}

resource "aws_instance" "ap-northeast-2a-bastion-node" {
  ami                         = "ami-087e08db3e40f7429"
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.public-ap-northeast-2a.id
  security_groups             = [aws_security_group.bastion-node-sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bastion-node-key.key_name
}
