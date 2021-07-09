#Gets the credentials for AWS from .tfvars file
variable "key" {
  type = string
}

variable "password" {
  type = string
}

variable "key_name" {
  type = string
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
  access_key = var.key
  secret_key = var.password
}

# Create a VPC
resource "aws_vpc" "test" {
  cidr_block       = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "TestVPC"
  }
}

resource "aws_internet_gateway" "test" {
  vpc_id = aws_vpc.test.id

  tags = {
    Name = "test"
  }
}

# Creates the Security Group
resource "aws_security_group" "test" {
  name        = "Test"
  description = "Test"
  vpc_id      = aws_vpc.test.id

  ingress {
    description = "TLS from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.test.cidr_block,"0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.test.cidr_block,"0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Creating 2 Subnets for ALB
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "test_subnet1" {
  vpc_id     = aws_vpc.test.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = "true"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "TestSubnet1"
  }
}

resource "aws_subnet" "test_subnet2" {
  vpc_id     = aws_vpc.test.id
  cidr_block = "10.0.2.0/24"
  map_public_ip_on_launch = "true"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "TestSubnet2"
  }
}

# Creates Public Route Table
resource "aws_route_table" "test" {
  vpc_id = aws_vpc.test.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.test.id
  }
}

resource "aws_route_table_association" "test-rta" {
  subnet_id      = aws_subnet.test_subnet1.id
  route_table_id = aws_route_table.test.id
}

# Builds an ALB 
resource "aws_lb" "test" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.test.id]
  
  subnet_mapping {
    subnet_id            = aws_subnet.test_subnet1.id
  }

  subnet_mapping {
    subnet_id            = aws_subnet.test_subnet2.id
  }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.test.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"
    forward {
        target_group {
          arn    = aws_lb_target_group.test.arn
          weight = 50
        }

        target_group {
          arn    = aws_lb_target_group.test2.arn
          weight = 50
        }
      }
  }
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_iam" {
  name = "lambda_iam"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# Lambda Function
resource "aws_lambda_function" "time_lambda" {
  filename      = "GetTime.zip"
  function_name = "lambda_get_time"
  role          = aws_iam_role.lambda_iam.arn
  handler       = "exports.test"
  runtime       = "python3.8"
}

# Adds Lambda to ALB
resource "aws_lambda_permission" "with_lb" {
  statement_id  = "AllowExecutionFromlb"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.time_lambda.arn
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.test.arn
}

resource "aws_lb_target_group" "test" {
  name        = "test"
  target_type = "lambda"
}

resource "aws_lb_target_group_attachment" "test" {
  target_group_arn = aws_lb_target_group.test.arn
  target_id        = aws_lambda_function.time_lambda.arn
  depends_on       = [aws_lambda_permission.with_lb]
}

# Creates an EC2 Server
resource "aws_network_interface" "test" {
  subnet_id   = aws_subnet.test_subnet1.id
  security_groups    = [aws_security_group.test.id]

  tags = {
    Name = "test_network_interface"
  }
}

resource "aws_instance" "TestNginxServer" {
  ami                 = "ami-042e8287309f5df03"
  instance_type       = "t2.micro"
  depends_on          = [aws_internet_gateway.test]
  key_name            = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.test.id
    device_index         = 0
  }

  tags = {
    Name = "MyTestServer"
  }
}

# Adds EC2 to ALB
resource "aws_lb_target_group" "test2" {
  name     = "test2"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.test.id
}

resource "aws_lb_target_group_attachment" "test2" {
  target_group_arn = aws_lb_target_group.test2.arn
  target_id        = aws_instance.TestNginxServer.id
  port             = 80
}