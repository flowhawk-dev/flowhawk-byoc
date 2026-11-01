# Terraform for Flowhawk in your cloud

One module per cloud. Settings > Storage shows the block to apply, with your deployment id filled in. Each module
makes a network, a managed Kubernetes cluster sized for ClickHouse and the collector, a disk class for ClickHouse
(kept on destroy of the volume claim: `Retain`), ingress-nginx, cert-manager (with `acme_email`) and the Flowhawk agent
([modules/apps](modules/apps)); the agent installs ClickHouse and the collector itself.

| Cloud | Folder | Where | Cluster | ClickHouse disk |
| --- | --- | --- | --- | --- |
| AWS | `aws` | `region`, `account_id` (checked against your credentials) | VPC (3 zones, one NAT gateway) and EKS with one managed node group (`m6i.xlarge`) | gp3, encrypted |
| Google Cloud | `gcp` | `region`, `project` | VPC with Cloud NAT and a regional GKE cluster with private nodes and Dataplane V2 (`e2-standard-4`) | pd-balanced |
| Azure | `azure` | `location`, `subscription_id` | Resource group and AKS with Azure RBAC and Cilium (`Standard_D4s_v5`, 3 zones) | Premium ZRS |

```hcl
variable "flowhawk_agent_token" { sensitive = true }
variable "flowhawk_ingest_key" { sensitive = true }

module "flowhawk_byoc" {
  source = "github.com/flowhawk-dev/flowhawk-byoc//terraform/aws?ref=v0.1.0"

  region        = "eu-central-1"
  account_id    = "123456789012"
  deployment_id = "byoc_..."
  agent_token   = var.flowhawk_agent_token
  ingest_key    = var.flowhawk_ingest_key

  collector_host = "otel.example.com"
  acme_email     = "ops@example.com"
}

output "collector_ingress_address" { value = module.flowhawk_byoc.collector_ingress_address }
```

After `terraform apply`, point `collector_host` at `collector_ingress_address` (a CNAME on AWS, an A record on Google
Cloud and Azure). Settings > Storage shows what the agent waits for until the cluster is running.

**Support access** (`support_principal`, optional and read-only): on AWS an IAM role ARN with an EKS access entry for
`AmazonEKSViewPolicy`; on Google Cloud a member (`group:...` or `serviceAccount:...`) with `roles/container.viewer`; on
Azure an object id with the AKS RBAC Reader and Cluster User roles on this cluster only. Leave it out to keep Flowhawk
out of the cluster entirely.

**Removing it:** remove the cluster in Settings > Storage, then `terraform destroy`. ClickHouse's disk is kept by the
`Retain` class; delete it in the cloud console once you no longer need the data.

`terraform validate` passes for all three with the provider versions pinned in each `main.tf`
(AWS 6, Google 8, AzureRM 5, Helm 3, Kubernetes 3).
