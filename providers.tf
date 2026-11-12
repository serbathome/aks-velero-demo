terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
  }
}

provider "azurerm" {
  # Configuration options
  features {
  }
  subscription_id     = "b03d3f08-d9c3-4eeb-b007-da276d9080e3"
  storage_use_azuread = true
}

provider "random" {
  # Configuration options
}
