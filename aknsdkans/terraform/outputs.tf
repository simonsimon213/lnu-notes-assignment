output "web_url" {
  description = "Open this in a browser once cloud-init has finished."
  value       = "http://${aws_instance.web.public_ip}/"
}

output "health_url" {
  description = "Tests the database and the bucket separately."
  value       = "http://${aws_instance.web.public_ip}/healthz"
}

output "db_private_ip" {
  description = "There is no public address, by design."
  value       = aws_instance.db.private_ip
}

output "bucket" {
  value = aws_s3_bucket.notes.id
}

output "ssh" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.web.public_ip}"
}

# Identifiers, so nothing has to be looked up by hand or remembered between sessions.
output "web_instance_id" { value = aws_instance.web.id }
output "db_instance_id" { value = aws_instance.db.id }
output "web_public_ip" { value = aws_instance.web.public_ip }
output "web_sg_id" { value = aws_security_group.web.id }
output "db_sg_id" { value = aws_security_group.db.id }
output "instance_profile" { value = aws_iam_instance_profile.web.name }
output "vpc_id" { value = aws_vpc.main.id }
