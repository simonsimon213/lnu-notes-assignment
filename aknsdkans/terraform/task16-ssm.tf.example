# --- task 16: both instances read the password from SSM; Terraform never sees it.
resource "aws_iam_role_policy" "web_ssm" {
  name = "read-db-password"
  role = aws_iam_role.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter"],
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/2dv705/db_password" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*",
      Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" } } }
    ]
  })
}

# The database had no role before; it needs one now to read the parameter.
resource "aws_iam_role" "db" {
  name = "${var.project}-db"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "db_ssm" {
  name   = "read-db-password"
  role   = aws_iam_role.db.id
  policy = aws_iam_role_policy.web_ssm.policy
}

resource "aws_iam_instance_profile" "db" {
  name = "${var.project}-db"
  role = aws_iam_role.db.name
}
