variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name used as resource name prefix"
  type        = string
  default     = "serverless-api"
}

variable "environment" {
  description = "Deployment environment (dev / prd)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment must be 'dev' or 'prd'."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 14
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch retention value."
  }
}

variable "cors_origins" {
  description = "Allowed CORS origins for API Gateway"
  type        = list(string)
  default     = ["https://example.com"]
}