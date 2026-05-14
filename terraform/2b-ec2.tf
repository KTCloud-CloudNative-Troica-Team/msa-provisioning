resource "aws_instance" "ap-northeast-2b-master-node-01" {
  ami                  = "ami-087e08db3e40f7429"
  instance_type        = "t3.medium"
  subnet_id            = aws_subnet.private-ap-northeast-2b.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname b-master-01
              EOF
}

resource "aws_instance" "ap-northeast-2b-worker-node-01" {
  ami = "ami-087e08db3e40f7429"
  # Phase 5 평가 매니페스트 — worker 사양 상향 사유는 2a-ec2.tf 참조.
  instance_type        = "t3.large"
  subnet_id            = aws_subnet.private-ap-northeast-2b.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false
}

resource "aws_ebs_volume" "ap-northeast-2b-worker-01-ebs" {
  availability_zone = "ap-northeast-2b"
  size              = 20
}

resource "aws_volume_attachment" "ap-northeast-2b-worker-01-ebs-att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ap-northeast-2b-worker-01-ebs.id
  instance_id = aws_instance.ap-northeast-2b-worker-node-01.id
}

resource "aws_instance" "ap-northeast-2b-worker-node-02" {
  ami = "ami-087e08db3e40f7429"
  # Phase 5 평가 매니페스트 — worker 사양 상향 사유는 2a-ec2.tf 참조.
  instance_type        = "t3.large"
  subnet_id            = aws_subnet.private-ap-northeast-2b.id
  security_groups      = [aws_security_group.cluster-node-sg.id]
  key_name             = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check    = false
}

resource "aws_ebs_volume" "ap-northeast-2b-worker-02-ebs" {
  availability_zone = "ap-northeast-2b"
  size              = 20
}

resource "aws_volume_attachment" "ap-northeast-2b-worker-02-ebs-att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ap-northeast-2b-worker-02-ebs.id
  instance_id = aws_instance.ap-northeast-2b-worker-node-02.id
}

resource "aws_instance" "ap-northeast-2b-bastion-node" {
  ami                         = "ami-087e08db3e40f7429"
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.public-ap-northeast-2b.id
  security_groups             = [aws_security_group.bastion-node-sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bastion-node-key.key_name
}
