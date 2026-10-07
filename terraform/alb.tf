resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "blue" {
  name     = "${var.project_name}-blue-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # SecurityConfig requires auth on everything except /register and /login,
  # so /login is the only route that reliably returns 200 unauthenticated.
  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = {
    Name  = "${var.project_name}-blue-tg"
    Color = "blue"
  }
}

resource "aws_lb_target_group" "green" {
  name     = "${var.project_name}-green-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = {
    Name  = "${var.project_name}-green-tg"
    Color = "green"
  }
}

resource "aws_lb_target_group_attachment" "blue" {
  target_group_arn = aws_lb_target_group.blue.arn
  target_id        = aws_instance.blue.id
  port             = var.app_port
}

resource "aws_lb_target_group_attachment" "green" {
  target_group_arn = aws_lb_target_group.green.arn
  target_id        = aws_instance.green.id
  port             = var.app_port
}

# Default listener starts pointed at blue. This is the resource
# Jenkins/Ansible will modify (via aws elbv2 modify-listener) to flip traffic.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # Jenkins moves traffic between blue and green after this is created.
  # Without this, the next terraform apply would reset traffic to blue.
  lifecycle {
    ignore_changes = [default_action]
  }
}
