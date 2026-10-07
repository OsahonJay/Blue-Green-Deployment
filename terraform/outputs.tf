output "blue_instance_public_ip" {
  value = aws_instance.blue.public_ip
}

output "green_instance_public_ip" {
  value = aws_instance.green.public_ip
}

output "blue_instance_private_ip" {
  value = aws_instance.blue.private_ip
}

output "green_instance_private_ip" {
  value = aws_instance.green.private_ip
}

output "jenkins_public_ip" {
  value = aws_eip.jenkins.public_ip
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "blue_target_group_arn" {
  value = aws_lb_target_group.blue.arn
}

output "green_target_group_arn" {
  value = aws_lb_target_group.green.arn
}

output "listener_arn" {
  value = aws_lb_listener.http.arn
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}
