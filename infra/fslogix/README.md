# FSLogix Multi-Session Host (Entra-ID-only, Private Endpoint)

Dedizierter Bicep-Stack für einen **Multi-Session-AVD-Host** mit **FSLogix-Profil-Containern** auf **Azure Files**, erreichbar **ausschließlich über einen Private Endpoint**. Authentifizierung erfolgt **cloud-only über Microsoft Entra Kerberos** (kein Active Directory Domain Services).

Dieser Stack ist bewusst vom primären AVD-Stack (`infra/main.bicep`) und vom Shortpath-Stack (`infra/shortpath/`) isoliert und folgt demselben Muster: eigener Host-Pool, eigene App-Group, eigener Workspace, eigener Workflow.

## Überblick

| Komponente | Wert |
| --- | --- |
| Storage Account | `stfsl<prefix>` (Standard_LRS, StorageV2, AADKERB) |
| File Share | `profiles` (100 GiB, SMB) |
| Public Network Access | `Disabled` (nur Private Endpoint) |
| Private Endpoint | `pe-stfsl<prefix>-file` in `snet-pe` (10.1.2.0/24) |
| Private DNS Zone | `privatelink.file.core.windows.net`, direkt mit `vnet-avd` verlinkt |
| Host Pool | `hp-fslogix-<prefix>` (Pooled, BreadthFirst, multi-session) |
| App Group / Workspace | `dag-fslogix-<prefix>` / `ws-fslogix-<prefix>` |
| Session Host | `vm-fslogix-<prefix>` (computerName `vmfsl01`) |
| Image | Windows 11 Enterprise **multi-session** + M365 (`win11-24h2-avd-m365`) |
| Identität | System-Assigned, Entra-Join (`AADLoginForWindows`) |

## Architekturentscheidungen

### Multi-Session statt Single-Session

Der Host nutzt ein **Windows 11 Enterprise multi-session** Image und einen **Pooled** Host-Pool mit `maxSessionLimit = 4`. Dadurch können sich **zwei (oder mehr) Test-User gleichzeitig auf demselben Host** anmelden — das ist die Voraussetzung, um FSLogix-Profil-Roaming sinnvoll zu testen.

### Private Endpoint only

Das Storage Account ist mit `publicNetworkAccess: 'Disabled'` und `networkAcls.defaultAction: 'Deny'` konfiguriert. Der File Share ist **aus dem öffentlichen Internet nicht erreichbar**. Der gesamte SMB-Verkehr (Port 445) läuft über den Private Endpoint und bleibt damit innerhalb des `vnet-avd`. Dieses Muster ist deckungsgleich mit dem [Azure/avdaccelerator](https://github.com/Azure/avdaccelerator) (`workload/bicep/modules/storageAzureFiles/deploy.bicep`).

### DNS-Auflösung ohne DNS Private Resolver

Dieses Projekt nutzt **keinen** DNS Private Resolver, und das Spoke-VNet `vnet-avd` hat **kein** Custom-DNS (es nutzt Azure-Default-DNS `168.63.129.16`). Die Azure Firewall hat zwar den DNS-Proxy aktiviert, liegt aber nicht im Auflösungspfad des Spokes.

Deshalb wird die Private DNS Zone `privatelink.file.core.windows.net` **direkt per VNet-Link an `vnet-avd` gekoppelt**. Der `privateDnsZoneGroup` am Private Endpoint legt den A-Record an, und das Azure-Default-DNS löst `<storage>.file.core.windows.net` automatisch auf die private IP auf. Es ist **kein** Resolver und **kein** Custom-DNS nötig.

### `snet-pe` im Basis-VNet

Das Private-Endpoint-Subnetz `snet-pe` ist in `infra/main.bicep` definiert (nicht in diesem Stack). Grund: Würde der FSLogix-Stack das Subnetz als eigenständige Ressource zum bestehenden VNet hinzufügen, würde ein erneuter Lauf von `deploy.yml` (das die Subnetz-Liste inline definiert) das Subnetz wieder entfernen. Durch die Definition im Basis-VNet ist `snet-pe` race-frei und übersteht Re-Deploys.

## Was Bicep abdeckt und was der Workflow erledigt

Microsoft Entra Kerberos für cloud-only-Identitäten benötigt Schritte, die **nicht** rein deklarativ in Bicep abbildbar sind, weil das zugehörige Entra-App-Objekt vom Storage-Resource-Provider **automatisch erst nach dem Storage-Deploy** erzeugt wird.

| Schritt | Ort |
| --- | --- |
| Storage, File Share, AADKERB aktivieren | Bicep (`main.bicep`) |
| Private DNS Zone + VNet-Link + Private Endpoint | Bicep (`main.bicep`) |
| Host Pool, App Group, Workspace, VM, Entra-Join | Bicep (`main.bicep`) |
| RBAC (`Storage File Data SMB Share Contributor`, `Desktop Virtualization User`, `VM User Login`) | Bicep (`main.bicep`) |
| Session-Host-Registrierung (DSC-Agent) | Workflow (`fslogix.yml`) |
| FSLogix-Registry + Cloud-Kerberos-Flag | Workflow (`fslogix.yml`) |
| **Admin Consent** auf die Storage-Entra-App | Workflow (`fslogix.yml`) |
| **App-Manifest-Tag** `kdc_enable_cloud_group_sids` | Workflow (`fslogix.yml`) |
| Conditional-Access-/MFA-Ausnahme | **Manuell** (siehe unten) |

### FSLogix-Registry-Konfiguration

`fslogix.yml` setzt per `az vm run-command` folgende Schlüssel auf dem Host:

- `HKLM\SOFTWARE\FSLogix\Profiles\Enabled = 1`
- `HKLM\SOFTWARE\FSLogix\Profiles\VHDLocations = \\<storage>.file.core.windows.net\profiles`
- `HKLM\SOFTWARE\FSLogix\Profiles\VolumeType = VHDX`
- `HKLM\SOFTWARE\FSLogix\Profiles\FlipFlopProfileDirectoryName = 1`
- `HKLM\SOFTWARE\FSLogix\Profiles\DeleteLocalProfileWhenVHDShouldApply = 1`
- `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters\CloudKerberosTicketRetrievalEnabled = 1`

Das letzte Flag ist für Entra Kerberos zwingend — es weist den Host an, Cloud-Kerberos-Tickets von Entra ID anzufordern.

## Option B: automatisierter Admin Consent (gewählt)

Der Admin Consent und das Manifest-Tag werden **vollautomatisch** im Workflow erteilt. Dafür benötigt die Pipeline-Service-Principal zwei zusätzliche Microsoft-Graph-App-Rollen, die einmalig out-of-band über `infra/identity/grant-pipeline-permissions.sh` (durch einen Global Admin) vergeben werden:

| Permission | Graph appRoleId | Zweck |
| --- | --- | --- |
| `Application.ReadWrite.All` | `1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9` | Manifest-Tag `kdc_enable_cloud_group_sids` patchen |
| `DelegatedPermissionGrant.ReadWrite.All` | `8e8e4742-1d95-4f68-9d56-6ee75648c72a` | `oauth2PermissionGrant` (Admin Consent) anlegen |

### Pro / Contra Option B (vollautomatisiert)

**Vorteile**

- **Vollständig reproduzierbar**: Der gesamte FSLogix-Lifecycle (inkl. Kerberos-Consent) läuft ohne manuellen Eingriff durch — passt zum IaC-Anspruch des Projekts und zur Teardown/Restore-Automatik.
- **Kein Bruch im Restore-Pfad**: Nach einem kompletten RG-Teardown stellt ein einziger Pipeline-Lauf alles wieder her, ohne dass ein Admin manuell konsentieren muss.
- **Konsistenz**: Gleiches Muster wie die bestehende Device-Cleanup- und Gruppen-Automatik (`az rest` gegen Graph).

**Nachteile / Risiken**

- **Hohe Privilegien**: `Application.ReadWrite.All` und `DelegatedPermissionGrant.ReadWrite.All` sind weitreichend. Mit ihnen kann die Pipeline **jede** App im Tenant verändern und sich selbst delegierte Berechtigungen erteilen. Das vergrößert den Blast-Radius der Pipeline-Identität erheblich.
- **Kompromittierungs-Folgen**: Wird der Pipeline-SP (OIDC-Federated-Credential auf das Repo) übernommen, sind tenant-weite App-Manipulationen möglich.
- **Governance**: Solche Berechtigungen erfordern in vielen Organisationen ein Security-Review und sind ggf. per Policy eingeschränkt.

### Alternative (nicht gewählt): Option A — least privilege

Admin Consent und Manifest-Tag einmalig manuell durch einen Global Admin setzen; die Pipeline behält nur die eng gefassten Rechte (`Group.ReadWrite.All`, `Device.ReadWrite.All`, `User Access Administrator`). Geringeres Risiko, aber ein manueller Schritt pro Storage-Konto im Restore-Pfad. Diese Variante wurde zugunsten der vollständigen Automatisierung verworfen.

## Conditional Access / MFA (manueller Schritt)

Die Kerberos-Ticket-Beschaffung passiert **still beim Logon** und kann **keine interaktive MFA** durchführen. Die Storage-Entra-App `[Storage Account] <storage>.file.core.windows.net` muss daher von Conditional-Access-/MFA-Policies **ausgenommen** werden. Das Anpassen von CA-Policies ist umgebungsspezifisch und sicherheitskritisch und wird deshalb bewusst **nicht** automatisiert. Der Workflow gibt dazu einen `notice`-Hinweis aus.

## Pro / Contra: FSLogix auf einem dedizierten Multi-Session-Host

**Vorteile**

- **Isoliertes Testen**: Profil-Roaming ohne Risiko für die produktiven Hosts; eigener Stack, eigener Workflow, unabhängig deploy- und teardownbar.
- **Echtes Multi-Session-Szenario**: Zwei User auf einem Host zeigen das tatsächliche FSLogix-Verhalten (gleichzeitiger Profilzugriff, getrennte Container).
- **Sicherheit**: Private-Endpoint-only + Deny-ACL + Entra-Kerberos (RBAC statt NTFS/Shared Key) entspricht aktuellen Best Practices.
- **Cloud-only**: Kein AD DS / keine Domain Controller nötig.

**Nachteile**

- **Laufende Kosten**: Storage Account + Azure Files (Kapazität + Transaktionen) laufen dauerhaft, zusätzlich zur VM.
- **Standard-Storage-IO**: `Standard_LRS` ist günstig, aber für viele parallele Profile weniger performant als Premium (`FileStorage`). Für einen 2-User-Test ausreichend; bei Lasttests auf Premium wechseln.
- **Profil-Bindung an den Pool**: User müssen gezielt den `ws-fslogix`-Workspace wählen; auf anderen Hosts (`vm-avd`, `vm-shortpath`) gilt das Profil nicht.
- **Entra-Kerberos-Feinheiten**: Admin Consent, Manifest-Tag und CA-Ausnahme sind zusätzliche Stolperstellen beim Troubleshooting.
- **Azure NetApp Files ist keine Alternative**: ANF unterstützt **kein** cloud-only/Entra-only FSLogix (benötigt AD DS Kerberos). Azure Files ist hier die einzige passende Wahl.

## Deployment

> Voraussetzung: Die Basis-Infrastruktur muss vorhanden sein. Nach einem Teardown zuerst `deploy.yml` (legt RG, VNet inkl. `snet-pe`, Firewall, AVD-Host an) und `members.yml` (Gruppenmitglieder) ausführen.

Einmalig (Global Admin), für Option B:

```bash
APP_ID=<AZURE_CLIENT_ID> SUBSCRIPTION_ID=<sub> PREFIX=cptdazavdvwan \
  ./infra/identity/grant-pipeline-permissions.sh
```

Restore- und Deploy-Reihenfolge:

```bash
gh workflow run deploy.yml      # Basis: RG, VNet (+ snet-pe), Firewall, AVD-Host
gh workflow run members.yml     # grp-avd-users Mitglieder (ga1, jesse)
gh workflow run fslogix.yml     # dieser Stack + Kerberos-Post-Config
```

`fslogix.yml` triggert außerdem automatisch bei Änderungen unter `infra/fslogix/**`.

## Verifikation

1. **DNS**: Auf `vm-fslogix` löst `Resolve-DnsName <storage>.file.core.windows.net` auf eine private `10.1.2.x`-Adresse auf.
2. **Share-Erreichbarkeit**: `Test-NetConnection <storage>.file.core.windows.net -Port 445` ist erfolgreich (intern, ohne Internet-Egress).
3. **Profil**: Nach Anmeldung eines Test-Users existiert unter `profiles\<sid>_<user>\` eine `Profile_*.vhdx`.
4. **Multi-Session**: Beide Test-User können sich gleichzeitig anmelden; jeder erhält seinen eigenen Container.
5. **Kerberos**: `klist` auf dem Host zeigt ein `cifs/<storage>.file.core.windows.net`-Ticket nach erfolgreichem Profilmount.
