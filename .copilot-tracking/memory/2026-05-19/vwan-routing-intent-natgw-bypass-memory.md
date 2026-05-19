<!-- markdownlint-disable-file -->
# Memory: vwan-routing-intent-natgw-bypass

**Created:** 2026-05-19T14:00:00Z | **Last Updated:** 2026-05-19T14:00:00Z

## Task Overview

Test whether a UDR with Service Tag `WindowsVirtualDesktop` + next-hop `Internet` (NAT Gateway) can bypass Azure Firewall when vWAN Routing Intent is active. Based on team discussion in NOTES.md: Can RDP/WVD traffic exit via NAT GW while all other internet traffic goes through the firewall?

**Success Criteria:**
- Effective routes on AVD NIC show both Routing Intent routes (0/0 → FW) AND UDR routes (WVD → Internet)
- General internet traffic from VM exits via Firewall PIP
- WVD traffic exits via NAT Gateway PIP

## Current State

### Infrastructure Deployed (commit 96cb7ba)
- vWAN Standard + Secured Hub (swedencentral) with Azure Firewall Standard (DNS proxy enabled)
- Routing Intent: PrivateTraffic + InternetTraffic → Azure Firewall
- AVD Spoke VNet (10.1.0.0/16) connected to vWAN hub
- NAT Gateway with Standard PIP on `snet-avd-hosts` (10.1.1.0/24)
- UDR `rt-avd-cptdazavdvwan` with two routes:
  - `avd-wvd-direct-internet`: WindowsVirtualDesktop → Internet
  - `test-udr-more-specific`: 10.99.0.0/16 → None
- AVD Host Pool (northeurope), session host VM (swedencentral)
- Bastion on AVD VNet for management access

### Files Modified
- `/home/ga1/cptdazavdvwan/main.bicep` - Core IaC (vWAN, hub, FW, routing intent, NAT GW, UDR, AVD, VM)
- `/home/ga1/cptdazavdvwan/main.bicepparam` - Parameters with KV reference
- `/home/ga1/cptdazavdvwan/.github/workflows/deploy.yml` - CI/CD with validation steps
- `/home/ga1/cptdazavdvwan/validate-routing.ipynb` - Jupyter notebook for live testing (bash kernel)
- `/home/ga1/cptdazavdvwan/NOTES.md` - Team discussion context

### Deployment Status
- Last workflow run (26090097795) FAILED - DSC extension type name issue (fixed in 96cb7ba)
- Need to confirm next run succeeds

### Jupyter Notebook
- Created `validate-routing.ipynb` with 8 test sections
- Bash kernel installed at `~/.local/share/jupyter/kernels/bash` (via venv at `~/.local/share/jupyter-bash/`)
- Kernel must be selected manually in VS Code (tool cannot programmatically select bash kernel)

## Important Discoveries

* **Decisions:**
  - AVD control plane in northeurope (not available in swedencentral), session host VM in swedencentral
  - Removed deployment scripts due to subscription policy blocking storage shared key access
  - AVD registration moved to CLI workflow step (az desktopvirtualization hostpool retrieve-registration-token + DSC extension)
  - Service Tag UDR uses `WindowsVirtualDesktop` (not `AzureVirtualDesktop`) as that's the valid Azure service tag name

* **Failed Approaches:**
  - Deployment scripts fail with identity-based storage in this subscription (policy blocks allowSharedKeyAccess)
  - `hostPool.properties.registrationInfo.token` cannot be evaluated in same deployment
  - `configure_non_python_notebook` tool always selects Python (OCI) kernel, cannot select bash kernel programmatically

* **Key Technical Points:**
  - NAT Gateway on subnet: when UDR says next-hop "Internet", traffic goes through NAT GW (if present on subnet)
  - Service Tag routes are more specific than 0/0, so they should theoretically win over Routing Intent's default route
  - But: Routing Intent might override ALL UDRs on connected spokes — this is what we're testing

## Next Steps

1. Confirm deployment succeeds (run after DSC fix commit 96cb7ba)
2. Select Bash kernel in notebook manually (VS Code UI: kernel picker → "Bash")
3. Run notebook cells sequentially to validate:
   - Effective routes show WVD service tag routes
   - `curl ifconfig.me` from VM shows FW PIP (default route)
   - WVD endpoint connectivity works via NAT GW
   - NAT GW metrics show traffic (ByteCount > 0)
4. Document findings: Does Routing Intent allow or block NAT GW bypass for service tag UDRs?
5. If bypass doesn't work: consider alternative approaches (static routes for WVD IPs, or accept FW for all traffic)

## Context to Preserve

* **Sources:**
  - NOTES.md: Team discussion (Andreas, Christian, Claus) about WVD service tag + NAT GW bypass
  - https://learn.microsoft.com/en-us/windows-365/enterprise/connectivity-principles
  - https://learn.microsoft.com/en-us/windows-365/enterprise/optimization-of-rdp
* **Agents:** None specific
* **Questions:**
  - Does vWAN Routing Intent override service tag UDRs on spoke subnets?
  - Is there a difference between how Routing Intent handles 0/0 vs service tag routes?
  - If UDR is overridden, can we use Azure Firewall policy to allow WVD traffic without inspection?
* **Infra Details:**
  - Subscription: ff0bb075-6c44-44ee-bb64-d46ce828c62f
  - Tenant: f71980b2-590a-4de9-90d5-6fbc867da951
  - Key Vault: `cptdazavdvwan` in `rg-cptdazavdvwan` (RBAC mode)
  - GitHub Repo: github.com/cpinotossi/cptdazavdvwan (private)
  - OIDC App: federated credentials for GitHub Actions
