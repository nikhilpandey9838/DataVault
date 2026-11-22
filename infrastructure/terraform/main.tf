
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

resource "aws_s3_bucket" "datavault" {
  bucket = "datavault-backups-2500"

  tags = {
    Name        = "DataVault Backups"
    Project     = "DataVault"
    Environment = "Development"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "datavault" {
  bucket = aws_s3_bucket.datavault.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datavault" {
  bucket = aws_s3_bucket.datavault.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "datavault" {
  bucket = aws_s3_bucket.datavault.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}



resource "aws_s3_bucket_lifecycle_configuration" "datavault" {
  bucket = aws_s3_bucket.datavault.id

  rule {
    id     = "backup-retention"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
