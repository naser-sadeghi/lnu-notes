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
