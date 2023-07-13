
provider "aws" {
  region = "us-west-2"
}

variable "name" {
  type    = string
  default = "ses-email-auto-validation"
}

variable "orig_domain" {
  type = string
}

variable "domain" {
  type = string
}

variable "emails" {
  type = list(string)
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "orig" {
  name = var.orig_domain
}

resource "aws_route53_zone" "main" {
  name = var.domain
}

resource "aws_route53_record" "ns" {
  zone_id = data.aws_route53_zone.orig.zone_id
  name    = aws_route53_zone.main.name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.main.name_servers
}

resource "aws_ses_domain_identity" "main" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = aws_route53_zone.main.zone_id
  name    = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}._domainkey"
  type    = "CNAME"
  ttl     = "600"
  records = ["${aws_ses_domain_dkim.main.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_ses_domain_identity_verification" "main" {
  domain = aws_ses_domain_identity.main.domain
  depends_on = [
    aws_route53_record.ns,
    aws_route53_record.dkim,
  ]
}

resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = "600"
  records = ["10 inbound-smtp.${data.aws_region.current.name}.amazonaws.com"]
}

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = var.name
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "main" {
  name          = var.name
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = var.emails
  enabled       = true
  sns_action {
    topic_arn = aws_sns_topic.main.arn
    position  = 1
  }
}

resource "aws_sns_topic" "main" {
  name = var.name
}

resource "aws_sns_topic_subscription" "main" {
  topic_arn  = aws_sns_topic.main.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.main.arn
  depends_on = [aws_lambda_permission.main]
}

data "archive_file" "main" {
  type        = "zip"
  source_file = "${path.module}/index.mjs"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "main" {
  function_name    = var.name
  role             = aws_iam_role.main.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  timeout          = 60
  filename         = "${path.module}/lambda.zip"
  source_code_hash = data.archive_file.main.output_base64sha256
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = 3
}

resource "aws_iam_role" "main" {
  name = var.name
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : "sts:AssumeRole",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
      }
    ]
  })
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  ]
}

resource "aws_lambda_permission" "main" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.main.function_name
  principal      = "sns.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = aws_sns_topic.main.arn
}

resource "aws_ses_email_identity" "emails" {
  for_each = toset(var.emails)
  email    = each.key

  depends_on = [
    aws_ses_domain_identity_verification.main,
    aws_route53_record.mx,
    aws_ses_active_receipt_rule_set.main,
    aws_ses_receipt_rule.main,
    aws_sns_topic_subscription.main,
  ]
}
