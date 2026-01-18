#!/bin/bash
# Script di bootstrap per worker GPU con RKE2 (Ubuntu Server 24.04 LTS)
# Eseguito prima dell'installazione di RKE2
#
# In Rancher: Cluster → Machine Pools → GPU Pool → Cloud Config → runcmd

set -e

echo "=== GPU Worker Bootstrap (Ubuntu 24.04 LTS) ==="

# Rileva se GPU presente
if ! lspci | grep -qi nvidia; then
    echo "No NVIDIA GPU detected, exiting"
    exit 0
fi

echo "NVIDIA GPU detected, installing drivers..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
fi

case $OS in
    ubuntu)
        echo "Installing NVIDIA driver 550 on Ubuntu ${VERSION}..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            nvidia-driver-550-server \
            nvidia-utils-550-server

        # NVIDIA Container Toolkit
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

        apt-get update
        apt-get install -y nvidia-container-toolkit
        ;;

    *)
        echo "Unsupported OS: $OS (expected Ubuntu 24.04)"
        exit 1
        ;;
esac

# Configura containerd per NVIDIA runtime
# Nota: RKE2 installerà containerd, questo script viene eseguito prima
# La configurazione avverrà dopo l'installazione di RKE2

# Crea script post-RKE2 per configurare containerd
cat > /usr/local/bin/configure-nvidia-containerd.sh << 'EOFSCRIPT'
#!/bin/bash
# Eseguito dopo che RKE2 ha installato containerd

set -e

# Aspetta che RKE2 sia installato
until [ -f /var/lib/rancher/rke2/agent/etc/containerd/config.toml ]; do
    echo "Waiting for RKE2 containerd config..."
    sleep 10
done

# Configura NVIDIA runtime
nvidia-ctk runtime configure --runtime=containerd \
    --config=/var/lib/rancher/rke2/agent/etc/containerd/config.toml

# Riavvia containerd di RKE2
systemctl restart rke2-agent || systemctl restart rke2-server

echo "NVIDIA containerd configuration completed"
EOFSCRIPT

chmod +x /usr/local/bin/configure-nvidia-containerd.sh

# Crea systemd service per configurazione post-RKE2
cat > /etc/systemd/system/nvidia-containerd-config.service << 'EOF'
[Unit]
Description=Configure NVIDIA runtime for RKE2 containerd
After=rke2-agent.service rke2-server.service
Wants=rke2-agent.service rke2-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/configure-nvidia-containerd.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nvidia-containerd-config.service

echo "=== GPU Worker Bootstrap Complete ==="
echo "Reboot required for NVIDIA driver to load"
