terraform {
  required_providers {
    kubernetes = ">0.0.0"
    aws        = ">0.0.0"
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
          env {
            name  = "SCIMMA_ADMIN_PROD"
            value = "True"
          }

          resources {
            limits {
              cpu    = var.resource_limits.cpu
              memory = var.resource_limits.memory
            }
            requests {
              cpu    = var.resource_requests.cpu
              memory = var.resource_requests.memory
            }
          }

          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = 80

            }
            period_seconds        = 10
            initial_delay_seconds = 15
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
        service_account_name = var.app_name
      }
    }
  }
}

resource "aws_acm_certificate" "cert" {
  domain_name       = local.hostname
  validation_method = "DNS"
  tags = merge(var.standard_tags, {
    Name = "Certificate for ${var.app_name}"
  })
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  name    = aws_acm_certificate.cert.domain_validation_options.0.resource_record_name
  type    = aws_acm_certificate.cert.domain_validation_options.0.resource_record_type
  zone_id = var.route53_zone_id
  records = [aws_acm_certificate.cert.domain_validation_options.0.resource_record_value]
  ttl     = "60"
}

resource "aws_acm_certificate_validation" "validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
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
      target_port = 80
    }

    port {
      name        = "https"
      port        = 443
      target_port = 80
    }
  }
}

resource "kubernetes_ingress" "ingress" {
  metadata {
    name = "${var.app_name}-ingress"
    annotations = {
      "ingress.kubernetes.io/rewrite-target" = "/",
      "kubernetes.io/ingress.class"          = "alb"
      "alb.ingress.kubernetes.io/scheme"     = "internet-facing"
    }
  }

  spec {
    backend {
      service_name = var.app_name
      service_port = 80
    }

    tls {
      hosts = [local.hostname]
    }

    rule {
      host = local.hostname

      http {
        path {
          path = "/"

          backend {
            service_name = var.app_name
            service_port = 80
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
  records = kubernetes_service.load_balancer.load_balancer_ingress[*].hostname
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

  automount_service_account_token = "true"
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

locals {
  # Trim the https:// prefix from the OIDC issuer value to get an issuer
  # identifier. This is just the format that AWS expects.
  oidc_issuer_id = replace(data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer, "https://", "")

}

data "aws_iam_policy_document" "permit_kubernetes_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_issuer_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_id}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }
  }
}

// Step 4: Attach IAM policies to the role we created.
resource "aws_iam_policy" "policy" {
  name   = "hopDev-${var.app_name}-k8s"
  policy = var.iam_policy_json
}

resource "aws_iam_role_policy_attachment" "attachment" {
  policy_arn = aws_iam_policy.policy.arn
  role       = aws_iam_role.app.name
}
