output "api_endpoint" {
  description = "HTTP API Gateway invoke URL"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.handler.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.handler.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.items.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.items.arn
}

output "kms_key_arn" {
  description = "KMS CMK ARN used for encryption"
  value       = aws_kms_key.main.arn
}

output "kms_key_alias" {
  description = "KMS CMK alias"
  value       = aws_kms_alias.main.name
}

output "lambda_log_group" {
  description = "Lambda CloudWatch Log Group name"
  value       = aws_cloudwatch_log_group.lambda.name
}

output "apigw_log_group" {
  description = "API Gateway CloudWatch Log Group name"
  value       = aws_cloudwatch_log_group.apigw.name
}