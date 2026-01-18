# cert-manager con Let's Encrypt e Cloudflare DNS-01

Configurazione per ottenere certificati TLS automatici tramite Let's Encrypt usando Cloudflare come DNS provider.

## Prerequisiti

1. Dominio gestito su Cloudflare
2. cert-manager installato nel cluster

## Installazione cert-manager

```bash
# Con kubectl
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Oppure con Helm
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

## Configurazione Cloudflare API Token

1. Vai su https://dash.cloudflare.com/profile/api-tokens
2. Clicca "Create Token"
3. Seleziona "Custom token"
4. Configura:
   - **Token name:** cert-manager
   - **Permissions:** Zone - DNS - Edit
   - **Zone Resources:** Include - Specific zone - tuodominio.com
5. Copia il token generato

## Configurazione

Modifica `cert-manager.yaml`:

1. Sostituisci `YOUR_CLOUDFLARE_API_TOKEN` con il token Cloudflare
2. Sostituisci `your-email@example.com` con la tua email

## Deploy

```bash
kubectl apply -f cert-manager.yaml
```

## Utilizzo negli Ingress

Aggiungi l'annotation per richiedere un certificato:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.tuodominio.com
      secretName: myapp-tls
  rules:
    - host: myapp.tuodominio.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 80
```

## ClusterIssuers disponibili

| Nome | Uso |
|------|-----|
| `letsencrypt-prod` | Produzione - certificati validi |
| `letsencrypt-staging` | Test - certificati non trusted (rate limit più alto) |

## Troubleshooting

```bash
# Verifica ClusterIssuer
kubectl get clusterissuer

# Verifica certificati
kubectl get certificates -A

# Verifica challenges
kubectl get challenges -A

# Log cert-manager
kubectl logs -n cert-manager -l app=cert-manager
```
