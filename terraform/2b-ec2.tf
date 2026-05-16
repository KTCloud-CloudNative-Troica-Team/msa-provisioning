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

  # root volume size — 2a-ec2.tf 참조. ephemeral-storage 부족 해소 위해 50GB.
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
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

  # root volume size — 2a-ec2.tf 참조. ephemeral-storage 부족 해소 위해 50GB.
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
}

resource "aws_instance" "ap-northeast-2b-bastion-node" {
  ami                         = "ami-087e08db3e40f7429"
  instance_type               = "t3.nano"
  subnet_id                   = aws_subnet.public-ap-northeast-2b.id
  security_groups             = [aws_security_group.bastion-node-sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bastion-node-key.key_name
}
