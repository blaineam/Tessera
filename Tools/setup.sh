#!/usr/bin/env bash
#
# Tessera Setup Script
# Run this once to configure Tessera for your project.
#
set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║         Tessera Setup Wizard         ║"
echo "  ║  Cryptographic App Licensing for macOS ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${NC}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TESSERA_DIR="$PROJECT_ROOT"
TOOLS_DIR="$SCRIPT_DIR"
CONFIG_FILE="$TESSERA_DIR/tessera.config.json"
KEYS_DIR="$TOOLS_DIR/keys"

# Step 1: Check dependencies
echo -e "${BOLD}Step 1: Checking dependencies...${NC}"

if ! command -v python3 &>/dev/null; then
    echo "  Python 3 is required. Install it from https://python.org"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python 3 found"

if ! python3 -c "import cryptography" 2>/dev/null; then
    echo "  Installing cryptography package..."
    pip3 install -q cryptography
fi
echo -e "  ${GREEN}✓${NC} cryptography package ready"

# Step 2: Generate keypair
echo ""
echo -e "${BOLD}Step 2: Generating Ed25519 keypair...${NC}"

if [ -f "$KEYS_DIR/private.pem" ]; then
    echo -e "  ${YELLOW}!${NC} Keypair already exists at $KEYS_DIR/"
    read -p "  Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Keeping existing keypair."
    else
        python3 "$TOOLS_DIR/tessera_cli.py" generate-keypair --output-dir "$KEYS_DIR"
    fi
else
    mkdir -p "$KEYS_DIR"
    python3 "$TOOLS_DIR/tessera_cli.py" generate-keypair --output-dir "$KEYS_DIR"
fi

# Extract the base64 public key
PUBLIC_KEY_B64=$(python3 -c "
import base64
from cryptography.hazmat.primitives import serialization
with open('$KEYS_DIR/public.pem', 'rb') as f:
    pub = serialization.load_pem_public_key(f.read())
raw = pub.public_bytes(encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)
print(base64.b64encode(raw).decode())
")
echo -e "  ${GREEN}✓${NC} Keypair generated"
echo -e "  ${DIM}Public key (base64): ${PUBLIC_KEY_B64}${NC}"

# Step 3: Create config from template
echo ""
echo -e "${BOLD}Step 3: Configuration${NC}"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${YELLOW}!${NC} tessera.config.json already exists"
    echo "  Edit it manually if needed: $CONFIG_FILE"
else
    cp "$TESSERA_DIR/tessera.config.example.json" "$CONFIG_FILE"
    echo -e "  ${GREEN}✓${NC} Created tessera.config.json from template"
    echo -e "  ${YELLOW}→${NC} Edit $CONFIG_FILE with your app details"
fi

# Step 4: Summary
echo ""
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo -e "  1. ${BOLD}Edit your config:${NC}"
echo "     $CONFIG_FILE"
echo ""
echo -e "  2. ${BOLD}Embed the public key in your Swift app:${NC}"
echo "     publicKeyBase64: \"$PUBLIC_KEY_B64\""
echo ""
echo -e "  3. ${BOLD}Add GitHub repo secrets:${NC}"
echo "     TESSERA_PRIVATE_KEY  = contents of $KEYS_DIR/private.pem"
echo "     PAGES_REPO_TOKEN    = GitHub PAT with repo scope"
echo ""
echo -e "  4. ${BOLD}(Optional) Set up Stripe:${NC}"
echo "     STRIPE_SECRET_KEY   = sk_live_xxxx"
echo "     STRIPE_WEBHOOK_SECRET = whsec_xxxx"
echo ""
echo -e "  5. ${BOLD}Generate your first license:${NC}"
echo "     python3 $TOOLS_DIR/tessera_cli.py generate \\"
echo "       --private-key $KEYS_DIR/private.pem \\"
echo "       --tier pro --duration 365"
echo ""
echo -e "  ${DIM}Full docs: https://tessera.wemiller.com${NC}"
echo -e "  ${DIM}Never commit private.pem or the keys/ directory!${NC}"
