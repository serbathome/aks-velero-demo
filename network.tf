locals {
  aks_networks = {
    source = {
      location       = var.source_cluster_region
      address_space  = "10.10.0.0/16"
      nodes          = "10.10.0.0/20"
      endpoints      = "10.10.16.0/24"
      pod_cidr       = "10.244.0.0/16"
      service_cidr   = "10.240.0.0/16"
      dns_service_ip = "10.240.0.10"
      peer           = "destination"
    }
    destination = {
      location       = var.destination_cluster_region
      address_space  = "10.20.0.0/16"
      nodes          = "10.20.0.0/20"
      endpoints      = "10.20.16.0/24"
      pod_cidr       = "10.245.0.0/16"
      service_cidr   = "10.241.0.0/16"
      dns_service_ip = "10.241.0.10"
      peer           = "source"
    }
  }
}

resource "azurerm_resource_group" "network" {
  for_each = local.aks_networks

  # A new destination group name also recreates its children when moving regions.
  name = each.key == "destination" ? (
    "${var.resource_group_name}-${each.key}-network-${replace(lower(each.value.location), " ", "")}-${random_string.suffix.result}"
  ) : "${var.resource_group_name}-${each.key}-network-${random_string.suffix.result}"
  location = each.value.location
}

resource "azurerm_virtual_network" "aks" {
  for_each = local.aks_networks

  name                = "aks-${each.key}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.network[each.key].name
  location            = azurerm_resource_group.network[each.key].location
  address_space       = [each.value.address_space]
}

resource "azurerm_subnet" "aks" {
  for_each = local.aks_networks

  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.network[each.key].name
  virtual_network_name = azurerm_virtual_network.aks[each.key].name
  address_prefixes     = [each.value.nodes]
}

resource "azurerm_subnet" "private_endpoints" {
  for_each = local.aks_networks

  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.network[each.key].name
  virtual_network_name              = azurerm_virtual_network.aks[each.key].name
  address_prefixes                  = [each.value.endpoints]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_virtual_network_peering" "aks" {
  for_each = local.aks_networks

  name                         = "${each.key}-to-${each.value.peer}"
  resource_group_name          = azurerm_resource_group.network[each.key].name
  virtual_network_name         = azurerm_virtual_network.aks[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.aks[each.value.peer].id
  allow_virtual_network_access = true
}

# Pre-authorize the control plane to manage networking before AKS creation.
resource "azurerm_user_assigned_identity" "aks" {
  for_each = local.aks_networks

  name                = "aks-${each.key}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.network[each.key].name
  location            = azurerm_resource_group.network[each.key].location
}

resource "azurerm_role_assignment" "aks_network" {
  for_each = local.aks_networks

  scope                = azurerm_virtual_network.aks[each.key].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# Separate resource groups allow same-named zones with VNet-local endpoint records.
resource "azurerm_private_dns_zone" "velero_blob" {
  for_each = local.aks_networks

  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.network[each.key].name
}

resource "azurerm_private_dns_zone_virtual_network_link" "velero_blob" {
  for_each = local.aks_networks

  name                 = "velero-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.velero_blob[each.key].id
  virtual_network_id   = azurerm_virtual_network.aks[each.key].id
  registration_enabled = false
}

resource "azurerm_private_endpoint" "velero_blob" {
  for_each = local.aks_networks

  name                = "velero-blob-${each.key}"
  resource_group_name = azurerm_resource_group.network[each.key].name
  location            = azurerm_resource_group.network[each.key].location
  subnet_id           = azurerm_subnet.private_endpoints[each.key].id

  private_service_connection {
    name                           = "velero-blob"
    private_connection_resource_id = azurerm_storage_account.velero.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "velero-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.velero_blob[each.key].id]
  }
}
