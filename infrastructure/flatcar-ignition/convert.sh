#!/bin/bash
# Convert Butane YAML to Ignition JSON for Flatcar provisioning

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Flatcar Ignition Config Converter${NC}"
echo "===================================="

# Check if butane is installed
if ! command -v butane &> /dev/null; then
    echo -e "${RED}Error: butane is not installed${NC}"
    echo "Install with:"
    echo "  macOS: brew install butane"
    echo "  Linux: https://coreos.github.io/butane/getting-started/"
    exit 1
fi

# Check butane version
BUTANE_VERSION=$(butane --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e "Using butane version: ${GREEN}${BUTANE_VERSION}${NC}"

# Convert worker-node.bu to Ignition JSON
INPUT_FILE="worker-node.bu"
OUTPUT_FILE="worker-node.ign"

if [ ! -f "${INPUT_FILE}" ]; then
    echo -e "${RED}Error: ${INPUT_FILE} not found${NC}"
    exit 1
fi

echo -e "\nConverting ${YELLOW}${INPUT_FILE}${NC} to Ignition JSON..."

if butane --strict --pretty < "${INPUT_FILE}" > "${OUTPUT_FILE}"; then
    echo -e "${GREEN}✓ Successfully created ${OUTPUT_FILE}${NC}"

    # Show file size
    SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)
    echo "  File size: ${SIZE}"

    # Validate JSON
    if command -v jq &> /dev/null; then
        if jq empty "${OUTPUT_FILE}" 2>/dev/null; then
            echo -e "${GREEN}✓ JSON validation passed${NC}"
        else
            echo -e "${RED}✗ JSON validation failed${NC}"
            exit 1
        fi
    fi

    # Show summary of config
    echo -e "\nConfiguration summary:"
    echo "  Variant: $(jq -r '.variant' ${OUTPUT_FILE} 2>/dev/null || echo 'N/A')"
    echo "  Version: $(jq -r '.version' ${OUTPUT_FILE} 2>/dev/null || echo 'N/A')"

    if command -v jq &> /dev/null; then
        FILE_COUNT=$(jq '.storage.files | length' ${OUTPUT_FILE} 2>/dev/null || echo 0)
        UNIT_COUNT=$(jq '.systemd.units | length' ${OUTPUT_FILE} 2>/dev/null || echo 0)
        echo "  Files: ${FILE_COUNT}"
        echo "  Systemd units: ${UNIT_COUNT}"
    fi

    echo -e "\n${GREEN}Next steps:${NC}"
    echo "1. Review the generated ${OUTPUT_FILE}"
    echo "2. Upload to vSphere as guestinfo.ignition.config"
    echo "3. Or use with CAPV ignition configuration"

else
    echo -e "${RED}✗ Conversion failed${NC}"
    exit 1
fi

# Optional: Create base64-encoded version for embedding
echo -e "\nCreating base64-encoded version..."
base64 < "${OUTPUT_FILE}" > "${OUTPUT_FILE}.base64"
echo -e "${GREEN}✓ Created ${OUTPUT_FILE}.base64${NC}"

echo -e "\n${YELLOW}Note:${NC} Update SSH keys in ${INPUT_FILE} before production use!"
