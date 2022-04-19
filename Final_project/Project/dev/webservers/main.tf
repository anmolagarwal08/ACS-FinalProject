#----------------------------------------------------------

#  Define the provider
provider "aws" {
  region = "us-east-1"
}

# Data source for AMI id
data "aws_ami" "latest_amazon_linux" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Use remote state to retrieve the data
data "terraform_remote_state" "network" { // This is to use Outputs from Remote State
  backend = "s3"
  config = {
    bucket = "group8anmolshubham"                   // Bucket from where to GET Terraform State
    key    = "${var.env}/network/terraform.tfstate" // Object name in the bucket to GET Terraform State
    region = "us-east-1"                            // Region where bucket created
  }
}


# Data source for availability zones in us-east-1
data "aws_availability_zones" "available" {
  state = "available"
}

# Define tags locally
locals {
  default_tags = merge(module.globalvars.default_tags, { "env" = var.env })
  prefix       = module.globalvars.prefix
  name_prefix  = "${local.prefix}-${var.env}"
}

# Retrieve global variables from the Terraform module
module "globalvars" {
  source = "../../../modules/globalvars"
}


# Adding SSH key to Amazon EC2
resource "aws_key_pair" "web_key" {
  key_name   = local.name_prefix
  public_key = file("${local.name_prefix}.pub")
}


# Security Group
resource "aws_security_group" "web_sg" {
  name        = "allow_http_ssh"
  description = "Allow SSH inbound traffic"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description     = "HTTP"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags,
    {
      "Name" = "${local.name_prefix}-sg"
    }
  )
}

resource "aws_lb" "load_balancer" {
  name               = "lb-dev"
  internal           = false
  ip_address_type    = "ipv4"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = data.terraform_remote_state.network.outputs.public_subnet_ids[*]
  tags = merge(local.default_tags,
    {
      "Name" = "${local.name_prefix}-load_balancer"
    }
  )
}


resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_lb_target_group" "tg" {
  health_check {
    interval            = 15
    path                = "/"
    protocol            = "HTTP"
    timeout             = 6
    healthy_threshold   = 4
    unhealthy_threshold = 3
  }
  name        = "tg-lb-dev"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id
}
resource "aws_security_group" "lb_sg" {
  name        = "allow_http"
  description = "Allow http inbound traffic"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.default_tags,
    {
      "Name" = "${local.name_prefix}-lb-sg"
    }
  )
}


# Auto Scaling launch config
resource "aws_launch_configuration" "launch_config" {
  name            = "web-dev"
  image_id        = data.aws_ami.latest_amazon_linux.id
  instance_type   = lookup(var.instance_type, var.env)
  key_name        = aws_key_pair.web_key.key_name
  security_groups =  [aws_security_group.web_sg.id]
  user_data = templatefile("${path.module}/install_httpd.sh.tpl",
    {
      env    = upper(var.env),
      prefix = upper(local.prefix)
    }
  )
}

# Auto Scaling group
resource "aws_autoscaling_group" "asg" {
  name                 = "asg-dev"
  min_size             = 1
  max_size             = 4
  desired_capacity     = 1
  launch_configuration = aws_launch_configuration.launch_config.name
  vpc_zone_identifier  = data.terraform_remote_state.network.outputs.private_subnet_ids[*]
  lifecycle {
    ignore_changes = [desired_capacity, target_group_arns]
  }

}

# Autoscaling Attachment
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.asg.id
  lb_target_group_arn    = aws_lb_target_group.tg.arn
}

# Auto-scaling policy - scaling in
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "scale_in"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

# Cloud watch alarm to scale in if cpu < below 5%
resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]
  alarm_name          = "web_scale_in"
  comparison_operator = "LessThanOrEqualToThreshold"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  threshold           = "5"
  evaluation_periods  = "3"
  period              = "300"
  statistic           = "Average"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# Auto-scaling policy 
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale_out"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 120
}

# Cloud watch alarm to scale out if cpu > 10%
resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]
  alarm_name          = "scale_out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  threshold           = "10"
  evaluation_periods  = "3"
  period              = "120"
  statistic           = "Average"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}







######

# Webserver deployment
resource "aws_instance" "my_amazon" {
  count                       = var.instance_count
  ami                         = data.aws_ami.latest_amazon_linux.id
  instance_type               = lookup(var.instance_type, var.env)
  key_name                    = aws_key_pair.web_key.key_name
  subnet_id                   = data.terraform_remote_state.network.outputs.private_subnet_ids[count.index]
  security_groups             = [aws_security_group.web_sg.id]
  associate_public_ip_address = false
  user_data = templatefile("${path.module}/install_httpd.sh.tpl",
    {
      env    = upper(var.env),
      prefix = upper(local.prefix)
    }
  )

  root_block_device {
    encrypted = var.env == "prod" ? true : false
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags,
    {
      "Name" = "${local.name_prefix}-VM-Linux"
    }
  )
}



resource "aws_lb_target_group_attachment" "instance_attach" {
  count            = length(aws_instance.my_amazon)
  target_group_arn =aws_lb_target_group.tg.arn
  target_id        = aws_instance.my_amazon[count.index].id
  port             = 80
}

