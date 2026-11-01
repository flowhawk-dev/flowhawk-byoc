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

variable "region" { type = string }
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

data "aws_availability_zones" "available" { state = "available" }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name               = var.cluster_name
  cidr               = "10.42.0.0/16"
  azs                = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets    = ["10.42.0.0/19", "10.42.32.0/19", "10.42.64.0/19"]
  public_subnets     = ["10.42.96.0/22", "10.42.100.0/22", "10.42.104.0/22"]
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
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    aws-ebs-csi-driver     = { pod_identity_association = [{ role_arn = aws_iam_role.ebs_csi.arn, service_account = "ebs-csi-controller-sa" }] }
  }

  eks_managed_node_groups = {
    flowhawk = {
      instance_types = [var.node_size]
      min_size       = var.node_count
      max_size       = var.node_count
      desired_size   = var.node_count
      disk_size      = 50
    }
  }

  # Flowhawk support: read-only, cluster-wide (AmazonEKSViewPolicy), and nothing else in the account.
  access_entries = var.support_principal == "" ? {} : {
    flowhawk_support = {
      principal_arn = var.support_principal
      policy_associations = {
        view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
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
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
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
  agent_image_tag       = var.agent_image_tag
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
output "kubeconfig_command" { value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}" }
