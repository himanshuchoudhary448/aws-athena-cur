data "aws_caller_identity" "current" {}

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.2.2"

  bucket = "hejoes-cur"

  versioning = {
    enabled = true
  }


  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCURPutObject"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action = [
          "s3:PutObject"
        ]
        Resource = [
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]

      },
      {
        Sid    = "AllowCURGetBucketAcl"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy"
        ]
        Resource = [
          module.s3_bucket.s3_bucket_arn
        ]

      },
      {
        Sid    = "AllowAthenaAccess"
        Effect = "Allow"
        Principal = {
          Service = "athena.amazonaws.com"
        }
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}


resource "aws_cur_report_definition" "cur" {
  report_name                = "cost-usage-report"
  time_unit                  = "HOURLY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = module.s3_bucket.s3_bucket_id
  s3_region                  = "eu-north-1"
  s3_prefix                  = "cur"
  additional_artifacts       = ["ATHENA"]
  refresh_closed_reports     = true
  report_versioning          = "OVERWRITE_REPORT"
}


resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = module.s3_bucket.s3_bucket_id

  queue {
    queue_arn     = aws_sqs_queue.crawler_queue.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = "cur/"
    filter_suffix = ".parquet"
  }
}

#################################
##           Athena
#################################

module "bucket_athena_results" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.2.2"

  bucket = "hejoes-cur-athena-results"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup"
      enabled = true

      expiration = {
        days = 14
      }
    }
  ]
}

resource "aws_athena_workgroup" "cur_workgroup" {
  name = "cur_workgroup"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${module.bucket_athena_results.s3_bucket_id}/output/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

#################################
##           Glue Database
#################################

resource "aws_glue_catalog_database" "cur_database" {
  name = "cur_database"
}

resource "aws_glue_catalog_table" "resources_view" {
  name          = "resource_tags_summary"
  database_name = aws_glue_catalog_database.cur_database.name

  table_type = "VIRTUAL_VIEW"

  parameters = {
    presto_view = "true"
    comment     = "View AWS Service costs based off tags"
  }

  storage_descriptor {
    columns {
      name = "resource_id"
      type = "string"
    }
    columns {
      name = "tag_key"
      type = "string"
    }
    columns {
      name = "tag_value"
      type = "string"
    }
    columns {
      name = "total_cost"
      type = "double"
    }
  }
}

resource "aws_glue_catalog_table" "daily_view" {
  name          = "daily costs summary"
  database_name = aws_glue_catalog_database.cur_database.name

  table_type = "VIRTUAL_VIEW"

  parameters = {
    presto_view = "true"
    comment     = "Daily AWS Costs"
  }

  storage_descriptor {
    columns {
      name = "usage_date"
      type = "date"
    }
    columns {
      name = "service"
      type = "string"
    }
    columns {
      name = "usage_type"
      type = "string"
    }
    columns {
      name = "total_cost"
      type = "double"
    }
  }
}


#################################
##           Glue Crawler
#################################

resource "aws_glue_crawler" "cur_crawler" {
  database_name = aws_glue_catalog_database.cur_database.name
  name          = "cur-crawler"
  role          = aws_iam_role.glue_role.arn

  s3_target {
    path                = "s3://${module.s3_bucket.s3_bucket_id}/cur"
    event_queue_arn     = aws_sqs_queue.crawler_queue.arn
    dlq_event_queue_arn = aws_sqs_queue.crawler_dlq.arn
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_EVENT_MODE"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

resource "aws_iam_role" "glue_role" {
  name = "GlueRole-CUR"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "glue_policy" {
  name = "GluePolicy-CUR"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*",
          module.bucket_athena_results.s3_bucket_arn,
          "${module.bucket_athena_results.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:*"
        ]
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:*",
        ]
        Resource = [
          aws_sqs_queue.crawler_queue.arn,
          aws_sqs_queue.crawler_dlq.arn
        ]
      }
    ]
  })
}


#################################
##           SQS
#################################

resource "aws_sqs_queue" "crawler_queue" {
  name                       = "cur-crawler-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.crawler_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "crawler_dlq" {
  name                      = "cur-crawler-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue_policy" "crawler_queue_policy" {
  queue_url = aws_sqs_queue.crawler_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.crawler_queue.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" : module.s3_bucket.s3_bucket_arn
          }
        }
      }
    ]
  })
}

