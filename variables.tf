// Required arguments:
variable "app_name" {
  description = "A name for the application. Use alphanumerics and hyphens only."
  type        = string
}

variable "subdomain" {
  description = <<EOT
Subdomain where the application should run. The 'domain' variable is suffixed
onto this to form the hostname.
EOT
  type        = string
}

variable "container_image" {
  description = <<EOT
A reference to a container image that should be run as the main application.
This image should accept HTTp traffic at port 80. An example valid value would
be 'docker.io/library/httpd:latest'.
EOT
  type        = string
}

variable "healthcheck_path" {
  description = <<EOT
HTTP path to query to make sure that the application is healthy. This should be
specified as a path, like "/health", not as a full URL.

Kubernetes will issue an HTTP GET to this address at port 80 every 10 seconds.
See the Kubernetes documentation on liveness probes for more information:
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/,
EOT
  type        = string
}

variable "standard_tags" {
  description = <<EOT
Standard tags for all SCIMMA resources.
EOT
  type = object({
    Service     = string,
    Criticality = string,
    OwnerEmail  = string,
    createdBy   = string,
    repo        = string,
    lifetime    = string
  })
}

// Required resources:
variable "iam_policy_json" {
  description = <<EOT
JSON of an IAM policy to attach to a generated IAM role which will be assumed
by the Kubernetes service that runs the application.
EOT
  type        = string
}

// Optional resources:
variable "eks_cluster_name" {
  description = "Name of the EKS cluster to run on."
  type        = string
  default     = "hopDevelEksCluster"
}

variable "route53_zone_id" {
  description = <<EOT

The ID of an external Route53 DNS zone. For most SCIMMA users, this should be
the hopZoneId from network module, which is the default. If you want to be a bit
more robust, you can load it like this:

  data "terraform_remote_state" "network" {
    backend = "s3"
    config = {
      bucket = var.stateBucketPrefix
      key    = "network"
      region = var.awsRegion
    }
  }

  locals {
    zone_id = data.terraform_remote_state.network.outputs.hopExternalDnsZoneId
  }

EOT
  default     = "Z05882683EEMG8KHBM55X"
  type        = string
}

// Optional arguments:
variable "domain" {
  description = <<EOT
Domain name where the application should run. The 'subdomain' variable is
prefixed onto this to form the hostname.
EOT
  default     = "dev.hop.scimma.org"
}

variable "resource_limits" {
  description = "Limits on how much CPU and memory should be accessible per instance of the service."
  type        = object({ cpu = string, memory = string })
  default = {
    cpu    = "0.5"
    memory = "512Mi"
  }
}

variable "resource_requests" {
  description = "Requested CPU and memory per instance of the service."
  type        = object({ cpu = string, memory = string })
  default = {
    cpu    = "0.25"
    memory = "50Mi"
  }
}
