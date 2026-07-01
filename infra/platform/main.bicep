// platform/main.bicep - cptdazavdvwan
// PLATFORM (landing-zone / connectivity) layer: shared vWAN hub, Azure Firewall
// (secured hub) and Routing Intent. This stack has NO dependency on the AVD
// workload and must be deployed FIRST. The AVD stack (infra/avd) references the
// hub created here via an `existing` lookup.
//
// Single resource group, Sweden Central. Deployed incrementally, so it can be
// split from the former monolith without recreating any live resource.

targetScope = 'resourceGroup'

@description('Azure region for the platform networking resources.')
param location string = resourceGroup().location

@description('Naming prefix.')
param prefix string = 'cptdazavdvwan'

// ---- Address Spaces ----
// avdSpokeAddr is the SOURCE range used by the firewall rules below. The spoke
// VNet itself is owned by the AVD stack; only the CIDR string is needed here.
var hubAddr = '10.0.0.0/16'
var avdSpokeAddr = '10.1.0.0/16'

// ============ Virtual WAN + Hub ============
resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: 'vwan-${prefix}'
  location: location
  properties: {
    type: 'Standard'
    allowVnetToVnetTraffic: true
    allowBranchToBranchTraffic: true
  }
}

resource vhub 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: 'vhub-${prefix}'
  location: location
  properties: {
    addressPrefix: hubAddr
    sku: 'Standard'
    virtualWan: { id: vwan.id }
  }
}

// ============ Azure Firewall Policy ============
// Required FQDNs: https://learn.microsoft.com/en-us/azure/virtual-desktop/required-fqdn-endpoint?tabs=azure
// Firewall with AVD: https://learn.microsoft.com/en-us/azure/firewall/protect-azure-virtual-desktop
resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'afwp-${prefix}'
  location: location
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Alert'
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource fwRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: fwPolicy
  name: 'rcg-allow'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-egress-https'
        priority: 1000
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'avd-service-traffic-https'
            sourceAddresses: [ avdSpokeAddr ]
            protocols: [ { protocolType: 'Https', port: 443 } ]
            targetFqdns: [
              // AVD Service Traffic (required)
              '*.wvd.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              '*.service.windows.cloud.microsoft'
              #disable-next-line no-hardcoded-env-urls
              '*.windows.cloud.microsoft'
              #disable-next-line no-hardcoded-env-urls
              '*.windows.static.microsoft'
              // Authentication
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              #disable-next-line no-hardcoded-env-urls
              '*.login.microsoftonline.com'
              '*.microsoftonline.com'
              #disable-next-line no-hardcoded-env-urls
              'login.windows.net'
              // Azure management + general Microsoft
              '*.microsoft.com'
              '*.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'management.azure.com'
              'aka.ms'
              // Monitoring
              #disable-next-line no-hardcoded-env-urls
              'gcs.prod.monitoring.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.prod.warm.ingest.monitor.core.windows.net'
              // Azure Marketplace + updates
              'catalogartifact.azureedge.net'
              '*.delivery.mp.microsoft.com'
              '*.windowsupdate.com'
              #disable-next-line no-hardcoded-env-urls
              '*.prod.do.dsp.mp.microsoft.com'
              // Storage / Blob (AVD agent download, SXS stack updates)
              #disable-next-line no-hardcoded-env-urls
              '*.blob.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.servicebus.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.core.windows.net'
              // DNS, certificates, telemetry
              '*.azure-dns.com'
              '*.azure-dns.net'
              '*.digicert.com'
              #disable-next-line no-hardcoded-env-urls
              '*.events.data.microsoft.com'
              // OneDrive, Graph
              '*.sfx.ms'
              #disable-next-line no-hardcoded-env-urls
              'graph.microsoft.com'
              // Entra ID device registration
              'enterpriseregistration.windows.net'
              '*.microsoftazuread-sso.com'
              'pas.windows.net'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-egress-http'
        priority: 1010
        action: { type: 'Allow' }
        rules: [
          {
            // Port 80 required for certificates + connectivity checks
            ruleType: 'ApplicationRule'
            name: 'avd-certificates-http'
            sourceAddresses: [ avdSpokeAddr ]
            protocols: [ { protocolType: 'Http', port: 80 } ]
            targetFqdns: [
              #disable-next-line no-hardcoded-env-urls
              'oneocsp.microsoft.com'
              'www.microsoft.com'
              '*.digicert.com'
              #disable-next-line no-hardcoded-env-urls
              '*.aikcertaia.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              'azcsprodeusaikpublish.blob.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.microsoftaik.azure.net'
              #disable-next-line no-hardcoded-env-urls
              'ctldl.windowsupdate.com'
              #disable-next-line no-hardcoded-env-urls
              'www.msftconnecttest.com'
              'ocsp.msocsp.com'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-network'
        priority: 1100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'kms'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '23.102.135.246', '20.118.99.224', '40.83.235.53' ]
            destinationPorts: [ '1688' ]
          }
          {
            // RDP Shortpath relay - required for relayed RDP connectivity
            ruleType: 'NetworkRule'
            name: 'rdp-shortpath-relay'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '51.5.0.0/16' ]
            destinationPorts: [ '3478' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'dns'
            ipProtocols: [ 'UDP', 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '168.63.129.16' ]
            destinationPorts: [ '53' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'ntp'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationFqdns: [ 'time.windows.com' ]
            destinationPorts: [ '123' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'metadata-wireserver'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '169.254.169.254', '168.63.129.16' ]
            destinationPorts: [ '80', '32526' ]
          }
        ]
      }
    ]
  }
}

// ============ Azure Firewall (Secured Hub) ============
resource fw 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'afw-${prefix}'
  location: location
  properties: {
    sku: { name: 'AZFW_Hub', tier: 'Standard' }
    hubIPAddresses: { publicIPs: { count: 1 } }
    virtualHub: { id: vhub.id }
    firewallPolicy: { id: fwPolicy.id }
  }
  dependsOn: [ fwRcg ]
}

// ============ Routing Intent ============
resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-09-01' = {
  parent: vhub
  name: 'ri-${prefix}'
  properties: {
    routingPolicies: [
      { name: 'PrivateTraffic', destinations: [ 'PrivateTraffic' ], nextHop: fw.id }
      { name: 'InternetTraffic', destinations: [ 'Internet' ], nextHop: fw.id }
    ]
  }
}

// ============ Outputs ============
// Consumed by the AVD stack (hub name for the spoke connection) and by
// validate-routing.ipynb (firewall egress IPs).
output virtualHubName string = vhub.name
output virtualHubId string = vhub.id
output firewallPrivateIp string = fw.properties.hubIPAddresses.privateIPAddress
output firewallPublicIp string = fw.properties.hubIPAddresses.publicIPs.addresses[0].address
