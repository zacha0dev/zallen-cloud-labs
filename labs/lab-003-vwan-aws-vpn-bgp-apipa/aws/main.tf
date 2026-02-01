# labs/lab-003-vwan-aws-vpn-bgp-apipa/aws/main.tf
# AWS VPC + VGW + S2S VPN to Azure vWAN with BGP over APIPA

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Region validation - fail fast if region not in allowlist
resource "null_resource" "region_check" {
  count = contains(var.allowed_regions, var.aws_region) ? 0 : 1

  provisioner "local-exec" {
    command = "echo 'ERROR: Region ${var.aws_region} is not in the allowed regions: ${join(", ", var.allowed_regions)}' && exit 1"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-vpc"
  })
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-subnet-public"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-igw"
  })
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-rt-public"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Virtual Private Gateway
resource "aws_vpn_gateway" "main" {
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = var.aws_bgp_asn

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-vgw"
  })
}

# Enable route propagation from VGW to route table
resource "aws_vpn_gateway_route_propagation" "main" {
  vpn_gateway_id = aws_vpn_gateway.main.id
  route_table_id = aws_route_table.public.id
}

# Customer Gateway (representing Azure VPN Gateway IP 1)
resource "aws_customer_gateway" "azure_1" {
  bgp_asn    = var.azure_bgp_asn
  ip_address = var.azure_vpn_gateway_ip_1
  type       = "ipsec.1"

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-cgw-azure-1"
  })
}

# VPN Connection 1 (to Azure VPN Gateway IP 1)
resource "aws_vpn_connection" "vpn_1" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.azure_1.id
  type                = "ipsec.1"
  static_routes_only  = false

  # Tunnel 1 options
  tunnel1_inside_cidr   = var.tunnel1_inside_cidr
  tunnel1_preshared_key = var.psk_vpn1_tunnel1
  tunnel1_ike_versions  = ["ikev2"]

  # Tunnel 2 options
  tunnel2_inside_cidr   = var.tunnel2_inside_cidr
  tunnel2_preshared_key = var.psk_vpn1_tunnel2
  tunnel2_ike_versions  = ["ikev2"]

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-vpn-1"
  })
}

# Customer Gateway 2 for Azure VPN Gateway Instance 1 (second IP)
resource "aws_customer_gateway" "azure_2" {
  count = var.azure_vpn_gateway_ip_2 != "" ? 1 : 0

  bgp_asn    = var.azure_bgp_asn
  ip_address = var.azure_vpn_gateway_ip_2
  type       = "ipsec.1"

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-cgw-azure-2"
  })
}

# VPN Connection 2 (to Azure VPN Gateway Instance 1 via CGW 2)
# Provides Tunnel 3 and Tunnel 4 for full redundancy
resource "aws_vpn_connection" "vpn_2" {
  count = var.azure_vpn_gateway_ip_2 != "" && var.psk_vpn2_tunnel1 != "" ? 1 : 0

  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.azure_2[0].id
  type                = "ipsec.1"
  static_routes_only  = false

  # Tunnel 3 options (first tunnel of VPN Connection 2)
  tunnel1_inside_cidr   = var.tunnel3_inside_cidr
  tunnel1_preshared_key = var.psk_vpn2_tunnel1
  tunnel1_ike_versions  = ["ikev2"]

  # Tunnel 4 options (second tunnel of VPN Connection 2)
  tunnel2_inside_cidr   = var.tunnel4_inside_cidr
  tunnel2_preshared_key = var.psk_vpn2_tunnel2
  tunnel2_ike_versions  = ["ikev2"]

  tags = merge(local.all_tags, {
    Name = "${var.lab_prefix}-vpn-2"
  })
}
