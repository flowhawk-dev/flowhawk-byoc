# Location checks that need no Azure subscription: `terraform init && terraform test` (mocked providers, plan only).
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000000" }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  deployment_id   = "byoc_test"
  agent_token     = "t"
  ingest_key      = "k"
  collector_host  = "otel.example.com"
}

run "zoned_location" {
  command = plan
  variables { location = "westeurope" }
  override_data {
    target = data.azurerm_location.this
    values = { zone_mappings = [{ logical_zone = "2", physical_zone = "westeurope-az2" }, { logical_zone = "1", physical_zone = "westeurope-az1" }, { logical_zone = "3", physical_zone = "westeurope-az3" }] }
  }
  assert {
    condition     = azurerm_kubernetes_cluster.flowhawk.default_node_pool[0].zones == toset(["1", "2", "3"])
    error_message = "nodes spread over the location's zones"
  }
  assert {
    condition     = azurerm_storage_account.backups[0].account_replication_type == "ZRS"
    error_message = "backups are zone-redundant where zones exist"
  }
}

# West US, UK West, Canada East and others have no availability zones.
run "location_without_zones" {
  command = plan
  variables { location = "westus" }
  override_data {
    target = data.azurerm_location.this
    values = { zone_mappings = [] }
  }
  assert {
    condition     = azurerm_kubernetes_cluster.flowhawk.default_node_pool[0].zones == null
    error_message = "no zones are asked for where there are none"
  }
  assert {
    condition     = azurerm_storage_account.backups[0].account_replication_type == "LRS"
    error_message = "backups are locally redundant without zones"
  }
  assert {
    condition     = kubernetes_storage_class_v1.premium.parameters.skuName == "Premium_LRS"
    error_message = "ClickHouse's disks are Premium_LRS, available everywhere"
  }
}

run "government" {
  command = plan
  variables { location = "usgovvirginia" }
  override_data {
    target = data.azurerm_location.this
    values = { zone_mappings = [{ logical_zone = "1", physical_zone = "usgovvirginia-az1" }] }
  }
  assert {
    condition     = local.environment == "usgovernment"
    error_message = "Azure Government locations use its cloud"
  }
}

run "china_refused" {
  command = plan
  variables { location = "chinaeast2" }
  expect_failures = [var.location]
}

run "scaling" {
  command = plan
  variables {
    location       = "westeurope"
    node_count     = 3
    node_count_max = 9
  }
  override_data {
    target = data.azurerm_location.this
    values = { zone_mappings = [] }
  }
  assert {
    condition     = azurerm_kubernetes_cluster.flowhawk.default_node_pool[0].auto_scaling_enabled && azurerm_kubernetes_cluster.flowhawk.default_node_pool[0].max_count == 9
    error_message = "nodes autoscale from node_count to node_count_max"
  }
}
