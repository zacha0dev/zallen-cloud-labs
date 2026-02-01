# labs/lab-003-vwan-aws-vpn-bgp-apipa/aws/outputs.tf

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "igw_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "route_table_id" {
  description = "Route Table ID"
  value       = aws_route_table.public.id
}

output "vgw_id" {
  description = "Virtual Private Gateway ID"
  value       = aws_vpn_gateway.main.id
}

output "cgw_id" {
  description = "Customer Gateway ID for Azure IP 1"
  value       = aws_customer_gateway.azure_1.id
}

output "cgw_id_1" {
  description = "Customer Gateway ID for Azure IP 1 (alias)"
  value       = aws_customer_gateway.azure_1.id
}

output "cgw_id_2" {
  description = "Customer Gateway ID for Azure IP 2"
  value       = length(aws_customer_gateway.azure_2) > 0 ? aws_customer_gateway.azure_2[0].id : null
}

output "vpn_connection_id" {
  description = "VPN Connection 1 ID"
  value       = aws_vpn_connection.vpn_1.id
}

output "vpn_connection_2_id" {
  description = "VPN Connection 2 ID (for Azure Instance 1)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].id : null
}

# Tunnel outside IPs (AWS side)
output "tunnel1_outside_ip" {
  description = "AWS Tunnel 1 outside IP address"
  value       = aws_vpn_connection.vpn_1.tunnel1_address
}

output "tunnel2_outside_ip" {
  description = "AWS Tunnel 2 outside IP address"
  value       = aws_vpn_connection.vpn_1.tunnel2_address
}

# Tunnel inside IPs for BGP peering
output "tunnel1_inside_cidr" {
  description = "Tunnel 1 inside CIDR (AWS APIPA)"
  value       = aws_vpn_connection.vpn_1.tunnel1_inside_cidr
}

output "tunnel2_inside_cidr" {
  description = "Tunnel 2 inside CIDR (AWS APIPA)"
  value       = aws_vpn_connection.vpn_1.tunnel2_inside_cidr
}

output "tunnel1_bgp_peer_ip" {
  description = "Tunnel 1 BGP peer IP (Azure side)"
  value       = aws_vpn_connection.vpn_1.tunnel1_vgw_inside_address
}

output "tunnel2_bgp_peer_ip" {
  description = "Tunnel 2 BGP peer IP (Azure side)"
  value       = aws_vpn_connection.vpn_1.tunnel2_vgw_inside_address
}

output "tunnel1_cgw_inside_ip" {
  description = "Tunnel 1 CGW inside IP (AWS BGP IP)"
  value       = aws_vpn_connection.vpn_1.tunnel1_cgw_inside_address
}

output "tunnel2_cgw_inside_ip" {
  description = "Tunnel 2 CGW inside IP (AWS BGP IP)"
  value       = aws_vpn_connection.vpn_1.tunnel2_cgw_inside_address
}

# Tunnel 3 and 4 outputs (from VPN Connection 2)
output "tunnel3_outside_ip" {
  description = "AWS Tunnel 3 outside IP address"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel1_address : null
}

output "tunnel4_outside_ip" {
  description = "AWS Tunnel 4 outside IP address"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel2_address : null
}

output "tunnel3_inside_cidr" {
  description = "Tunnel 3 inside CIDR (AWS APIPA)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel1_inside_cidr : null
}

output "tunnel4_inside_cidr" {
  description = "Tunnel 4 inside CIDR (AWS APIPA)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel2_inside_cidr : null
}

output "tunnel3_bgp_peer_ip" {
  description = "Tunnel 3 BGP peer IP (Azure side)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel1_vgw_inside_address : null
}

output "tunnel4_bgp_peer_ip" {
  description = "Tunnel 4 BGP peer IP (Azure side)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel2_vgw_inside_address : null
}

output "tunnel3_cgw_inside_ip" {
  description = "Tunnel 3 CGW inside IP (AWS BGP IP)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel1_cgw_inside_address : null
}

output "tunnel4_cgw_inside_ip" {
  description = "Tunnel 4 CGW inside IP (AWS BGP IP)"
  value       = length(aws_vpn_connection.vpn_2) > 0 ? aws_vpn_connection.vpn_2[0].tunnel2_cgw_inside_address : null
}

output "aws_bgp_asn" {
  description = "AWS BGP ASN"
  value       = var.aws_bgp_asn
}

# Summary for Azure VPN Site configuration (all 4 tunnels)
output "azure_vpn_site_config" {
  description = "Configuration needed for Azure VPN Site"
  value = {
    # Tunnels 1-2: VPN Connection 1 to Azure Instance 0
    link1 = {
      name             = "link-tunnel1"
      ip_address       = aws_vpn_connection.vpn_1.tunnel1_address
      bgp_peer_address = aws_vpn_connection.vpn_1.tunnel1_cgw_inside_address
    }
    link2 = {
      name             = "link-tunnel2"
      ip_address       = aws_vpn_connection.vpn_1.tunnel2_address
      bgp_peer_address = aws_vpn_connection.vpn_1.tunnel2_cgw_inside_address
    }
    # Tunnels 3-4: VPN Connection 2 to Azure Instance 1 (if exists)
    link3 = length(aws_vpn_connection.vpn_2) > 0 ? {
      name             = "link-tunnel3"
      ip_address       = aws_vpn_connection.vpn_2[0].tunnel1_address
      bgp_peer_address = aws_vpn_connection.vpn_2[0].tunnel1_cgw_inside_address
    } : null
    link4 = length(aws_vpn_connection.vpn_2) > 0 ? {
      name             = "link-tunnel4"
      ip_address       = aws_vpn_connection.vpn_2[0].tunnel2_address
      bgp_peer_address = aws_vpn_connection.vpn_2[0].tunnel2_cgw_inside_address
    } : null
    bgp_asn = var.aws_bgp_asn
  }
}
