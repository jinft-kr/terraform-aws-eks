##########################################
### Terraform Config
##########################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }

  backend "s3" {
    bucket = "jinlee-tf-state"
    key    = "terraform.tfstate"
    region = "us-west-1"
  }
}

##########################################
### Provider
##########################################
provider "aws" {
  region = var.default_region
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

data "aws_availability_zones" "available" {
}

##########################################
### VPC
##########################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"

  # VPC
  name                 = "${local.cluster_name}-vpc"
  cidr                 = local.cidr

  # Subnet
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = local.private_subnets
  public_subnets       = local.public_subnets

  # NAT Gateway
  enable_nat_gateway   = true
  single_nat_gateway   = true

  enable_dns_hostnames = true

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

##########################################
### EKS
##########################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name    = "${local.cluster_name}"
  cluster_version = "1.30"

  vpc_id = module.vpc.vpc_id
  #  subnet_ids = module.vpc.private_subnets
  subnet_ids = flatten([module.vpc.private_subnets, module.vpc.public_subnets])

  eks_managed_node_groups = {
    node1 = {
      name = "node1"
      instance_type = "t2.samll"
      min_size = 1
      max_size = 2
      desired_capacity = 1
    }
  }

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access = true
  cluster_endpoint_public_access_cidrs = [
    "0.0.0.0/0"
  ]

  access_entries = {
    # One access entry with a policy associated
    jinlee = {
      principal_arn = "arn:aws:iam::144761725601:user/leejinlee"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    admin = {
      principal_arn = var.user_rone_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  depends_on = [
    module.vpc
  ]
}
##########################################
### AWS Application Load Balancer
##########################################
resource "aws_lb" "app_lb" {
  name               = "${local.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.vpc.default_security_group_id]
  subnets            = module.vpc.public_subnets
  enable_deletion_protection = false

  tags = {
    Name = "${local.cluster_name}-lb"
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Service Unavailable"
      status_code  = "503"
    }
  }
}

module "lb_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${local.cluster_name}_eks_lb"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

##########################################
### Provider
##########################################
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
  alias = "eks"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
  alias = "eks"
}
##########################################
### AWS Load Balancer Controller
##########################################
resource "helm_release" "aws_load_balancer_controller" {
  provider   = helm.eks
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  depends_on = [
    module.lb_role,
    kubernetes_service_account.alb_controller,
    aws_lb.app_lb
  ]
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.lb_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
  depends_on = [
    module.lb_role
  ]
}
##########################################
### K8s Deployment, Service, Ingress
##########################################
resource "kubernetes_ingress_v1" "nginx" {
  depends_on = [
    aws_lb.app_lb,
    module.eks
  ]

  metadata {
    name      = local.k8s.app.nginx.name
    namespace = local.k8s.app.nginx.namespace
    annotations = {
      "kubernetes.io/ingress.class" = "alb"
      "alb.ingress.kubernetes.io/scheme"     = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "alb.ingress.kubernetes.io/group.name" = local.k8s.app.nginx.name
      "alb.ingress.kubernetes.io/load-balancer-arn" = aws_lb.app_lb.arn
    }
  }

  spec {
    rule {
      http {
        path {
          path = "/"
          backend {
            service {
              name =  local.k8s.app.nginx.name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginx" {
  depends_on = [ module.eks ]
  metadata {
    name      =  local.k8s.app.nginx.name
    namespace =  local.k8s.app.nginx.namespace
  }

  spec {
    selector = {
      app =  local.k8s.app.nginx.name
    }

    port {
      port        = local.k8s.app.nginx.port
      target_port = local.k8s.app.nginx.port
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "nginx" {
  depends_on = [ module.eks ]

  metadata {
    name      =  local.k8s.app.nginx.name
    namespace =  local.k8s.app.nginx.namespace
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app =  local.k8s.app.nginx.name
      }
    }

    template {
      metadata {
        labels = {
          app =  local.k8s.app.nginx.name
        }
      }

      spec {
        container {
          name  =  local.k8s.app.nginx.name
          image = "nginx:latest"

          port {
            container_port =  local.k8s.app.nginx.port
          }
        }
      }
    }
  }
}