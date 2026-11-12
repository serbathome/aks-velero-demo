
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group_name}-${random_string.suffix.result}"
  location = "East US"
}

