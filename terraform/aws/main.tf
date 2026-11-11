# A Flowhawk cluster in your AWS account: a VPC, an EKS cluster with one managed node group, gp3 disks for ClickHouse,
# and the Flowhawk agent (modules/apps). Flowhawk never gets credentials to this account; the agent only calls out.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }
}

variable "region" {
  type = string
  validation {
    condition     = !startswith(var.region, "cn-")
    error_message = "AWS China regions aren't supported: they need a separate AWS China account and image mirrors inside China."
  }
}
variable "account_id" {
  description = "Checked against the credentials Terraform runs with, so the cluster lands in the account you registered."
  type        = string
}
variable "node_size" {
  type    = string
  default = "m6i.xlarge"
}
variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { "flowhawk.dev/deployment" = var.deployment_id } }
}

# The partition makes ARNs and addresses right in GovCloud as well as the commercial regions.
data "aws_partition" "this" {}

# Regular zones only: Local Zones and Wavelength Zones are opt-in and can't hold the cluster's subnets. Some regions,
# and some accounts in a region (N. California), have only two, so the network uses up to three.
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, min(3, length(data.aws_availability_zones.available.names)))
}
resource "terraform_data" "zones" {
  lifecycle {
    precondition {
      condition     = length(local.azs) >= 2
      error_message = "EKS needs two availability zones; ${var.region} offers this account ${length(local.azs)}."
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name               = var.cluster_name
  cidr               = "10.42.0.0/16"
  azs                = local.azs
  private_subnets    = slice(["10.42.0.0/19", "10.42.32.0/19", "10.42.64.0/19"], 0, length(local.azs))
  public_subnets     = slice(["10.42.96.0/22", "10.42.100.0/22", "10.42.104.0/22"], 0, length(local.azs))
  enable_nat_gateway = true
  single_nat_gateway = true
  # Where Kubernetes puts load balancers: public ones for ClickHouse (Flowhawk's addresses only) and the collector.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = var.cluster_name
  kubernetes_version                       = var.kubernetes_version
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    # enableNetworkPolicy: without it EKS ignores the NetworkPolicies that keep ClickHouse and the trace collectors
    # to the namespace.
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = { before_compute = true }
    aws-ebs-csi-driver     = { pod_identity_association = [{ role_arn = aws_iam_role.ebs_csi.arn, service_account = "ebs-csi-controller-sa" }] }
  }

  eks_managed_node_groups = {
    flowhawk = {
      instance_types = [var.node_size]
      # The cluster autoscaler (below) adds nodes, up to node_count_max, when pods (more collectors) don't fit.
      min_size     = var.node_count
      max_size     = max(var.node_count, var.node_count_max)
      desired_size = var.node_count
      disk_size    = 50
    }
  }

  # Flowhawk support: read-only, cluster-wide (AmazonEKSViewPolicy), and nothing else in the account.
  access_entries = var.support_principal == "" ? {} : {
    flowhawk_support = {
      principal_arn = var.support_principal
      policy_associations = {
        view = {
          policy_arn   = "arn:${data.aws_partition.this.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

# The EBS CSI driver's role, through EKS Pod Identity.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Node autoscaling. EKS has neither the cluster autoscaler nor metrics-server (which the collectors' autoscalers read),
# unlike GKE and AKS, so they are installed here. The autoscaler's role (EKS Pod Identity) may resize only this
# cluster's node groups, which EKS tags for it.
resource "aws_iam_role" "autoscaler" {
  name = "${var.cluster_name}-autoscaler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}
resource "aws_iam_role_policy" "autoscaler" {
  name = "node-groups"
  role = aws_iam_role.autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities", "autoscaling:DescribeTags", "ec2:DescribeImages", "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplateVersions", "ec2:GetInstanceTypesFromInstanceRequirements", "eks:DescribeNodegroup"]
        Resource = "*"
      },
      {
        Effect    = "Allow"
        Action    = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/k8s.io/cluster-autoscaler/${module.eks.cluster_name}" = "owned" } }
      },
    ]
  })
}
resource "aws_eks_pod_identity_association" "autoscaler" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.autoscaler.arn
}
resource "helm_release" "autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  # Cluster autoscaler 1.34, for kubernetes_version 1.34; move both together.
  version = "9.53.0"
  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.region
    autoDiscovery = { clusterName = module.eks.cluster_name }
    rbac          = { serviceAccount = { name = "cluster-autoscaler" } }
    extraArgs     = { "balance-similar-node-groups" = true, "skip-nodes-with-local-storage" = false }
  })]
  depends_on = [aws_eks_pod_identity_association.autoscaler]
}
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  depends_on = [module.eks]
}

# Nightly backups (backup_days): a private, encrypted bucket that deletes backups a week after backup_days, and a
# role only ClickHouse's service account can take (IRSA), allowed this bucket and nothing else.
resource "aws_s3_bucket" "backups" {
  count         = var.backup_days > 0 ? 1 : 0
  bucket_prefix = "${var.cluster_name}-backups-"
}
resource "aws_s3_bucket_public_access_block" "backups" {
  count                   = var.backup_days > 0 ? 1 : 0
  bucket                  = aws_s3_bucket.backups[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count  = var.backup_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count  = var.backup_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id
  rule {
    id     = "expire-backups"
    status = "Enabled"
    filter {}
    # A week more than backup_days, so an incremental backup's weekly full backup outlives it.
    expiration { days = var.backup_days + 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}
resource "aws_iam_role" "backups" {
  count = var.backup_days > 0 ? 1 : 0
  name  = "${var.cluster_name}-clickhouse-backups"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:flowhawk:flowhawk-clickhouse"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
resource "aws_iam_role_policy" "backups" {
  count = var.backup_days > 0 ? 1 : 0
  name  = "bucket"
  role  = aws_iam_role.backups[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.backups[0].arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"], Resource = "${aws_s3_bucket.backups[0].arn}/*" },
    ]
  })
}

data "aws_eks_cluster_auth" "this" { name = module.eks.cluster_name }

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata { name = "flowhawk-gp3" }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [module.eks]
}

module "apps" {
  source                = "../modules/apps"
  deployment_id         = var.deployment_id
  control_url           = var.control_url
  cloud                 = "aws"
  agent_token           = var.agent_token
  ingest_key            = var.ingest_key
  collector_host        = var.collector_host
  acme_email            = var.acme_email
  storage_class         = kubernetes_storage_class_v1.gp3.metadata[0].name
  clickhouse_storage_gb = var.clickhouse_storage_gb
  clickhouse_cpu        = var.clickhouse_cpu
  clickhouse_memory_gb  = var.clickhouse_memory_gb
  agent_image_tag       = var.agent_image_tag
  backup = var.backup_days == 0 ? null : {
    kind                      = "s3"
    endpoint                  = "https://${aws_s3_bucket.backups[0].bucket}.s3.${var.region}.${data.aws_partition.this.dns_suffix}/flowhawk/"
    serviceAccountAnnotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.backups[0].arn }
    keepDays                  = var.backup_days
  }
  ingress_annotations = {
    "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
    "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
  }
  depends_on = [module.eks]
}

output "collector_ingress_address" {
  description = "Point collector_host at this hostname (a CNAME)."
  value       = module.apps.collector_ingress_address
}
output "cluster_name" { value = module.eks.cluster_name }
output "backup_bucket" {
  description = "Where ClickHouse's nightly backups go (empty when backup_days is 0)."
  value       = var.backup_days > 0 ? aws_s3_bucket.backups[0].bucket : ""
}
output "kubeconfig_command" { value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}" }
