# Home Automation Stack

Future implementation per domotica e smart home.

## Componenti Pianificati

### Home Assistant
- **Descrizione**: Piattaforma open-source per home automation
- **Immagine**: `ghcr.io/home-assistant/home-assistant:stable`
- **Porte**: 8123 (WebUI)
- **Storage**: PVC per configurazione e database
- **Note**: Richiede accesso alla rete host per discovery dispositivi (hostNetwork o Multus)

### Scrypted
- **Descrizione**: Video integration platform per HomeKit, Google Home, Alexa
- **Immagine**: `koush/scrypted:latest`
- **Porte**: 10443 (WebUI), 1080x (RTSP streams)
- **Storage**: PVC per configurazione e plugin
- **GPU**: Può usare vGPU per transcoding/AI detection
- **Note**: Ideale per integrare telecamere con HomeKit Secure Video

### Homebridge
- **Descrizione**: Bridge HomeKit per dispositivi non compatibili
- **Immagine**: `homebridge/homebridge:latest`
- **Porte**: 8581 (WebUI), 51826 (HomeKit)
- **Storage**: PVC per configurazione e plugin
- **Note**: Alternativa leggera se non serve Home Assistant completo

## Architettura Consigliata

```
┌─────────────────────────────────────────────────────────────┐
│                    Home Automation Stack                     │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │    Home      │  │   Scrypted   │  │  Homebridge  │      │
│  │  Assistant   │  │   (video)    │  │   (HomeKit)  │      │
│  │   :8123      │  │   :10443     │  │    :8581     │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                  │              │
│         └────────────┬────┴──────────────────┘              │
│                      │                                      │
│              ┌───────▼───────┐                             │
│              │    Ingress    │                             │
│              │ home.mosca.lan│                             │
│              └───────────────┘                             │
└─────────────────────────────────────────────────────────────┘
                       │
                       ▼
              IoT Devices (Zigbee, Z-Wave, WiFi)
```

## Requisiti Hardware

| Componente | Requisito |
|------------|-----------|
| Zigbee Coordinator | USB dongle (Sonoff, Conbee) passato alla VM |
| Z-Wave Controller | USB dongle (Aeotec) passato alla VM |
| Telecamere | RTSP compatibili per Scrypted |

## TODO

- [ ] Creare namespace `home-automation`
- [ ] Deployment Home Assistant con discovery
- [ ] Deployment Scrypted con GPU support
- [ ] Deployment Homebridge
- [ ] Configurare Ingress per accesso esterno
- [ ] Integrare con MQTT broker (se necessario)
- [ ] Passthrough USB per Zigbee/Z-Wave coordinator

## Integrazione con Media Stack

Home Assistant può controllare:
- Plex (media player)
- TV/AV receivers
- Luci durante visione film
- Automazioni basate su stato riproduzione
