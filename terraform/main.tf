
terraform {
  backend "s3" {
    bucket         = "gobuff-app-terraform"
    key            = "terraform.tfstate"
  }
}

data "aws_eks_cluster" "default" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "default" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.default.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.default.id]
    command     = "aws"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "4.0.2"

  name = "webapp-vpc"
  cidr = "10.0.0.0/16"

  azs              = ["us-east-1a", "us-east-1b"]
  private_subnets  = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets   = ["10.0.64.0/19", "10.0.96.0/19"]
  database_subnets = ["10.0.128.0/19", "10.0.160.0/19"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = true

  tags = {
    Environment = "webapp"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.29.0"

  cluster_name    = "eks-webapp"
  cluster_version = "1.23"

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    general = {
      desired_size = 1
      min_size     = 1
      max_size     = 1

      instance_types = ["t3a.medium"]
      capacity_type  = "ON_DEMAND"
    }

    tags = {
      Environment = "webapp"
    }
  }
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "postgres-sg"
  description = "Replica PostgreSQL example security group"
  vpc_id      = module.vpc.vpc_id


  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

}

module "psql" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "gobuff-psql"

  engine               = "postgres"
  engine_version       = "14"
  family               = "postgres14" # DB parameter group
  major_engine_version = "14"         # DB option group
  instance_class       = "db.t2.small"

  allocated_storage     = 20
  max_allocated_storage = 30

  db_name  = "gobuff_db"
  username = "postgres_user"
  port     = 5432


  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [module.security_group.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  backup_retention_period = 1
  skip_final_snapshot     = false
  deletion_protection     = false
  storage_encrypted       = false

}

module "load_balancer_controller_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

}

module "alb-ingress-controller" {
  source  = "campaand/alb-ingress-controller/aws"
  version = "2.0.0"
  cluster_name = "eks-webapp"
  namespace = "alb-ingress"
  helm_chart_version = "1.6.1"
}