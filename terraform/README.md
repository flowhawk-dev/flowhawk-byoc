# Terraform for Flowhawk in your cloud

One module per cloud. Settings > Storage shows the block to apply, with your deployment id filled in. Each module
makes a network, a managed Kubernetes cluster sized for ClickHouse and the collector, a disk class for ClickHouse
(kept on destroy of the volume claim: `Retain`), ingress-nginx, cert-manager (with `acme_email`) and the Flowhawk agent
([modules/apps](modules/apps)); the agent installs ClickHouse and the collector itself.

Regions: every commercial region of the three clouds, AWS GovCloud (`us-gov-*`, the `aws-us-gov` partition) and Azure
Government (`usgov*`, `usdod*`). AWS opt-in regions (Cape Town, Hong Kong, Bahrain and others) work once the region is
enabled in the account (AWS console > Account > AWS Regions). AWS China and Azure China are separate clouds and are
refused: they would need an account there and mirrors of every image inside China.

| Cloud | Folder | Where | Cluster | ClickHouse disk |
| --- | --- | --- | --- | --- |
| AWS | `aws` | `region`, `account_id` (checked against your credentials) | VPC (up to 3 zones, two where the account has only two, such as N. California; one NAT gateway) and EKS with one managed node group (`m6i.xlarge`) | gp3, encrypted |
| Google Cloud | `gcp` | `region`, `project` | VPC with Cloud NAT and a regional GKE cluster with private nodes and Dataplane V2 (`e2-standard-4`) | pd-balanced |
| Azure | `azure` | `location`, `subscription_id` | Resource group and AKS with Azure RBAC and Cilium (`Standard_D4s_v5`, spread over the location's zones where it has them) | Premium SSD (LRS) |

```hcl
variable "flowhawk_agent_token" { sensitive = true }
variable "flowhawk_ingest_key" { sensitive = true }

module "flowhawk_byoc" {
  source = "github.com/flowhawk-dev/flowhawk-byoc//terraform/aws?ref=v0.1.2"

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

Sizing: `node_size` and `node_count` (default 3) set the nodes, and the cluster adds nodes up to `node_count_max` (default
6) when the collectors scale out. `clickhouse_cpu` (2), `clickhouse_memory_gb` (8) and `clickhouse_storage_gb` (200)
size ClickHouse; raise them in Terraform and apply, and the agent applies them (a bigger disk grows in place, a smaller
one is ignored). ClickHouse is a single replica: its disk is zonal, so if its zone fails it waits for that zone.

After `terraform apply`, point `collector_host` at `collector_ingress_address` (a CNAME on AWS, an A record on Google
Cloud and Azure). Settings > Storage shows what the agent waits for until the cluster is running.

**Support access** (`support_principal`, optional and read-only): on AWS an IAM role ARN with an EKS access entry for
`AmazonEKSViewPolicy`; on Google Cloud a member (`group:...` or `serviceAccount:...`) with `roles/container.viewer`; on
Azure an object id with the AKS RBAC Reader and Cluster User roles on this cluster only. Leave it out to keep Flowhawk
out of the cluster entirely.

**Backups** (`backup_days`, default 30; 0 turns them off): ClickHouse backs up the workspace's database every night
at 03:00 UTC to a bucket in your account, a full backup each week and an incremental one on the other days. Flowhawk
never gets access to the bucket.

| Cloud | Bucket | How ClickHouse writes to it |
| --- | --- | --- |
| AWS | S3, private, SSE-S3 encrypted (output `backup_bucket`) | An IAM role only ClickHouse's service account can take (IRSA), allowed this bucket only |
| Google Cloud | Cloud Storage, private, uniform access (output `backup_bucket`) | A service account allowed this bucket only, through Cloud Storage's S3 interface with an HMAC key kept in a Kubernetes secret |
| Azure | A storage account with a private container (output `backup_bucket`) | The storage account's key, kept in a Kubernetes secret |

A lifecycle rule on the bucket deletes backups `backup_days` plus 7 days after they were written, so every backup of
the last `backup_days` days still has its weekly full backup. Nothing in the cluster deletes backups. On AWS and Google
Cloud `terraform destroy` stops at a bucket that still holds backups (empty it first if you want it gone); on Azure it
deletes the storage account with them, so copy what you want to keep first.

To restore, list the bucket (`full-<yyyymmdd>` and `incr-<time>` folders) and run, as `flowhawk_admin` on the cluster's
ClickHouse, `RESTORE DATABASE ws_<workspace> FROM Disk('flowhawk_backups', 'incr-20261110T030012Z')` (an incremental
backup brings its full one in by itself). A new cluster made with the same Terraform reads the same bucket.

**Removing it:** remove the cluster in Settings > Storage, then `terraform destroy`. ClickHouse's disk is kept by the
`Retain` class; delete it in the cloud console once you no longer need the data.

`terraform validate` passes for all three with the provider versions pinned in each `main.tf`
(AWS 6, Google 8, AzureRM 5, Helm 3, Kubernetes 3). `terraform test` in `aws/` and `azure/` plans against mocked
providers, with no account: regions with three, two and one zones, GovCloud, Azure locations with and without zones,
Azure Government, and China refused. The backup resources (added 2026-11-10) have passed `terraform fmt`
only; they get validated, and a first backup and restore tried, on the first run in a real account.
