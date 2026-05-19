
- Christian
AVD und vWAN mit Routing Intent für private und public traffic.
FRAGE: Gibt es eine Empfehlung wie man AVD Traffic im Kontext von vWAN mit Routing Intent korrekt konfiguriert?
 
Hintergrund:
Mir geht es nicht darum die korrekten IPs und FQDN in den Firewall Rules zu hinterlegen. Mir geht es um den Datapath. Folgende Darstellung zeigt das man AVD via Firewall betreiben kann:
 
(Use Azure Firewall to protect Azure Virtual Desktop | Microsoft Learn)
 
Was jedoch dort nicht betrachtet wird ist die Network Latency. Wie Sinnvoll ist es den gesamten Traffic der User Session über die Firewall zu senden, sprich auch den RDP Traffic.
NOTE: Mein Verständnis ist das wir hier durch die Nutzung von Routing Intent die Vorteile des hochverteilten AVD Gateway (via FrontDoor) nicht mehr nutzen. Das kann die Performance bei einer global verteilten Audience negative beeinflussen.  
 
Folgendes Slide verwendet ein NAT Gateway um den RDP Traffic gesondert zu behandeln: 
 
Inside Windows Cloud - Default outbound access.pptx
Ich denke jedoch das vWAN Routing Intent die Nutzung von NAT Gateway nicht erlauben wird. 
NOTE: Habe es selber noch nicht getested, denke aber das die Firewall im vWAN Hub über Routing Intent den Internet Traffic an sich ziehen wird.

Ich muss meine Aussage "die Nutzung des hochverteilten AVD Gateway" etwas revidieren. 
Habe mir nochmals folgenden Link angesehen: https://learn.microsoft.com/en-us/azure/virtual-desktop/service-architecture-resilience#rdp-connection
Dort erkennt man das AFD und Gateway hier wahrscheinlich nicht negative durch vWAN Secure Hub und Routing Intent beinflusst werden. 
Dementsprechend bleibt einzig die Frage ob wir den RDP Traffic bei vWAN Secure Hub mit Routing Intent via der Firewall senden und falls ja ob das auch unserer Empfehlung entspricht.

- Andreas
wo seht ihr das Problem mit vWAN. Ihr habt ein Peering mit einem VNet in dem AVD liegt. In dem ist der NAT Gateway und eine UDR. Damit sollte doch auch im vWAN das Routing passen. Er hat eine more specific route für AVD über das NAT Gateway wenn sich der Host in dem VNet befindet.
 
- Christian
Das währe für mich ok, das Problem ist nur das der gesamte Internet Traffic ungefiltert ins internet geht. Wir (
Andreas Weber und ich) hatten uns dazu bereits in der Vergangenheit im Kontext des Continental dazu ausgetauscht und die Antwort auf diese Anforderung war das man auf dem Session Host direkt die Traffic Inspection durchführt.
Das DERTour Team würde aber gerne den Traffic über die Firewall senden. 
 
FRAGE:
Andreas Weber hast du einen Kunden der VWAN Secure Hub + Routing Intent + UDR + NAT Gateway verwendet + Windows Firewall verwendet? 

- Andreas
Hallo, nein ich habe keinen Kunden mit der Konfiguration
 
zu dem gesamten Internet Traffic direkt, Configure doch nur eine UDR für den Service Tag WVD. Dann bleibt das Default Routing zum Secure Hub bestehen. 

- claus
zu dem Thema empfehle ich dringend die gesamte Doku zu Networking zu lesen die wir hier haben:
Connectivity Principles | Microsoft Learn
 
Insbesonderefür den RDP Traffic empfehlen wir ihn nicht via einer FW zu schicken.
hier ist es auch nochmal am Beispiel von ANC bei W365 erklärt, was man auch auf AVD übertrag kann Optimization of RDP Traffic | Microsoft Learn
 
- https://learn.microsoft.com/en-us/windows-365/enterprise/connectivity-principles
- https://learn.microsoft.com/en-us/windows-365/enterprise/optimization-of-rdp#azure-network-connection-anc-deployments

 
 