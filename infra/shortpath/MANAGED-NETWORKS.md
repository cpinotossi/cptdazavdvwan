# Teil 2 – RDP Shortpath für Managed Networks via In-Guest-Policy

> Status: **nicht implementiert** (bewusste Design-Entscheidung). Die aktive Umsetzung
> in [`main.bicep`](./main.bicep) nutzt **Public Networks (STUN/TURN)** und benötigt
> daher keine In-Guest-Konfiguration. Dieses Dokument beschreibt, was nötig *wäre*,
> falls der dedizierte Host stattdessen (oder zusätzlich) Shortpath für **Managed
> Networks** anbieten soll.

## Warum Teil 2 separat ist

RDP Shortpath kennt zwei Betriebsarten mit unterschiedlichen Anforderungen:

| Shortpath-Typ | In-Guest-Config nötig | Netzwerk-Voraussetzung |
| --- | --- | --- |
| **Public networks** (STUN/TURN) | Nein – UDP/TCP sind in Windows Default | Ausgehend UDP 3478 zu `51.5.0.0/16` (Firewall-Regel `rdp-shortpath-relay` deckt das ab) |
| **Managed networks** (direkt UDP) | **Ja** – Listener auf UDP 3390 muss aktiviert werden | Direkte Sichtverbindung Client ↔ Host (VPN / ExpressRoute) |

Managed Networks setzt damit zwei Dinge voraus, die im aktuellen Lab fehlen:

1. **Direkte Sichtverbindung** vom Client zum Host (Site-to-Site/Point-to-Site VPN
   oder ExpressRoute Private Peering). Hinter vWAN + Azure Firewall + NAT ohne
   Client-VPN erreicht ein typischer Client UDP 3390 nicht direkt.
2. **Ein aktivierter UDP-Listener** auf dem Session Host (Registry-Einstellung), den
   Windows standardmäßig nicht setzt.

## Die In-Guest-Einstellung

Der Listener wird über die AVD Administrative Template-Einstellung **Enable RDP
Shortpath for managed networks** aktiviert. Technisch entspricht das diesen
Registry-Werten unter
`HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`:

| Wert | Typ | Bedeutung |
| --- | --- | --- |
| `fUseUdpPortRedirector` | `REG_DWORD` = `1` | UDP-Listener aktivieren |
| `UdpPortNumber` | `REG_DWORD` = `3390` | Listener-Port (Default 3390, frei wählbar) |

Zusätzlich muss der gewählte Port **inbound** in der Windows-Firewall und in jeder
vorgelagerten NSG/Azure-Firewall erlaubt sein.

## Umsetzungsoptionen für die In-Guest-Konfiguration

In der bevorzugten Reihenfolge für ein IaC-/Policy-getriebenes Setup:

### Option A – Azure Machine Configuration (Guest Configuration)

Der „policy-native" Weg. Setzt die Registry-Werte deklarativ und korrigiert Drift.

- **Modus** `ApplyAndAutoCorrect`: wendet die Konfiguration an und korrigiert
  Abweichungen automatisch beim nächsten Evaluierungsintervall.
- **Voraussetzungen** auf der VM: Guest-Configuration-Extension + Managed Identity.
- **Custom Package nötig**: Es gibt **keine** eingebaute Policy für die
  Shortpath-Registry. Ein eigenes Paket (`.zip`) muss mit dem PowerShell-Modul
  `GuestConfiguration` gebaut, in einen Storage-Blob geladen und über eine
  `DeployIfNotExists`-Policy + Assignment verteilt werden.
- **Bicep-Abdeckung**: Policy-Definition, -Assignment, Storage, Extension und MI
  lassen sich in Bicep ausdrücken; das Paket-`.zip` selbst wird in einem
  Build-Schritt (PowerShell) erzeugt – nicht in Bicep.

### Option B – Group Policy / Microsoft Intune

Der von Microsoft dokumentierte „Standard"-Weg über das AVD Administrative Template
(Settings Catalog in Intune bzw. GPO in einer AD-Domäne). Passt gut, wenn ohnehin
Intune-Verwaltung vorhanden ist, aber nicht rein über Bicep abbildbar.

### Option C – VM-Extension (CustomScript / DSC)

Pragmatischster Weg für ein Lab: Eine `CustomScriptExtension` setzt die zwei
Registry-Werte per PowerShell direkt beim Deployment. Vollständig in Bicep, kein
Storage/Package nötig – aber kein Drift-Schutz wie bei Option A.

## Verifikation: Ist Shortpath aktiv?

Es gibt **keinen** nativen `az`-Befehl, der „Shortpath aktiv: ja/nein" zurückgibt.
Die Verifikation erfolgt am Host bzw. zur Verbindungszeit. Im Stil dieses Repos
(`az vm run-command`) lassen sich die Host-Checks aber per CLI auslösen.

### 1. Vorab-Readiness am Host prüfen (`avdnettest.exe`)

Prüft STUN/TURN-Erreichbarkeit und NAT-Typ – sagt aus, ob Public-Networks-Shortpath
funktionieren wird. Über Run Command auf dem dedizierten Host:

```bash
RG="rg-cptdazavdvwan"
VM="vm-shortpath-cptdazavdvwan"

az vm run-command invoke \
  --resource-group "$RG" \
  --name "$VM" \
  --command-id RunPowerShellScript \
  --scripts "
    \$u='https://raw.githubusercontent.com/Azure/RDS-Templates/master/AVD-TestShortpath/avdnettest.exe'
    \$o=\"\$env:TEMP\\avdnettest.exe\"
    Invoke-WebRequest -Uri \$u -OutFile \$o -UseBasicParsing
    & \$o
  " \
  --query "value[].message" -o tsv
```

Erfolgreiche Ausgabe enthält `TURN support ... OK` und
`Shortpath for public networks is very likely to work on this host.`

### 2. UDP-Transport im Default-Zustand prüfen (Registry)

Bestätigt, dass UDP auf dem Host nicht (z. B. per GPO) deaktiviert wurde:

```bash
az vm run-command invoke \
  --resource-group "$RG" \
  --name "$VM" \
  --command-id RunPowerShellScript \
  --scripts "
    Get-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services' `
      -Name fUseUdpPortRedirector,UdpPortNumber -ErrorAction SilentlyContinue |
      Format-List fUseUdpPortRedirector,UdpPortNumber
  " \
  --query "value[].message" -o tsv
```

Fehlen die Werte, gilt der Default (UDP aktiv, kein Managed-Listener). Für Managed
Networks müssen `fUseUdpPortRedirector=1` und `UdpPortNumber=3390` gesetzt sein.

### 3. Tatsächlich genutzten Transport prüfen (nach einer Verbindung)

Nach einer aktiven Sitzung zeigt das Event-Log, ob UDP verwendet wurde. **Event ID
135** im Log `Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational`
meldet `transport type set to UDP`:

```bash
az vm run-command invoke \
  --resource-group "$RG" \
  --name "$VM" \
  --command-id RunPowerShellScript \
  --scripts "
    Get-WinEvent -LogName 'Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational' -MaxEvents 200 |
      Where-Object Id -eq 135 |
      Select-Object TimeCreated, Message -First 5 | Format-List
  " \
  --query "value[].message" -o tsv
```

### 4. Am Client (ohne CLI)

In der Verbindungsleiste der Windows App / Remote Desktop App auf das
Signalstärke-Symbol klicken → **Connection Information**. Der Transportwert zeigt:

- `UDP` – Public Networks via STUN
- `UDP (Relay)` – Public Networks via TURN
- `UDP (Private Network)` – Managed Networks

### 5. Per Log Analytics (flottenweit)

Bei aktiviertem AVD-Diagnose-Export gibt die Spalte `UdpUse` der Tabelle
`WVDConnections` Auskunft: `1` = Managed, `2` = Public/STUN, `4` = Public/TURN,
andere Werte = TCP.

## Referenzen

- [RDP Shortpath for Azure Virtual Desktop (Übersicht, Managed vs. Public)](https://learn.microsoft.com/azure/virtual-desktop/rdp-shortpath)
- [Configure RDP Shortpath – Listener für Managed Networks aktivieren](https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath#enable-the-rdp-shortpath-listener-for-rdp-shortpath-for-managed-networks)
- [Configure RDP Shortpath – Verify RDP Shortpath is working](https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath#verify-rdp-shortpath-is-working)
- [Troubleshoot RDP Shortpath for public networks (avdnettest.exe)](https://learn.microsoft.com/troubleshoot/azure/virtual-desktop/troubleshoot-rdp-shortpath)
- [Remediation options for machine configuration (ApplyAndAutoCorrect)](https://learn.microsoft.com/azure/governance/machine-configuration/concepts/remediation-options)
- [How to create custom machine configuration policy definitions](https://learn.microsoft.com/azure/governance/machine-configuration/how-to/create-policy-definition)
- [Use the administrative template for Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/administrative-template)
