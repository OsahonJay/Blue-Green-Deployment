# Logging and monitoring for the blue/green stack.
# Logs: every container ships its stdout to one CloudWatch log group (one stream per color and version).
# Alerts: CloudWatch alarms on what users actually experience, sent to an SNS topic.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/bluegreen/bankapp"
  retention_in_days = 7
}

# Lets the blue/green servers write container logs to that log group, and nothing else.
resource "aws_iam_role" "app" {
  name = "${var.project_name}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "app_logs" {
  name = "${var.project_name}-app-logs"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.app.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# Optional: set alert_email in terraform.tfvars to get emails (AWS sends a confirmation link first).
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Users are getting errors from the load balancer itself (for example 503 when no backend is healthy).
resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  alarm_name          = "${var.project_name}-users-seeing-5xx"
  alarm_description   = "The load balancer returned 5xx errors to users"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# The application itself is returning 5xx errors.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.project_name}-app-returning-5xx"
  alarm_description   = "The application behind the load balancer returned 5xx errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Total outage: neither color has a healthy server. Both colors are added together on purpose, because
# the idle color is briefly unhealthy during every deployment and must not raise a false alarm.
resource "aws_cloudwatch_metric_alarm" "no_healthy_backend" {
  alarm_name          = "${var.project_name}-no-healthy-backend"
  alarm_description   = "Neither blue nor green has a healthy server"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "total"
    expression  = "FILL(blue, 0) + FILL(green, 0)"
    label       = "Healthy servers (blue + green)"
    return_data = true
  }

  metric_query {
    id = "blue"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Maximum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.blue.arn_suffix
      }
    }
  }

  metric_query {
    id = "green"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Maximum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
        TargetGroup  = aws_lb_target_group.green.arn_suffix
      }
    }
  }
}
