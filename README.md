---
title: cptdazavdvwan
description: Deploy and validate an Azure Virtual WAN and Azure Virtual Desktop routing lab.
---

Test: Can a UDR on an AVD spoke subnet be effective when vWAN Routing Intent is enabled?

## Architecture

```text
┌──────────────────────────────────────┐
│       vWAN Hub (10.0.0.0/16)         │
│  ┌────────────────────────────────┐  │
│  │ Azure Firewall (Secured Hub)   │  │
│  └──────────────┬─────────────────┘  │
│     Routing Intent (Priv + Inet)     │
├─────────────────┼────────────────────┤
│                 │                    │
│    ┌────────────▼───────────┐        │
│    │  AVD Spoke 10.1.0.0/16 │        │
│    │  snet-avd  10.1.1.0/24 │        │
│    │  + UDR (rt-avd)        │        │
│    │  + AVD Session Host    │        │
│    │  + Bastion             │        │
│    └────────────────────────┘        │
└──────────────────────────────────────┘
```

## What Gets Tested

Routing Intent injects `10.0.0.0/8` → Azure FW into the spoke.
The UDR adds `10.99.0.0/16` → None (drop).

Check effective routes on the AVD NIC to verify the more-specific UDR wins.

## Deploy

Deploy the platform first, then the AVD workload into the same resource group.
The VM admin password is supplied through `VM_ADMIN_PASSWORD`, never through source control.
Firewall, vWAN, Bastion, NAT Gateway and the VM incur ongoing charges.

### Via GitHub Actions

Run **Deploy Platform (vWAN + Firewall)**, wait for success, then run
**Deploy AVD Workload**. Each workflow also runs when its own files change on
`main`; when changing both stacks, deploy the platform before the workload.

The platform firewall includes a dedicated Application Rule Collection,
`allow-ifconfig-egress` (priority 1020), allowing the AVD spoke (`10.1.0.0/16`)
to reach `ifconfig.io` over HTTP (80) and HTTPS (443) for public egress IP checks.

Required repository secrets:

| Secret | Description |
|---|---|
| AZURE_CLIENT_ID | Client ID of the GitHub-federated managed identity |
| AZURE_TENANT_ID | Entra ID tenant |
| AZURE_SUBSCRIPTION_ID | Target subscription |
| VM_ADMIN_PASSWORD | Randomly generated VM administrator password |

Repository variables:

| Variable | Default | Description |
|---|---|---|
| AZURE_LOCATION | swedencentral | Networking and VM region |
| AVD_VM_SIZE | Standard_D2s_v5 | VM size with available regional quota |
| AVD_COMPUTER_NAME | vmavd01 | Windows name, unique in the tenant, at most 15 characters |
| AVD_USER_GROUP_OBJECT_ID | Empty | Existing AVD security group; skips Graph group creation when set |

The current target is subscription `a0844269-41ae-442c-8277-415f1283d422`,
with networking and the VM in `polandcentral`, VM size `Standard_D2s_v6`,
and Windows computer name `avd-sub2-01`. The AVD control plane remains in
`northeurope`. Existing members of the configured AVD group receive access.

The managed identity `id-github-cptdazavdvwan` resides in
`rg-cptdazavdvwan-identity`, separate from the disposable workload group.
Its OIDC credential trusts only `repo:cpinotossi/cptdazavdvwan:ref:refs/heads/main`.
It has Contributor and Role Based Access Control Administrator on
`rg-cptdazavdvwan`, not on the subscription. With an existing AVD group it
needs no Microsoft Graph application permissions. Optional identity, membership,
device-cleanup and FSLogix workflows may require additional permissions and are
not enabled by this setup.

### Direct Stream Shortpath test host

Run **Deploy RDP Shortpath Session Host** to provision a separate test host,
host pool, application group and workspace in the existing AVD spoke.
The workflow reuses `AZURE_LOCATION`, `AVD_VM_SIZE`, `AVD_USER_GROUP_OBJECT_ID`
and the `VM_ADMIN_PASSWORD` secret. `SHORTPATH_COMPUTER_NAME` optionally
overrides the separate Windows name `vmsp01`; do not reuse the primary host name.
This additional VM and its disk incur charges.

Use the native Windows App to connect to `ws-shortpath-cptdazavdvwan`.
Browser connections do not support Shortpath. For Direct Stream Multipath with
UDP and redundant TCP paths, use Windows App for Windows 2.0.1069.0 or later.
Direct Stream is the new name of the existing streaming stack, not a separate
feature switch.

Run [analyze-shortpath.ipynb](analyze-shortpath.ipynb), initialize its variables
before connecting, then check `UDP` or `UDP (Relay)` and Multipath in the client
connection information. The notebook targets the current lab subscription and
group by default; override them with `AZURE_SUBSCRIPTION_ID` and
`AVD_USER_GROUP_OBJECT_ID` for another environment. Historical notebook outputs
are cleared; only a new test establishes the current transport.

Public Shortpath uses the default host-pool UDP options. The fixed managed
listener on UDP 3390 remains disabled. The `WindowsVirtualDesktop` UDR currently
sends `51.5.0.0/16` via NAT Gateway, bypassing Azure Firewall; the relay allow rule
only applies when that traffic traverses the firewall. Other direct UDP paths
must satisfy their own routing and firewall requirements.

### Manual deployment

```bash
export LOCATION=polandcentral
export PREFIX=cptdazavdvwan
export ADMIN_USERNAME=chpinoto
export AZURE_SUBSCRIPTION_ID=a0844269-41ae-442c-8277-415f1283d422
export AVD_VM_SIZE=Standard_D2s_v6
export AVD_COMPUTER_NAME=avd-sub2-01
export AVD_USER_GROUP_OBJECT_ID=23b3a9fd-22f3-461c-9dc8-7f3183e87d02
read -rsp 'VM administrator password: ' VM_ADMIN_PASSWORD
echo
export VM_ADMIN_PASSWORD

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az group create -n rg-$PREFIX -l $LOCATION
az deployment group create -g rg-$PREFIX \
  -n platform -f infra/platform/main.bicep -p infra/platform/main.bicepparam
az deployment group create -g rg-$PREFIX \
  -n avd -f infra/avd/main.bicep -p infra/avd/main.bicepparam
unset VM_ADMIN_PASSWORD
```

For a manual deployment, also register the session host using the DSC extension
steps in [.github/workflows/deploy.yml](.github/workflows/deploy.yml).
The AVD workflow performs registration and routing checks automatically.

## Validate

```bash
az network nic show-effective-route-table \
  -g rg-cptdazavdvwan \
  -n nic-avd-cptdazavdvwan \
  -o table
```

Expected: Both vWAN-injected routes (10.0.0.0/8 → FW) and UDR routes (10.99.0.0/16 → None) appear.

## Cleanup

```bash
az group delete -n rg-cptdazavdvwan --yes --no-wait
```

The separate identity group and tenant-wide Entra groups remain intact.
Before redeploying a deleted VM, remove only its stale Entra device registration
(`avd-sub2-01` for this target), or choose a new `AVD_COMPUTER_NAME`. The legacy
teardown/device-cleanup workflows use hardcoded device names and must not be used
to clean up a different environment.
