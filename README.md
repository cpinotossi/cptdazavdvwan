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

Single resource-group deployment. The VM admin password is set directly in
`infra/main.bicepparam` (cleartext, by design — VMs have no public IP, access via Bastion only).

### Via GitHub Actions

Push to `main` or trigger manually. Required secrets:

| Secret | Description |
|---|---|
| AZURE_CLIENT_ID | Service principal (federated) |
| AZURE_TENANT_ID | Entra ID tenant |
| AZURE_SUBSCRIPTION_ID | Target subscription |

### Manual

```bash
export LOCATION=swedencentral
export PREFIX=cptdazavdvwan
export ADMIN_USERNAME=chpinoto
export AZURE_SUBSCRIPTION_ID=<your-sub-id>

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az group create -n rg-$PREFIX -l $LOCATION
az deployment group create -g rg-$PREFIX \
  -f infra/main.bicep -p infra/main.bicepparam
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
