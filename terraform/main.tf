terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "serverless-api/terraform.tfstate"
  #   region         = "ap-northeast-1"
  #   dynamodb_table = "terraform-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project_name, Env = var.environment, ManagedBy = "Terraform" } }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ── KMS CMK ──────────────────────────────────────────────────
resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "RootAccess", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }, Action = "kms:*", Resource = "*" },
      { Sid = "LambdaUse", Effect = "Allow", Principal = { AWS = aws_iam_role.lambda.arn }, Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "*" },
      { Sid = "CWLogs", Effect = "Allow", Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = "*" }
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ── DynamoDB ──────────────────────────────────────────────────
resource "aws_dynamodb_table" "items" {
  name         = "${local.name_prefix}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk", type = "S" }
  attribute { name = "sk", type = "S" }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true; kms_key_arn = aws_kms_key.main.arn }
  deletion_protection_enabled = var.environment == "prd"
}

# ── IAM Role for Lambda ───────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoDBAccess"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.items.arn, "${aws_dynamodb_table.items.arn}/index/*"]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# ── CloudWatch Log Groups ─────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-handler"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

# ── Lambda Function ───────────────────────────────────────────
data "aws_caller_identity" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/.build/handler.zip"
}

resource "aws_lambda_function" "handler" {
  function_name    = "${local.name_prefix}-handler"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handlers/index.handler"
  runtime          = "nodejs20.x"
  architectures    = ["arm64"]
  timeout          = 29
  memory_size      = 512

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.items.name
      ENVIRONMENT = var.environment
      POWERTOOLS_SERVICE_NAME = local.name_prefix
    }
  }

  tracing_config { mode = "Active" }
  logging_config { log_group  = aws_cloudwatch_log_group.lambda.name, log_format = "JSON" }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# ── API Gateway HTTP API ──────────────────────────────────────
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = var.cors_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format          = jsonencode({ requestId = "$context.requestId", sourceIp = "$context.identity.sourceIp", httpMethod = "$context.httpMethod", path = "$context.path", status = "$context.status", responseLatency = "$context.responseLatency" })
  }
  default_route_settings {
    throttling_burst_limit = 500
    throttling_rate_limit  = 1000
    detailed_metrics_enabled = true
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "items" {
  for_each  = toset(["GET /items", "POST /items", "GET /items/{id}", "PUT /items/{id}", "DELETE /items/{id}"])
  api_id    = aws_apigatewayv2_api.main.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}