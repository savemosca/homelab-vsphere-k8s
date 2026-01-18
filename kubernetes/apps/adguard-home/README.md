# AdGuard Home

DNS server con ad-blocking, supporto DNS-over-HTTPS (DoH) e DNS-over-TLS (DoT) integrati.

## Funzionalità

- Blocco pubblicità e tracker a livello DNS
- DNS-over-HTTPS (DoH) integrato
- DNS-over-TLS (DoT) integrato
- Parental control
- Query log e statistiche
- Supporto liste di blocco personalizzate

## Servizi esposti

| Servizio | Porta | IP MetalLB | Descrizione |
|----------|-------|------------|-------------|
| DNS TCP/UDP | 53 | 192.168.1.53 | DNS standard |
| DNS-over-TLS | 853 | 192.168.1.54 | DNS criptato |
| Web UI | 80/443 | via Ingress | Pannello amministrazione |
| Setup | 3000 | interno | Wizard configurazione iniziale |

## Deploy

```bash
kubectl apply -f adguard-deployment.yaml
```

## Configurazione iniziale

1. Al primo avvio, accedi al wizard: `http://<pod-ip>:3000`
2. Configura username e password admin
3. Configura upstream DNS (es. `https://1.1.1.1/dns-query` per DoH)
4. Dopo la configurazione, la UI sarà disponibile su porta 80

## Configurazione DNS-over-HTTPS upstream

Nella UI di AdGuard, vai su Settings → DNS settings → Upstream DNS:

```
https://1.1.1.1/dns-query
https://1.0.0.1/dns-query
```

## Accesso Web UI

Dopo il deploy, accedi via:
- Ingress: https://adguard.homelab.local (modifica hostname nel file)
- NodePort: http://<node-ip>:80

## Note

- Modifica `192.168.1.53` e `192.168.1.54` con IP del tuo pool MetalLB
- Modifica `adguard.homelab.local` con il tuo hostname
- I PVC usano `vsphere-thin` StorageClass - adatta se necessario
