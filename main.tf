terraform {
  required_providers {
    kubernetes = "~>2.20.0"
    aws        = "~>4.47.0"
  }
}

// locals provides some aliases for commonly-used names
locals {
  hostname = "${var.subdomain}.${var.domain}"
}

resource "kubernetes_deployment" "deployment" {
  metadata {
    name = var.app_name
    labels = {
      appName = var.app_name
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 1
      }
    }

    selector {
      match_labels = {
        appName = var.app_name
      }
    }

    template {
      metadata {
        labels = {
          appName = var.app_name
        }
      }

      spec {
        container {
          name  = var.app_name
          image = var.container_image

          dynamic "env" {
              for_each = var.env_vars
              content {
                  name  = env.value["name"]
                  value = env.value["value"]
              }
          }

          resources {
            limits = {
              cpu    = var.resource_limits.cpu
              memory = var.resource_limits.memory
            }
            requests = {
              cpu    = var.resource_requests.cpu
              memory = var.resource_requests.memory
            }
          }

          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.internal_port

              dynamic "http_header" {
                for_each = var.healthcheck_headers
                iterator = header
                content {
                  name  = header.value["name"]
                  value = header.value["value"]
                }
              }

            }
            period_seconds        = 10
            initial_delay_seconds = 15
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        // We might need at least one volume to make automounting the service
        // token work
        volume {
          name = "${var.app_name}-data"
          empty_dir {}
        }

        service_account_name = var.app_name
      }
    }
  }
}

resource "aws_acm_certificate" "cert" {
  domain_name       = local.hostname
  validation_method = "DNS"
  subject_alternative_names = keys(var.cert_alternative_names)
  tags = merge(var.standard_tags, {
    Name = "Certificate for ${var.app_name}"
  })
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dv in aws_acm_certificate.cert.domain_validation_options : dv.domain_name => {
      name   = dv.resource_record_name
      record = dv.resource_record_value
      type   = dv.resource_record_type
      // For each name, we look up the corresponding zone in cert_alternative_names, 
      // or use the overall zone ID as the default if we do not find an entry.
      // Some string operations are needed to turn the validation record name back into
      // the original SAN.
      zone   = lookup(var.cert_alternative_names, 
                      trimsuffix(replace(dv.resource_record_name, "/^[^.]*[.]/", ""),"."), 
                      var.route53_zone_id)
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = each.value.zone
}

resource "aws_acm_certificate_validation" "validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}


// Load balancer which can use ACM certificates
resource "kubernetes_service" "load_balancer" {
  metadata {
    name = var.app_name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http",
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = aws_acm_certificate.cert.arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "https"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      appName = var.app_name
    }

    session_affinity = "None"
    port {
      name        = "http"
      port        = 80
      target_port = var.internal_port
    }

    port {
      name        = "https"
      port        = 443
      target_port = var.internal_port
    }
  }
}

resource "kubernetes_ingress_v1" "ingress" {
  metadata {
    name = "${var.app_name}-ingress"
    annotations = {
      "ingress.kubernetes.io/rewrite-target"   = "/",
      "kubernetes.io/ingress.class"            = "alb"
      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}, {\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/actions.ssl-redirect" = "{\"Type\": \"redirect\", \"RedirectConfig\": { \"Protocol\": \"HTTPS\", \"Port\": \"443\", \"StatusCode\": \"HTTP_301\"}}"
    }
  }

  spec {
    default_backend {
      service {
        name = var.app_name
        port {
          number = var.internal_port
        }
      }
    }

    tls {
      hosts = [local.hostname]
    }

    rule {
      http {
        path {
          path = "/*"
          backend {
            service {
              name = "ssl-redirect"
              port {
                name = "use-annotation"
              }
            }
          }
        }
      }

    }

    rule {
      host = local.hostname

      http {
        path {
          path = "/"

          backend {
            service {
              name = var.app_name
              port {
                number = var.internal_port
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_route53_record" "external_dns" {
  zone_id = var.route53_zone_id
  name    = local.hostname
  type    = "CNAME"
  ttl     = "5"
  records = [kubernetes_service.load_balancer.status[0].load_balancer[0].ingress[0].hostname]
}

resource "aws_route53_record" "internal_dns" {
  count   = var.route53_internal_zone_id!="" ? 1 : 0
  zone_id = var.route53_internal_zone_id
  name    = local.hostname
  type    = "CNAME"
  ttl     = "5"
  records = [kubernetes_service.load_balancer.status[0].load_balancer[0].ingress[0].hostname]
}

/* IAM:

See https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
for an explanation of what's going on here, but here's a summary:

We want the application to be able to access AWS resources like SecretsManager,
S3, and so on, which means it needs credentials. The application running on
Kubernetes has an identity on the Kubernetes cluster; our job is to grant that
Kubernetes identity the permission to assume an AWS IAM role.

This requires a few things:

 0. We need to register the Kubernetes cluster as an identity provider for IAM.
    This lets IAM know that our cluster exists and is reasonably trusted. Note
    that this step is _not_ done in this module, for two reasons: first, it's an
    admin action which the SCIMMA devops team doesn't have permission to do, and
    second, it's something that should be done once for the whole cluster, not
    for every application on the cluster.

 1. We need to make a Kubernetes Service Account. This will be the identity that
    the application uses on the cluster.

 2. We need to make an AWS IAM Role which we'll use to hold the permissions that
    target just the few APIs we'll permit.

 3. We need to tell AWS that we give our Kubernetes cluster permission to assume
    this role, under the condition that the assumer has the right Service
    Account.

 4. We need to attach any desired AWS IAM policies to the role we created.

*/

// Step 1: Make a service account
resource "kubernetes_service_account" "account" {
  metadata {
    name = var.app_name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.app.arn
    }
  }

  automount_service_account_token = true
}

// Step 2: Make a role
resource "aws_iam_role" "app" {
  name = "hopDev-k8s-${var.app_name}"

  assume_role_policy   = data.aws_iam_policy_document.permit_kubernetes_assume_role.json
  permissions_boundary = "arn:aws:iam::585193511743:policy/NoIAM"

  tags = var.standard_tags
}

// Step 3: Permit the cluster (which should already exist) to assume the role
data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

data "aws_caller_identity" "current" {}

locals {
  # Trim the https:// prefix from the OIDC issuer value to get an issuer
  # identifier. This is just the format that AWS expects.
  oidc_issuer_id = replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")
  oidc_arn       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_id}"
}

data "aws_iam_policy_document" "permit_kubernetes_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
  }
}

// Step 4: Attach IAM policies to the role we created.
resource "aws_iam_policy" "policy" {
  name   = "hopDev-k8s-${var.app_name}"
  policy = var.iam_policy_json
}

resource "aws_iam_role_policy_attachment" "attachment" {
  policy_arn = aws_iam_policy.policy.arn
  role       = aws_iam_role.app.name
}
