# creates a public-ish RDS postgres, allows only the current public IP on 5432,
# and auto-loads happiness_index.sql once the db is ready
# prerequisites: aws cli authenticated + a local psql binary that can reach the internet
# cost note: db.t4g.micro is free-tier eligible for 750h/month in the first year;
# after that it's ~$12/month even if idle. run `terraform destroy` when done.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
    http   = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# identifier = rds "name" in the console; also used as prefix for sg/subnet group
variable "identifier" {
  type    = string
  default = "happiness"
}

# name of the logical database created inside the instance
variable "db_name" {
  type    = string
  default = "happiness"
}

variable "master_username" {
  type    = string
  default = "postgres"
}

# path to a local psql used for the migration step.
# points to Postgres.app v18 by default; override with -var if installed elsewhere.
# a newer psql talking to an older server is fine for plain SQL dumps.
variable "psql_binary" {
  type    = string
  default = "/Applications/Postgres.app/Contents/Versions/18/bin/psql"
}

# ---- networking ----
# use the default vpc so we don't have to design a vpc/igw/route-table from scratch.
# the default vpc already has one public subnet per AZ, which rds needs
# (subnet group requires ≥2 subnets in ≥2 AZs).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_db_subnet_group" "happiness" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# discover the laptop's public IP at plan time so the security group can allowlist it.
# caveat: this resolves once when terraform runs. if your isp reassigns your ip later,
# you'll need to re-apply to update the sg rule.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"
}

# firewall: postgres port reachable only from my /32
resource "aws_security_group" "happiness" {
  name        = "${var.identifier}-pg-sg"
  description = "allow postgres from my current public ip"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # open egress lets the instance reach aws internal services if ever needed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---- master password ----
# special=false avoids rds's forbidden characters and shell-escaping headaches.
# 24 alphanumeric chars ≈ 144 bits of entropy — plenty.
resource "random_password" "master" {
  length  = 24
  special = false
}

# ---- the rds instance itself ----
# takes ~5-10 minutes to become "available" on the first apply.
resource "aws_db_instance" "happiness" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = "17"              # dump was from 15.2; restoring into 17 is fine
  instance_class = "db.t4g.micro"    # cheapest graviton tier; free-tier eligible

  allocated_storage = 20             # gb; 20 is the minimum for gp3
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name             # rds creates this database at launch
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.happiness.name
  vpc_security_group_ids = [aws_security_group.happiness.id]
  publicly_accessible    = true      # the sg still restricts who can actually reach it

  # settings tuned for a throwaway demo — not prod-safe:
  skip_final_snapshot     = true     # `terraform destroy` wipes the db without a snapshot
  backup_retention_period = 0        # no automated backups (saves a few $/month)
  apply_immediately       = true     # don't defer config changes to the next maint window
  deletion_protection     = false
}

# ---- migration ----
# re-runs when the dump file changes or when the rds endpoint changes
# (i.e. on first create). drops public schema first so re-imports are idempotent
# — otherwise the second apply would fail on duplicate objects.
resource "null_resource" "migrate" {
  triggers = {
    dump_hash = filemd5("${path.module}/../../happiness_index.sql")
    endpoint  = aws_db_instance.happiness.endpoint
  }

  provisioner "local-exec" {
    # PGPASSWORD is the standard way to pass a password to psql non-interactively.
    environment = {
      PGPASSWORD = random_password.master.result
    }

    command = <<-EOT
      set -e
      PSQL=${var.psql_binary}
      HOST=${aws_db_instance.happiness.address}
      # reset schema for idempotency
      $PSQL -h $HOST -U ${var.master_username} -d ${var.db_name} -v ON_ERROR_STOP=1 \
        -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;'
      # load the dump
      $PSQL -h $HOST -U ${var.master_username} -d ${var.db_name} -v ON_ERROR_STOP=1 \
        -f ${path.module}/../../happiness_index.sql
    EOT
  }
}

# ---- outputs ----
# full "host:port" for libraries that want it in one string
output "endpoint" {
  value = aws_db_instance.happiness.endpoint
}

output "address" {
  value = aws_db_instance.happiness.address
}

output "port" {
  value = aws_db_instance.happiness.port
}

output "db_name" {
  value = var.db_name
}

output "master_username" {
  value = var.master_username
}

# sensitive → terraform hides it in normal output; retrieve with
# `terraform output -raw master_password`
output "master_password" {
  value     = random_password.master.result
  sensitive = true
}

# copy-paste this to connect with psql. run `terraform output -raw connect_command`.
output "connect_command" {
  value     = "PGPASSWORD='${random_password.master.result}' ${var.psql_binary} -h ${aws_db_instance.happiness.address} -U ${var.master_username} -d ${var.db_name}"
  sensitive = true
}
