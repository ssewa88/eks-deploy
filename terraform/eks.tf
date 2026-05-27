# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "eks-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.31"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name = "eks-cluster"
  }
}

# Security Group for EKS Worker Nodes
resource "aws_security_group" "eks_worker" {
  name        = "eks-worker-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  # Allow all traffic from the EKS cluster
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  # Allow node-to-node communication
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Allow traffic from ALB
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-worker-sg"
  }
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "eks-alb-sg"
  description = "Security group for EKS ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-alb-sg"
  }
}

# Launch Template for EKS nodes
resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "eks-node-template-"
  image_id      = "ami-03bc317f1e0c7d6c1" # Amazon EKS-optimized AMI for 1.31 in us-east-1
  instance_type = "t3.small"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
set -ex

# Get instance ID and use it to determine node number
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
NODE_NUMBER=$(echo $INSTANCE_ID | cut -d'-' -f2 | cut -c1)

# Bootstrap the node with proper naming
/etc/eks/bootstrap.sh eks-cluster \
  --kubelet-extra-args '--node-labels=eks.amazonaws.com/nodegroup=eks-node-group,eks.amazonaws.com/nodegroup-image=ami-03bc317f1e0c7d6c1' \
  --apiserver-endpoint '${aws_eks_cluster.main.endpoint}' \
  --b64-cluster-ca '${aws_eks_cluster.main.certificate_authority[0].data}'

# Set the node name
hostnamectl set-hostname "Worker Node $NODE_NUMBER"
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Worker Node 1"
    }
  }

  vpc_security_group_ids = [aws_security_group.eks_worker.id]

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_iam_instance_profile.eks_node_group,
    aws_security_group.eks_worker
  ]
}

# IAM Instance Profile for EKS Node Group
resource "aws_iam_instance_profile" "eks_node_group" {
  name = "eks-node-group-profile"
  role = aws_iam_role.eks_node_group.name
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 1
    max_size     = 4
    min_size     = 1
  }

  # Use CUSTOM AMI type since we're specifying an AMI in the launch template
  ami_type      = "CUSTOM"
  capacity_type = "ON_DEMAND"

  # Use launch template
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  # Update strategy
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only
  ]

  tags = {
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Application Load Balancer
resource "aws_lb" "eks" {
  name               = "eks-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "eks-alb"
  }
}

# Target Group for ALB
resource "aws_lb_target_group" "eks" {
  name     = "eks-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
  }

  tags = {
    Name = "eks-tg"
  }
}

# ALB Listener
resource "aws_lb_listener" "eks" {
  load_balancer_arn = aws_lb.eks.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks.arn
  }
} 