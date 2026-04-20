# end-to-end deploy: build image, push to ecr, run on app runner.
# requires docker running locally + aws cli already authenticated.
# first apply takes ~3-5 min (app runner creation is the slow part).

# provider pins — null is used to shell out to docker during apply
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    null = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

# aws region for every resource in this file
provider "aws" {
  region = var.region
}

# region to deploy into — change if you're not on us-east-1
variable "region" {
  type    = string
  default = "us-east-1"
}

# name of the new ecr repo this config creates.
# note: this is separate from the manual `cloud_platforms` repo —
# you'll end up with two unless you delete the old one in the console.
variable "repo_name" {
  type    = string
  default = "sample-webapi-aspnetcore"
}

# name shown in the app runner console + used in iam role name
variable "service_name" {
  type    = string
  default = "sample-webapi-aspnetcore"
}

# src_hash = deterministic hash of every input that affects the image.
# when any .cs / .csproj / .json / .sln / dockerfile byte changes, the hash
# changes → image tag changes → app runner sees a new identifier and redeploys.
# this is the mechanism that keeps infra and code in sync without manual steps.
locals {
  src_files = setunion(
    fileset("${path.module}/..", "SampleWebApiAspNetCore/**/*.cs"),
    fileset("${path.module}/..", "SampleWebApiAspNetCore/**/*.csproj"),
    fileset("${path.module}/..", "SampleWebApiAspNetCore/**/*.json"),
    fileset("${path.module}/..", "SampleWebApiAspNetCore.sln"),
  )
  src_hash = sha1(join("", concat(
    [filemd5("${path.module}/../dockerfile")],
    [for f in local.src_files : filemd5("${path.module}/../${f}")]
  )))
  # short tag keeps the image URI readable in logs/console
  image_tag = substr(local.src_hash, 0, 12)
  image_uri = "${aws_ecr_repository.app.repository_url}:${local.image_tag}"
}

# step 1: the ecr repo that will hold pushed images.
# force_delete = true lets `terraform destroy` wipe the repo even if images
# still live inside — skip this and destroy will fail on a non-empty repo.
resource "aws_ecr_repository" "app" {
  name         = var.repo_name
  force_delete = true
}

# step 2: build + push the image via the local docker daemon.
# null_resource is terraform's escape hatch for "just run a command".
# re-runs only when triggers change, so unchanged source = no rebuild.
# caveat: state tracks the trigger value, not the actual image in ecr.
# if someone deletes the image manually, tf won't know to re-push until
# a source file changes. rare, but worth knowing.
resource "null_resource" "build_push" {
  triggers = {
    src_hash = local.src_hash
    repo_url = aws_ecr_repository.app.repository_url
  }

  # --platform linux/amd64 is required on apple silicon — app runner runs
  # on x86_64 and will fail to start an arm64 image with a cryptic error.
  # two tags pushed: the hash (for immutable referencing) and :latest (for humans).
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGISTRY=$(echo "${aws_ecr_repository.app.repository_url}" | cut -d'/' -f1)
      aws ecr get-login-password --region ${var.region} \
        | docker login --username AWS --password-stdin $REGISTRY
      docker build --platform linux/amd64 \
        -f ${path.module}/../dockerfile \
        -t ${local.image_uri} \
        -t ${aws_ecr_repository.app.repository_url}:latest \
        ${path.module}/..
      docker push ${local.image_uri}
      docker push ${aws_ecr_repository.app.repository_url}:latest
    EOT
  }
}

# step 3: iam role that app runner assumes to pull from ecr.
# trust principal must be build.apprunner.amazonaws.com (not tasks.apprunner) —
# pulling happens at "build" time from app runner's perspective.
resource "aws_iam_role" "apprunner_ecr_access" {
  name = "${var.service_name}-apprunner-ecr-access"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "build.apprunner.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# aws-managed policy granting GetAuthorizationToken + BatchGetImage etc.
# writing it by hand is possible but this is the blessed one.
resource "aws_iam_role_policy_attachment" "apprunner_ecr" {
  role       = aws_iam_role.apprunner_ecr_access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# step 4: the app runner service itself — the thing that actually runs containers.
# on default specs (1 vCPU / 2 GB) this costs ~$0.07/hour while active.
# run `terraform destroy` when you're done to stop charges.
resource "aws_apprunner_service" "app" {
  service_name = var.service_name

  source_configuration {
    # links the access role from step 3
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_ecr_access.arn
    }

    image_repository {
      # using the hash-tag (not :latest) so tf detects changes and redeploys.
      # if you reference :latest here, tf sees the same string every apply
      # and won't trigger a redeploy even though the image changed.
      image_identifier      = local.image_uri
      image_repository_type = "ECR"

      image_configuration {
        # must match ASPNETCORE_URLS in the dockerfile (http://+:8080)
        port = "8080"
        runtime_environment_variables = {
          # dev env enables swagger. swap to Production once you stop needing it.
          ASPNETCORE_ENVIRONMENT = "Development"
        }
      }
    }

    # false = tf is the single source of truth for deploys.
    # true would make app runner redeploy on any ecr push, which can
    # race with terraform and cause confusing drift.
    auto_deployments_enabled = false
  }

  # smallest reasonable size. bump these if the app gets busier.
  instance_configuration {
    cpu    = "1024"
    memory = "2048"
  }

  # explicit order: image must exist and role must be attached
  # before app runner tries its first pull.
  depends_on = [
    null_resource.build_push,
    aws_iam_role_policy_attachment.apprunner_ecr,
  ]
}

# full uri of the created repo — useful for manual docker pull/push
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

# public https url app runner exposes. ready ~3-5 min after first apply.
output "service_url" {
  value = "https://${aws_apprunner_service.app.service_url}"
}

# direct link to swagger — only works while ASPNETCORE_ENVIRONMENT=Development
output "swagger_url" {
  value = "https://${aws_apprunner_service.app.service_url}/swagger"
}
