# cptdazavdvwan

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

### Via GitHub Actions

Push to `main` or trigger manually. Required secrets:

| Secret | Description |
|---|---|
| AZURE_CLIENT_ID | Service principal (federated) |
| AZURE_TENANT_ID | Entra ID tenant |
| AZURE_SUBSCRIPTION_ID | Target subscription |
| KV_RG | Key Vault resource group |
| KV_NAME | Key Vault name (must have `vm-admin-password` secret) |

### Manual

```bash
export LOCATION=swedencentral
export PREFIX=cptdazavdvwan
export ADMIN_USERNAME=chpinoto
export AZURE_SUBSCRIPTION_ID=<your-sub-id>
export KV_RG=<your-kv-rg>
export KV_NAME=<your-kv-name>

az group create -n rg-$PREFIX -l $LOCATION
az deployment group create -g rg-$PREFIX -f main.bicep -p main.bicepparam
```

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
