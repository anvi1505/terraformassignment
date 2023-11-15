terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
    region = "ap-south-1"
    access_key = "*****************"
    secret_key = "*****************"
}

resource "aws_vpc" "myvpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "myvpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.myvpc.id

  tags = {
    Name = "internet_gateway"
  }
}

resource "aws_subnet" "s1" {
  vpc_id     = aws_vpc.myvpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name = "public_sn1"
  }
}

resource "aws_subnet" "s2" {
  vpc_id     = aws_vpc.myvpc.id
  cidr_block = "10.0.2.0/24"

  tags = {
    Name = "private_sn1"
  }
}

resource "aws_route_table" "pubrt" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "public_rt"
  }
}

resource "aws_route_table" "pvtrt" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

  tags = {
    Name = "private_rt"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.s1.id
  route_table_id = aws_route_table.pubrt.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.s2.id
  route_table_id = aws_route_table.pvtrt.id
}

resource "aws_security_group" "linux_sg" {
  name        = "allow_ssh"
  description = "Allow ssh inbound traffic"
  vpc_id      = aws_vpc.myvpc.id

  ingress {
    description      = "ssh from user"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["10.0.0.0/16"]
    ipv6_cidr_blocks = null
  }

  ingress {
    description      = "http from user"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = null
  }

  tags = {
    Name = "linux_SG"
  }
}

resource "aws_security_group" "elb_sg" {
  name        = "allow_http"
  description = "Allow http inbound traffic"
  vpc_id      = aws_vpc.myvpc.id

  ingress {
    description      = "http from user"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Name = "elb_SG"
  }
}

resource "aws_lb" "app_lb" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.elb_sg.id]
  subnets            = [aws_subnet.s1.id]
  enable_deletion_protection = true
  tags = {
    Name = "application_elb"
  }
}

resource "aws_lb_listener" "app_lb" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_lb.arn
  }
}

resource "aws_lb_target_group" "app_lb" {
  name     = "tf-application-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.myvpc.id
}

resource "aws_ebs_volume" "app_lb" {
  availability_zone = "ap-south-1a"
  size              = 20
}

resource "aws_launch_template" "app_lb" {
  name_prefix   = "app_lb"
  image_id      = "ami-0a6ed6689998f32a5"
  instance_type = "t2.micro"
  security_group_names = aws_security_group.linux_sg.id
  key_name = "dev"
  user_data = "${file("data.sh")}"
  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_size = 20
    }
  }
}

resource "aws_lb_target_group_attachment" "app_lb" {
  target_group_arn = aws_lb_target_group.app_lb.arn
  target_id        = aws_instance.app_lb.id
  port             = 80
}

resource "aws_autoscaling_group" "app_lb" {
  availability_zones = ["ap-south-1a","ap-south-1b"]
  desired_capacity   = 2
  max_size           = 5
  min_size           = 1

  launch_template {
    id      = aws_launch_template.app_lb.id
    version = "$Latest"
  }
}

resource "aws_autoscaling_policy" "web_policy_up" {
  name = "web_policy_up"
  scaling_adjustment = 1
  adjustment_type = "ChangeInCapacity"
  cooldown = 300
  autoscaling_group_name = aws_autoscaling_group.app_lb.name
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_up" {
  alarm_name = "web_cpu_alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "120"
  statistic = "Average"
  threshold = "70"
dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app_lb.name
  }
alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions = [ aws_autoscaling_policy.web_policy_up.arn ]
}
resource "aws_autoscaling_policy" "web_policy_down" {
  name = "web_policy_down"
  scaling_adjustment = -1
  adjustment_type = "ChangeInCapacity"
  cooldown = 300
  autoscaling_group_name = aws_autoscaling_group.app_lb.name
}
resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_down" {
  alarm_name = "web_cpu_alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "120"
  statistic = "Average"
  threshold = "30"
dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app_lb.name
  }
alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions = [ aws_autoscaling_policy.web_policy_down.arn ]
}

resource "aws_autoscaling_attachment" "app_lb" {
  autoscaling_group_name = aws_autoscaling_group.app_lb.id
  elb                    = aws_elb.app_lb.id
}





