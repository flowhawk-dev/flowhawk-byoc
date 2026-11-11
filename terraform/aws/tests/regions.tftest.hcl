# Region checks that need no AWS account: `terraform init && terraform test` (mocked providers, plan only).
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/x" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:user/x" }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

variables {
  account_id     = "123456789012"
  deployment_id  = "byoc_test"
  agent_token    = "t"
  ingest_key     = "k"
  collector_host = "otel.example.com"
}

run "three_zones" {
  command = plan
  variables { region = "eu-west-1" }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["eu-west-1c", "eu-west-1a", "eu-west-1b", "eu-west-1d"] }
  }
  assert {
    condition     = local.azs == tolist(["eu-west-1a", "eu-west-1b", "eu-west-1c"])
    error_message = "a region with four zones uses the first three"
  }
}

# N. California: most accounts see two zones.
run "two_zones" {
  command = plan
  variables { region = "us-west-1" }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-west-1b", "us-west-1c"] }
  }
  assert {
    condition     = length(local.azs) == 2
    error_message = "a two-zone region gets two subnets of each kind"
  }
}

run "one_zone_refused" {
  command = plan
  variables { region = "us-west-1" }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-west-1b"] }
  }
  expect_failures = [terraform_data.zones]
}

run "govcloud" {
  command = plan
  variables {
    region      = "us-gov-west-1"
    backup_days = 30
  }
  override_data {
    target = data.aws_partition.this
    values = { partition = "aws-us-gov", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-gov-west-1a", "us-gov-west-1b", "us-gov-west-1c"] }
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws-us-gov:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "GovCloud policies use the aws-us-gov partition"
  }
}

run "china_refused" {
  command = plan
  variables { region = "cn-north-1" }
  expect_failures = [var.region]
}

run "scaling" {
  command = plan
  variables {
    region               = "eu-west-1"
    node_count_max       = 9
    clickhouse_memory_gb = 24
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  assert {
    condition     = helm_release.autoscaler.version == "9.53.0" && helm_release.metrics_server.chart == "metrics-server"
    error_message = "EKS gets the cluster autoscaler and metrics-server"
  }
  assert {
    condition     = strcontains(module.eks.cluster_addons["vpc-cni"].configuration_values, "enableNetworkPolicy")
    error_message = "network policies are enforced"
  }
}
