#!/bin/bash
# Generate Ignition config for Flatcar worker nodes
# Usage: ./generate-ignition.sh <rke2-server-url> <rke2-token> <ssh-public-key>
#
# Example:
#   ./generate-ignition.sh https://rke2-cp.mosca.lan:9345 "K10abc123..." "ssh-rsa AAAA..."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <rke2-server-url> <rke2-token> <ssh-public-key>"
    echo ""
    echo "Arguments:"
    echo "  rke2-server-url  - RKE2 server URL (e.g., https://rke2-cp.mosca.lan:9345)"
    echo "  rke2-token       - RKE2 join token (from /var/lib/rancher/rke2/server/node-token)"
    echo "  ssh-public-key   - SSH public key for 'core' user"
    echo ""
    echo "Example:"
    echo "  $0 https://rke2-cp.mosca.lan:9345 'K10abc...' 'ssh-rsa AAAA...'"
    exit 1
fi

RKE2_SERVER_URL="$1"
RKE2_TOKEN="$2"
SSH_PUBLIC_KEY="$3"

# Generate RKE2 config
RKE2_CONFIG=$(cat <<EOF
server: ${RKE2_SERVER_URL}
token: ${RKE2_TOKEN}
node-label:
  - "node.kubernetes.io/pool=workers"
  - "topology.kubernetes.io/zone=vsphere"
kubelet-arg:
  - "max-pods=110"
  - "image-gc-high-threshold=85"
  - "image-gc-low-threshold=80"
EOF
)

# Base64 encode the config
RKE2_CONFIG_BASE64=$(echo "$RKE2_CONFIG" | base64 | tr -d '\n')

# Check if butane is available
if command -v butane &> /dev/null; then
    echo "Using butane to generate Ignition config..."

    # Generate from YAML using butane
    cat "${SCRIPT_DIR}/flatcar-worker-ignition.yaml" | \
        sed "s|YOUR_RKE2_TOKEN|${RKE2_TOKEN}|g" | \
        sed "s|https://rke2-cp.mosca.lan:9345|${RKE2_SERVER_URL}|g" | \
        sed "s|ssh-rsa YOUR_SSH_PUBLIC_KEY user@workstation|${SSH_PUBLIC_KEY}|g" | \
        butane --pretty --strict > "${SCRIPT_DIR}/flatcar-worker.ign"
else
    echo "butane not found, using template..."

    # Use JSON template
    cat "${SCRIPT_DIR}/flatcar-worker.ign.template" | \
        sed "s|\${RKE2_CONFIG_BASE64}|${RKE2_CONFIG_BASE64}|g" | \
        sed "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY}|g" > "${SCRIPT_DIR}/flatcar-worker.ign"
fi

echo ""
echo "Generated: ${SCRIPT_DIR}/flatcar-worker.ign"
echo ""
echo "Next steps:"
echo "1. Upload flatcar-worker.ign to a web server or paste into vSphere VM guestinfo"
echo "2. Create VM from Flatcar OVA"
echo "3. Set guestinfo.ignition.config.data = <base64 of flatcar-worker.ign>"
echo "4. Set guestinfo.ignition.config.data.encoding = base64"
echo ""
echo "Or with govc:"
echo "  govc vm.change -vm <vm-name> \\"
echo "    -e guestinfo.ignition.config.data=\$(base64 -w0 flatcar-worker.ign) \\"
echo "    -e guestinfo.ignition.config.data.encoding=base64"
