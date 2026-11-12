
resource "azurerm_kubernetes_cluster" "source_cluster" {
  name                      = "${var.source_cluster_name}-${random_string.suffix.result}"
  dns_prefix                = "${var.source_cluster_name}-${random_string.suffix.result}"
  location                  = var.source_cluster_region
  resource_group_name       = azurerm_resource_group.rg.name
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.vm_size
    vnet_subnet_id = azurerm_subnet.aks["source"].id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = local.aks_networks.source.pod_cidr
    service_cidr        = local.aks_networks.source.service_cidr
    dns_service_ip      = local.aks_networks.source.dns_service_ip
    load_balancer_sku   = "standard"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks["source"].id]
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  depends_on = [azurerm_role_assignment.aks_network["source"]]
}

resource "azurerm_kubernetes_cluster" "destination_cluster" {
  name                      = "${var.destination_cluster_name}-${random_string.suffix.result}"
  dns_prefix                = "${var.destination_cluster_name}-${random_string.suffix.result}"
  location                  = var.destination_cluster_region
  resource_group_name       = azurerm_resource_group.rg.name
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = coalesce(var.destination_vm_size, var.vm_size)
    vnet_subnet_id = azurerm_subnet.aks["destination"].id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = local.aks_networks.destination.pod_cidr
    service_cidr        = local.aks_networks.destination.service_cidr
    dns_service_ip      = local.aks_networks.destination.dns_service_ip
    load_balancer_sku   = "standard"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks["destination"].id]
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  depends_on = [azurerm_role_assignment.aks_network["destination"]]
}