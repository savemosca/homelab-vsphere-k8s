# Espansione Subnet da /27 a /26

**Stato:** ✅ Migrazione completata - La rete è già configurata a `192.168.11.128/26`

Questa guida documenta l'espansione della subnet di srv26 da `192.168.11.128/27` a `192.168.11.128/26` per supportare più VM Kubernetes.

## Architettura di Rete Consigliata per Produzione

### Panoramica

La rete management attuale `192.168.11.128/27` (30 IP utilizzabili) è un buon punto di partenza ma risulta limitante per un cluster con autoscaling. Per un'architettura robusta e scalabile, si consiglia di implementare **3 reti separate** con sizing adeguato:

1. **Management Network** - Control plane e infrastruttura
2. **Workload Network** - Worker nodes e autoscaling
3. **Services Network** - LoadBalancer e servizi esposti

### Design Reti Consigliato

#### Rete 1: Management (espansione della rete esistente)

**Subnet:** `192.168.11.128/26` (62 IP utilizzabili) invece di `/27`

**Componenti:**
- vCenter (se accessibile nella subnet)
- Management cluster K3s + CAPV controller (1-2 VM)
- Kubernetes control plane (1-3 VM per HA)
- Jump host/bastion (opzionale)

**IP Reservation:** ~10-15 IP, con spazio per eventuali control plane scale-out

**Naming consigliato:** `k8s-management` o `k8s-control-plane`

#### Rete 2: Workload (nuova, per worker nodes)

**Subnet:** `192.168.12.0/24` (254 IP utilizzabili)

**Componenti:**
- Worker nodes fissi (2-3 VM iniziali)
- Worker effimeri Flatcar autoscalati da CAPV (fino a 10-15 VM)
- DHCP o IP pool per provisioning automatico

**IP Reservation:** 20-30 IP per autoscaling headroom

**Naming consigliato:** `k8s-workload` o `k8s-worker-nodes`

#### Rete 3: Services (nuova, per servizi esposti)

**Subnet:** `192.168.13.0/25` (126 IP utilizzabili)

**Componenti:**
- MetalLB LoadBalancer IP pool (es. `192.168.13.100-192.168.13.150`)
- Ingress controller external IPs
- Servizi homelab esposti (Pihole DNS, Plex se in K8s)

**Routing:** Accessibile da LAN principale per i client

**Naming consigliato:** `k8s-services` o `k8s-loadbalancer`

### Separazione Traffico Kubernetes Interno

Oltre alle reti vSphere fisiche, Kubernetes utilizza subnet interne overlay che **non consumano IP vSphere**:

- **Pod Network (Cilium/Calico):** `10.244.0.0/16` (default, gestito da CNI)
- **Service Network (ClusterIP):** `10.96.0.0/12` (interno al cluster)

Queste reti sono logiche e non hanno impatto sulle reti fisiche vSphere.

### Vantaggi Architettura 3 Reti

✅ **Sicurezza**: Control plane isolato, workload segregato, servizi controllati via firewall  
✅ **Scalabilità**: `/24` workload supporta 50+ nodi autoscalati senza IP exhaustion  
✅ **Performance**: QoS/VLAN separate per traffico management vs data plane  
✅ **Troubleshooting**: Packet capture e monitoring per rete semplificati  
✅ **Flessibilità**: Possibilità di applicare policy di rete diverse per ogni tier

### Implementazione Graduale

Per homelab o ambienti iniziali, è possibile implementare gradualmente:

1. **Fase 1** (questo documento): Espansione management da `/27` a `/26`
2. **Fase 2** (futuro): Aggiunta workload network `/24` per worker nodes
3. **Fase 3** (futuro): Aggiunta services network `/25` per LoadBalancer/Ingress

> **Nota**: La guida seguente si concentra sulla Fase 1 (espansione management network), che è il prerequisito per le fasi successive.

## Analisi Subnet

### Configurazione Precedente (192.168.11.128/27)
```
Network:        192.168.11.128/27
Netmask:        255.255.255.224
Range IP:       192.168.11.128 - 192.168.11.159
Broadcast:      192.168.11.159
Gateway:        192.168.11.129
Indirizzi utilizzabili: 30 (128-158, esclusi network/broadcast)
```

**IP attualmente configurati:**
- `192.168.11.129` - Gateway
- `192.168.11.130` - srv26.mosca.lan (questo server)
- `192.168.11.66` - DNS 1
- `192.168.11.67` - DNS 2 (fuori range attuale!)

### Configurazione Attuale (192.168.11.128/26)
```
Network:        192.168.11.128/26
Netmask:        255.255.255.192
Range IP:       192.168.11.128 - 192.168.11.191
Broadcast:      192.168.11.191
Gateway:        192.168.11.129 (stesso)
Indirizzi utilizzabili: 62 (128-190, esclusi network/broadcast)
```

**Benefici:**
- Raddoppia gli indirizzi disponibili: da 30 a 62 IP
- Mantiene gli IP esistenti (tutto rimane compatibile)
- Spazio sufficiente per cluster Kubernetes con autoscaling
- Include gli IP DNS che prima erano fuori range

## Prerequisiti e Considerazioni

### ⚠️ Impatto Infrastruttura

Questa modifica richiede cambiamenti su:

1. **Gateway/Router (192.168.11.129)**
   - Aggiornare la subnet mask da `/27` a `/26`
   - Aggiornare eventuali regole firewall
   - Verificare routing verso altre subnet

2. **Switch/VLAN vSphere**
   - Verificare che il port group vSphere sia configurato correttamente
   - Non dovrebbero essere necessari cambiamenti se VLAN/switch sono L2

3. **DHCP Server** (se presente)
   - Aggiornare pool DHCP per nuovo range
   - Evitare conflitti con IP statici

4. **DNS Servers (192.168.11.66, 192.168.11.67)**
   - Sono già nel nuovo range (/26 include 192.168.11.66-67)
   - Potrebbero richiedere aggiornamento se hanno subnet configurate

5. **Altri Server nella Subnet**
   - Identificare tutti i dispositivi in 192.168.11.128-159
   - Pianificare aggiornamento della netmask su ognuno

### IP Allocation Plan

```
192.168.11.128      - Network address
192.168.11.129      - Gateway (esistente)
192.168.11.130      - srv26.mosca.lan (esistente)
192.168.11.131-139  - Reserved for infrastructure
192.168.11.140-180  - Kubernetes cluster VMs (CAPV pool)
192.168.11.181-190  - Reserved for future use
192.168.11.191      - Broadcast address
```

## Piano di Migrazione (Completato)

> **Nota:** Questa sezione documenta i passaggi già eseguiti per la migrazione. Manteniamo la documentazione come riferimento storico e per eventuali rollback.

### Fase 1: Preparazione (No Downtime)

#### 1.1 Backup Configurazione Attuale

```bash
# Backup configurazione rete srv26
ssh administrator@srv26.mosca.lan "sudo nmcli connection show ens33 > ~/network-backup-$(date +%Y%m%d-%H%M).txt"

# Backup K3s kubeconfig (in caso di problemi di rete)
ssh administrator@srv26.mosca.lan "sudo cp /etc/rancher/k3s/k3s.yaml ~/k3s-kubeconfig-backup-$(date +%Y%m%d-%H%M).yaml"

# Backup completo NetworkManager
ssh administrator@srv26.mosca.lan "sudo cp /etc/NetworkManager/system-connections/ens33.nmconnection ~/ens33.nmconnection.backup-$(date +%Y%m%d-%H%M)"
```

#### 1.2 Verificare Altri Device sulla Subnet

```bash
# Scan della subnet attuale per identificare tutti i device
nmap -sn 192.168.11.128/27

# Output atteso: lista di tutti gli IP attivi
# Annotare tutti i device prima di procedere
```

#### 1.3 Documentare Configurazione Gateway/Router

Prima di modificare srv26, **IMPORTANTE**: Configurare il gateway/router:

**Sul Router/Gateway (192.168.11.129):**

Esempio per router Linux:
```bash
# Accedi al gateway
ssh admin@192.168.11.129

# Backup configurazione
ip addr show > ~/network-backup-$(date +%Y%m%d).txt
ip route show >> ~/network-backup-$(date +%Y%m%d).txt

# Modifica interfaccia subnet (esempio per Linux)
# ATTENZIONE: Adatta ai comandi del tuo router specifico!
sudo ip addr del 192.168.11.129/27 dev eth0
sudo ip addr add 192.168.11.129/26 dev eth0

# Verifica
ip addr show dev eth0
```

Per router hardware (Cisco, MikroTik, pfSense, etc.):
- Accedi alla WebUI o CLI del router
- Modifica subnet mask dell'interfaccia da `255.255.255.224` a `255.255.255.192`
- Salva la configurazione

### Fase 2: Modifica srv26 (Breve Downtime)

#### Opzione A: Modifica Remota (Consigliata se hai accesso console vSphere)

**Preparazione:**
1. Apri console vSphere per srv26 (accesso diretto in caso di problemi di rete)
2. Verifica che il gateway sia già stato aggiornato a /26
3. Prepara il comando di modifica

**Esecuzione:**

```bash
# Modifica la subnet mask da /27 a /26
ssh administrator@srv26.mosca.lan "sudo nmcli connection modify ens33 ipv4.addresses 192.168.11.130/26"

# Riavvia la connessione di rete
ssh administrator@srv26.mosca.lan "sudo nmcli connection down ens33 && sudo nmcli connection up ens33"

# Se perdi la connessione SSH, è normale. Attendi 10 secondi e riconnetti
sleep 10

# Verifica la nuova configurazione
ssh administrator@srv26.mosca.lan "ip addr show ens33 | grep inet"

# Output atteso:
# inet 192.168.11.130/26 brd 192.168.11.191 scope global noprefixroute ens33
```

#### Opzione B: Modifica da Console vSphere (Più Sicura)

Se preferisci evitare il rischio di perdere l'accesso SSH:

```bash
# 1. Accedi alla console vSphere di srv26
# 2. Login come administrator
# 3. Esegui i seguenti comandi dalla console:

sudo nmcli connection modify ens33 ipv4.addresses 192.168.11.130/26
sudo nmcli connection down ens33 && sudo nmcli connection up ens33

# Verifica
ip addr show ens33 | grep inet
# Output atteso: inet 192.168.11.130/26 brd 192.168.11.191

# Verifica routing
ip route show
# Output atteso: 192.168.11.128/26 dev ens33 proto kernel scope link src 192.168.11.130

# Test connettività
ping -c 3 192.168.11.129  # gateway
ping -c 3 192.168.11.66   # DNS
ping -c 3 8.8.8.8         # Internet
```

### Fase 3: Verifica Post-Migrazione

#### 3.1 Verifica Rete srv26

```bash
# Connessione SSH
ssh administrator@srv26.mosca.lan

# Verifica IP e subnet
ip addr show ens33
# Output atteso:
# inet 192.168.11.130/26 brd 192.168.11.191 scope global noprefixroute ens33

# Verifica routing
ip route show | grep 192.168.11
# Output atteso:
# 192.168.11.128/26 dev ens33 proto kernel scope link src 192.168.11.130 metric 100

# Test DNS
nslookup rancher.savemosca.com
dig @192.168.11.66 google.com

# Test connettività internet
ping -c 3 8.8.8.8
curl -I https://google.com
```

#### 3.2 Verifica Servizi K3s e Rancher

```bash
# Verifica K3s
sudo systemctl status k3s
# Expected: active (running)

# Verifica Rancher pods
sudo /usr/local/bin/kubectl get pods -n cattle-system
# Expected: Tutti i pod rancher-* Running

# Verifica CAPV controllers
sudo /usr/local/bin/kubectl get pods -n capv-system
# Expected: capv-controller-manager-* Running

# Test accesso Rancher UI
curl -k https://rancher.savemosca.com/dashboard/
# Expected: HTTP 200 o 302 redirect
```

#### 3.3 Verifica Accesso Remoto

```bash
# Da workstation locale
ssh administrator@srv26.mosca.lan "hostname && ip addr show ens33 | grep inet"

# Accedi a Rancher UI
open https://rancher.savemosca.com
# Expected: UI carica correttamente
```

### Fase 4: Aggiornare Configurazione Cluster

#### 4.1 Aggiornare vSphere Network Range

Modifica i manifest del cluster workload per usare il nuovo range IP:

```bash
# File: infrastructure/workload-cluster/cluster.yaml
# NOTA: Questo è per riferimento futuro, il cluster workload non è ancora deployato

# Assicurati che i worker nodes ricevano IP dal nuovo range
# Se usi DHCP, verifica che il pool DHCP sia aggiornato
# Se usi IP statici, pianifica IP nel range 192.168.11.140-180
```

#### 4.2 Aggiornare Documentazione

```bash
# Aggiorna docs/01-vsphere-setup.md
# Aggiorna README.md
# Aggiorna infrastructure/vsphere-params.env.template
```

## Rollback Plan

Se qualcosa va storto durante la migrazione:

### Rollback srv26 a /27

```bash
# Da console vSphere o se hai ancora SSH
sudo nmcli connection modify ens33 ipv4.addresses 192.168.11.130/27
sudo nmcli connection down ens33 && sudo nmcli connection up ens33

# Verifica
ip addr show ens33 | grep inet
# Output: inet 192.168.11.130/27 brd 192.168.11.159

# Verifica servizi
sudo systemctl status k3s
sudo /usr/local/bin/kubectl get nodes
```

### Restore da Backup

```bash
# Ripristina configurazione NetworkManager
sudo cp ~/ens33.nmconnection.backup-YYYYMMDD-HHMM /etc/NetworkManager/system-connections/ens33.nmconnection
sudo chmod 600 /etc/NetworkManager/system-connections/ens33.nmconnection
sudo nmcli connection reload
sudo nmcli connection down ens33 && sudo nmcli connection up ens33
```

## Troubleshooting

### Problema: Perso accesso SSH dopo modifica

**Soluzione:**
1. Accedi alla console vSphere di srv26
2. Verifica l'IP: `ip addr show ens33`
3. Verifica routing: `ip route show`
4. Verifica gateway: `ping 192.168.11.129`
5. Se il gateway non risponde, probabilmente non è stato aggiornato a /26
6. Rollback a /27 o aggiorna il gateway

### Problema: K3s non si avvia dopo modifica

**Soluzione:**
```bash
# Verifica logs K3s
sudo journalctl -u k3s -n 100 --no-pager

# Verifica rete
sudo /usr/local/bin/kubectl get nodes
# Se timeout, verifica che l'API server sia raggiungibile

# Restart K3s
sudo systemctl restart k3s
sleep 30
sudo systemctl status k3s
```

### Problema: Rancher UI non raggiungibile

**Soluzione:**
```bash
# Verifica DNS
nslookup rancher.savemosca.com

# Verifica certificati
sudo /usr/local/bin/kubectl get certificates -n cattle-system

# Verifica ingress
sudo /usr/local/bin/kubectl get ingress -n cattle-system

# Verifica Traefik
sudo /usr/local/bin/kubectl get pods -n kube-system | grep traefik

# Restart Rancher pods se necessario
sudo /usr/local/bin/kubectl rollout restart deployment/rancher -n cattle-system
```

### Problema: DNS non risolve

**Soluzione:**
```bash
# Verifica che DNS servers siano raggiungibili
ping 192.168.11.66
ping 192.168.11.67

# Verifica configurazione DNS
cat /etc/resolv.conf

# Test DNS diretto
dig @192.168.11.66 google.com

# Se DNS non risponde, potrebbero avere ancora /27
# Contatta l'admin dei DNS server per aggiornarli
```

## Checklist Pre-Migrazione

Prima di procedere, assicurati di aver completato:

- [ ] Backup configurazione rete srv26
- [ ] Backup kubeconfig K3s
- [ ] Scan subnet per identificare tutti i device
- [ ] Accesso console vSphere disponibile (piano B)
- [ ] **CRITICO**: Gateway/router aggiornato a /26
- [ ] DNS servers informati/aggiornati (se necessario)
- [ ] DHCP pool aggiornato (se presente)
- [ ] Altri server sulla subnet identificati e pianificati per aggiornamento
- [ ] Finestra di manutenzione pianificata (stima: 10-15 minuti downtime srv26)
- [ ] Team informato della manutenzione
- [ ] Piano di rollback testato/compreso

## Checklist Post-Migrazione

Dopo la migrazione, verifica:

- [ ] srv26 ha IP 192.168.11.130/26
- [ ] Broadcast address è 192.168.11.191
- [ ] Route table corretta (192.168.11.128/26)
- [ ] Gateway raggiungibile (192.168.11.129)
- [ ] DNS funzionante (192.168.11.66, 192.168.11.67)
- [ ] Connettività internet OK
- [ ] K3s running
- [ ] Rancher UI accessibile
- [ ] CAPV controllers running
- [ ] SSH accessibile da remoto
- [ ] Altri device sulla subnet aggiornati
- [ ] Documentazione aggiornata

## Timeline Stimata

1. **Preparazione**: 15-30 minuti (backup, scan, pianificazione)
2. **Aggiornamento Gateway**: 5-10 minuti
3. **Aggiornamento srv26**: 2-5 minuti (downtime effettivo)
4. **Verifica e test**: 10-15 minuti
5. **Aggiornamento altri device**: Varia (dipende dal numero)

**Downtime totale stimato per srv26**: 5-10 minuti

## Note Importanti

1. **Gateway DEVE essere aggiornato prima di srv26** - altrimenti srv26 non potrà comunicare dopo il cambio
2. **Console vSphere è essenziale** - assicurati di averla disponibile prima di procedere
3. **CAPV cluster non ancora deployato** - la migrazione ora è il momento ideale
4. **DNS servers già nel nuovo range** - 192.168.11.66/67 sono inclusi in /26 ma non in /27
5. **Nessun impatto su Kubernetes workload** - il cluster workload non è ancora creato

## Next Steps

Ora che la migrazione della subnet è completata:

1. **Aggiorna vsphere-params.env** con il nuovo range per CAPV
2. **Deploy workload cluster** con IP nel range 192.168.11.140-180
3. **Configura DHCP** per assegnare IP nel nuovo range (se applicabile)
4. **Documenta IP allocation** nel README

## Riferimenti

- [RHEL 9 NetworkManager](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/)
- [nmcli Examples](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/managing-networking-with-nmcli_configuring-and-managing-networking)
- [Subnet Calculator](https://www.subnet-calculator.com/cidr.php)
