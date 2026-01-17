#!/bin/bash
# K3s installation script for management cluster
# Run this on the Ubuntu VM that will host the management cluster

set -euo pipefail

echo "Installing K3s for Cluster API management cluster..."

# Install K3s without default workload scheduling
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --disable metrics-server \
  --write-kubeconfig-mode 644 \
  --node-taint CriticalAddonsOnly=true:NoExecute \
  --kube-apiserver-arg=feature-gates=JobTrackingWithFinalizers=true

echo "Waiting for K3s to be ready..."
sleep 10

# Wait for node to be ready
sudo k3s kubectl wait --for=condition=ready node --all --timeout=300s

echo "K3s installed successfully!"
echo ""
echo "Kubeconfig location: /etc/rancher/k3s/k3s.yaml"
echo ""
echo "To access from remote machine:"
echo "  scp ubuntu@$(hostname -I | awk '{print $1}'):/etc/rancher/k3s/k3s.yaml ~/.kube/management-config"
echo "  sed -i 's/127.0.0.1/$(hostname -I | awk '{print $1}')/g' ~/.kube/management-config"
echo ""
echo "Verify cluster:"
echo "  export KUBECONFIG=~/.kube/management-config"
echo "  kubectl get nodes"
