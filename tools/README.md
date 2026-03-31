# Tools

Utility scripts for managing and troubleshooting Azure Labs resources.

## Prerequisites

- **Azure CLI** - [Install](https://aka.ms/installazurecli)
- **AWS CLI** - [Install](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (optional, for hybrid labs)

---

## Watch-Endpoint.ps1

Polls an endpoint repeatedly over time, building a live in-place report of DNS, TCP, TLS, and HTTP behavior. Designed for troubleshooting DNS propagation, connectivity flaps, certificate validity, and resolver differences.

**Fully standalone** -- no imports, no module dependencies, no repo helpers required. Copy the single file to any machine with PowerShell and run it directly.

### Quick Start

```powershell
# Watch DNS for a hostname (system resolver)
./tools/Watch-Endpoint.ps1 -Target "example.com" -Tests DNS

# Full suite: DNS + TCP + TLS + HTTP on port 443
./tools/Watch-Endpoint.ps1 -Target "myapp.azure.com" -Tests ALL -Ports 443

# TCP reachability to a bare IP -- no DNS lookup needed
./tools/Watch-Endpoint.ps1 -Target "10.0.1.4" -Tests TCP -Ports 22,443

# Compare two DNS resolvers side-by-side over 10 minutes
./tools/Watch-Endpoint.ps1 -Target "corp.internal" -Tests DNS `
  -DnsResolvers "10.0.0.4","168.63.129.16" -DurationMinutes 10

# Quick 2-minute HTTPS health check, fast poll
./tools/Watch-Endpoint.ps1 -Target "https://api.example.com" `
  -Tests TCP,TLS,HTTP -DurationMinutes 2 -IntervalSeconds 5

# Watch a URL with default settings (ALL tests, 5 minutes, 10s interval)
./tools/Watch-Endpoint.ps1 -Target "https://myapp.azure.com"
```

Via `lab.ps1`:

```powershell
.\lab.ps1 -Watch -WatchTarget "myapp.azure.com"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Target` | *(required)* | FQDN, IP address, or full URL |
| `-Tests` | `ALL` | `DNS`, `TCP`, `TLS`, `HTTP`, or `ALL` |
| `-Ports` | auto | TCP port(s). Defaults: 443 for TLS/HTTPS, 80 for HTTP |
| `-DurationMinutes` | `5` | How long to poll |
| `-IntervalSeconds` | `10` | Seconds between polls |
| `-DnsResolvers` | *(system)* | Explicit resolver IPs (e.g. `"8.8.8.8","10.0.0.4"`) |
| `-DnsRecordTypes` | `A` | Record types to query: `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `NS` |
| `-ConnectTimeoutMs` | `3000` | TCP/TLS connect timeout in milliseconds |

### Report Format

```
  Watch-Endpoint  |  myapp.azure.com  |  Poll 4/30  |  0m 40s
  ----------------------------------------------------------------------------
  TEST        ADDRESS/VALUE             PORT   STATUS       LATENCY  P/F
  ----------------------------------------------------------------------------
  DNS A       10.0.1.4, 10.0.1.5         --   OK              8ms   4/0
                (system resolver)
  DNS A       10.0.1.4                   --   OK             12ms   4/0
                @10.0.0.4
  TCP         10.0.1.4                  443   CONNECTED      44ms   4/0
  TLS         10.0.1.4                  443   VALID          19ms   4/0
                CN=myapp.azure.com  exp 2026-06-01  (62d left)
  HTTP        https://myapp.azure...    443   200            98ms   4/0
  ----------------------------------------------------------------------------
  Last: 14:32:40  |  Next in: 7s  |  Ctrl+C to stop
```

- **P/F** column -- cumulative pass/fail count across all polls since start
- Rows are persistent: once a row appears it stays for the session
- New IPs discovered mid-session get their own TCP/TLS rows automatically
- Report updates in-place using ANSI cursor positioning (no screen flicker)
- Each DNS resolver gets its own row for side-by-side comparison

### DNS vs. TCP/TLS separation

The tool distinguishes between:

- **DNS as a test** (`-Tests DNS`) -- shows DNS rows in the report
- **DNS for discovery** -- when target is an FQDN and TCP/TLS are requested, the tool silently resolves IPs internally even if `DNS` is not in `-Tests`

This means you can watch TCP/TLS behavior for `myapp.azure.com` without DNS rows cluttering the report, while still getting per-IP rows that appear as the DNS answer evolves.

### Standalone use (outside this repo)

Copy `Watch-Endpoint.ps1` to any machine with PowerShell 5.1 or 7. No other files needed.

```powershell
# Run from any directory
.\Watch-Endpoint.ps1 -Target "example.com" -Tests ALL
```

---

## cost-check.ps1

Audits Azure and AWS resources created by these labs to help you stay cost-aware. **Read-only** - no destructive actions.

### Quick Start

```powershell
# Basic scan (Azure only, lab resource groups)
./tools/cost-check.ps1

# Scan specific lab with AWS
./tools/cost-check.ps1 -Lab lab-003 -AwsProfile aws-labs

# Full subscription scan with AWS
./tools/cost-check.ps1 -Scope All -AwsProfile aws-labs -AwsRegion us-east-2

# Save JSON report
./tools/cost-check.ps1 -AwsProfile aws-labs -JsonOutputPath ./audit-report.json
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Scope` | `Labs` | `Labs` = scan lab RGs only; `All` = entire subscription |
| `-Lab` | (none) | Filter to specific lab (e.g., `lab-003`) |
| `-SubscriptionKey` | (from config) | Azure subscription key from `.data/subs.json` |
| `-AwsProfile` | (none) | AWS CLI profile; if not set, AWS checks are skipped |
| `-AwsRegion` | `us-east-2` | AWS region to scan |
| `-JsonOutputPath` | (none) | Path to save JSON report |

### What It Checks

**Azure (in lab resource groups `rg-lab-*`, `rg-azure-labs-*`):**
- Virtual WANs
- Virtual Hubs
- VPN Gateways
- Application Gateways
- Virtual Machines
- Public IP Addresses
- Front Door / CDN profiles
- Azure Firewalls

**AWS (tagged with `project=azure-labs`):**
- VPN Connections
- Virtual Private Gateways
- Customer Gateways
- EC2 Instances
- Elastic IPs (especially unassociated ones)
- NAT Gateways
- Load Balancers
- VPCs

### Example Output

```
Cost Audit Tool for Azure Labs
===============================

Scope: Labs
AWS Profile: aws-labs

============================================================
Azure Resource Audit
============================================================

--- Resource Groups ---

  Found 2 resource group(s):

  Resource Group                      Location        Resources  Tags
  ----------------------------------- --------------- ---------- --------------------
  rg-lab-003-vwan-aws                 centralus       12         project=azure-labs, lab=lab-003
  rg-lab-005-vwan-s2s                 westus2         8          project=azure-labs, lab=lab-005

--- High-Cost Resources in Lab RGs ---

  [WARN] Found 4 high-cost resource(s):

  Resource Group                      Resource Name             Type
  ----------------------------------- ------------------------- ---------------
  rg-lab-003-vwan-aws                 vwan-lab-003              vWAN
  rg-lab-003-vwan-aws                 vhub-lab-003              vHub
  rg-lab-003-vwan-aws                 vpngw-lab-003             VPN Gateway

============================================================
Summary
============================================================

  Azure:
    Lab resource groups: 2
    High-cost resources: 4

  AWS:
    Billable resources:  2

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ACTION REQUIRED: Billable resources detected!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  To clean up, run the destroy script for the relevant lab:

    cd C:\path\to\azure-labs\labs\lab-003-vwan-aws-bgp-apipa
    .\destroy.ps1
```

### Interpretation

- **[PASS]** - No billable resources of this type found
- **[WARN]** - Billable resources detected - consider cleanup
- **[INFO]** - Resources found but not directly billable (VPCs, Customer Gateways)

### Cleanup

When the tool detects billable resources, it suggests running the appropriate destroy script:

```powershell
# Clean up Lab 003 (Azure + AWS)
cd labs/lab-003-vwan-aws-bgp-apipa
.\destroy.ps1 -AwsProfile aws-labs

# Clean up Lab 005 (Azure only)
cd labs/lab-005-vwan-s2s-bgp-apipa
.\destroy.ps1
```

Always use the lab's destroy script rather than deleting resources manually - the scripts handle dependencies and cleanup order correctly.
