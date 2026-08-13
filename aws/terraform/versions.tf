# Terraform + provider version constraints.
#
# aws is pinned to the 5.x line: aws_lambda_invocation's lifecycle_scope = "CRUD"
# (used to invoke our helper Lambdas on create/update/destroy) and the
# data.aws_region.name attribute both behave as this module expects there.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
