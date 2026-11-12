data "azurerm_client_config" "current" {}

locals {
  velero_namespace       = "velero"
  velero_service_account = "velero"
  velero_clusters = {
    source = {
      name                   = azurerm_kubernetes_cluster.source_cluster.name
      location               = azurerm_kubernetes_cluster.source_cluster.location
      oidc_issuer_url        = azurerm_kubernetes_cluster.source_cluster.oidc_issuer_url
      node_resource_group    = azurerm_kubernetes_cluster.source_cluster.node_resource_group
      node_resource_group_id = azurerm_kubernetes_cluster.source_cluster.node_resource_group_id
    }
    destination = {
      name                   = azurerm_kubernetes_cluster.destination_cluster.name
      location               = azurerm_kubernetes_cluster.destination_cluster.location
      oidc_issuer_url        = azurerm_kubernetes_cluster.destination_cluster.oidc_issuer_url
      node_resource_group    = azurerm_kubernetes_cluster.destination_cluster.node_resource_group
      node_resource_group_id = azurerm_kubernetes_cluster.destination_cluster.node_resource_group_id
    }
  }
}

# Keep backups and snapshots outside the AKS and node resource groups.
resource "azurerm_resource_group" "velero" {
  name     = "${var.resource_group_name}-velero-${random_string.suffix.result}"
  location = var.location
}

resource "azurerm_storage_account" "velero" {
  name                            = "velero${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.velero.name
  location                        = var.destination_cluster_region
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Disabled"
}

resource "azurerm_storage_container" "velero" {
  name                  = "velero"
  storage_account_id    = azurerm_storage_account.velero.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "velero" {
  for_each = local.velero_clusters

  name                = "velero-${each.key}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.velero.name
  location            = azurerm_resource_group.velero.location
}

resource "azurerm_federated_identity_credential" "velero" {
  for_each = local.velero_clusters

  name                      = "velero-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.velero[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = each.value.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.velero_namespace}:${local.velero_service_account}"
}

# The explicit blob endpoint in the installer avoids storage Reader/ListKeys access.
resource "azurerm_role_assignment" "velero_blob" {
  for_each = local.velero_clusters

  scope                = "${azurerm_storage_account.velero.id}/blobServices/default/containers/${azurerm_storage_container.velero.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.velero[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_definition" "velero_disks" {
  name        = "Velero Disk Backup ${random_string.suffix.result}"
  scope       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  description = "Manage Velero disk snapshots and restore managed disks without storage account key access."

  permissions {
    actions = [
      "Microsoft.Compute/disks/read",
      "Microsoft.Compute/disks/write",
      "Microsoft.Compute/disks/beginGetAccess/action",
      "Microsoft.Compute/disks/endGetAccess/action",
      "Microsoft.Compute/snapshots/read",
      "Microsoft.Compute/snapshots/write",
      "Microsoft.Compute/snapshots/delete",
    ]
  }

  assignable_scopes = concat(
    [azurerm_resource_group.velero.id],
    [for cluster in local.velero_clusters : cluster.node_resource_group_id],
  )
}

resource "azurerm_role_assignment" "velero_disks" {
  for_each = local.velero_clusters

  scope              = each.value.node_resource_group_id
  role_definition_id = azurerm_role_definition.velero_disks.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.velero[each.key].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "velero_snapshots" {
  for_each = local.velero_clusters

  scope              = azurerm_resource_group.velero.id
  role_definition_id = azurerm_role_definition.velero_disks.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.velero[each.key].principal_id
  principal_type     = "ServicePrincipal"
}

output "velero" {
  description = "Non-secret settings consumed by install-velero.ps1 after terraform apply."
  value = {
    subscription_id       = data.azurerm_client_config.current.subscription_id
    tenant_id             = data.azurerm_client_config.current.tenant_id
    namespace             = local.velero_namespace
    service_account       = local.velero_service_account
    backup_resource_group = azurerm_resource_group.velero.name
    storage_account       = azurerm_storage_account.velero.name
    storage_account_uri   = azurerm_storage_account.velero.primary_blob_endpoint
    container             = azurerm_storage_container.velero.name
    clusters = {
      for key, cluster in local.velero_clusters : key => {
        name                = cluster.name
        location            = cluster.location
        resource_group      = azurerm_resource_group.rg.name
        node_resource_group = cluster.node_resource_group
        client_id           = azurerm_user_assigned_identity.velero[key].client_id
        access_mode         = key == "source" ? "ReadWrite" : "ReadOnly"
      }
    }
  }

  depends_on = [
    azurerm_federated_identity_credential.velero,
    azurerm_role_assignment.velero_blob,
    azurerm_role_assignment.velero_disks,
    azurerm_role_assignment.velero_snapshots,
    azurerm_private_endpoint.velero_blob,
    azurerm_private_dns_zone_virtual_network_link.velero_blob,
  ]
}
