variable "zone_name" {
  description = "Domain name for the DNS zone (e.g. example.com)"
  type        = string
}

variable "zone_ttl" {
  description = "Default TTL for the zone"
  type        = number
  default     = 3600
}

variable "records" {
  description = "List of DNS records to create in the zone"
  type = list(object({
    name  = string
    type  = string
    value = string
    ttl   = optional(number, 300)
  }))
  default = []
}
