variable "location" {
  description = "The location for the resources"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "source_cluster_region" {
  description = "The region of the source cluster"
  type        = string
}

variable "destination_cluster_region" {
  description = "The region of the destination cluster"
  type        = string
}

variable "source_cluster_name" {
  description = "The name of the source cluster"
  type        = string
}

variable "destination_cluster_name" {
  description = "The name of the destination cluster"
  type        = string
}

variable "vm_size" {
  description = "The default VM size for cluster nodes; destination_vm_size can override the destination"
  type        = string
}

variable "destination_vm_size" {
  description = "The destination cluster node VM size; defaults to vm_size when unset"
  type        = string
  default     = null
}

variable "node_count" {
  description = "The number of nodes in the default node pool"
  type        = number
}
