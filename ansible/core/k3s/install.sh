#!/bin/bash

# --- Configuration Defaults ---
DEFAULT_CONTEXT="k3s"
DEFAULT_IP="192.168.1.201"
DEFAULT_USER="root"
DEFAULT_SSH_KEY="/home/akira/OneDrive/credentials/ssh/k3s/id_rsa"
# Database Defaults
DB_USER="k3s"
DB_HOST="192.168.99.2"
DB_PORT="5432"
DB_NAME="k3s_production"

# --- Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}--- k3sup HA Installer (Postgres) ---${NC}"

# 1. Target IP
read -p "Target IP Address [$DEFAULT_IP]: " TARGET_IP
TARGET_IP=${TARGET_IP:-$DEFAULT_IP}

# 2. SSH User
read -p "SSH User [$DEFAULT_USER]: " SSH_USER
SSH_USER=${SSH_USER:-$DEFAULT_USER}

# 3. SSH Key Path
read -p "SSH Key Path [$DEFAULT_SSH_KEY]: " SSH_KEY
SSH_KEY=${SSH_KEY:-$DEFAULT_SSH_KEY}

# 4. Context Name
read -p "Local Context Name [$DEFAULT_CONTEXT]: " CONTEXT_NAME
CONTEXT_NAME=${CONTEXT_NAME:-$DEFAULT_CONTEXT}

# 5. K3s Token (Required for HA/Datastore)
# Generate a random default token
RANDOM_TOKEN=$(openssl rand -hex 16)
echo ""
echo -e "${YELLOW}Important: K3s requires a shared secret (Token) when using an external database.${NC}"
echo -e "If this is your first node, use the generated token below."
echo -e "If this is your 2nd/3rd node, paste the token from the first node."
echo -e "Generated Token: ${GREEN}${RANDOM_TOKEN}${NC}"
read -p "Enter K3s Token [Press Enter to use generated]: " K3S_TOKEN
K3S_TOKEN=${K3S_TOKEN:-$RANDOM_TOKEN}

# 6. Database Password
echo ""
echo -e "Enter PostgreSQL password for user '${DB_USER}' on host '${DB_HOST}'"
read -s -p "DB Password: " DB_PASS
echo ""

# Validate Password is not empty
if [ -z "$DB_PASS" ]; then
    echo -e "${RED}Error: DB Password cannot be empty!${NC}"
    exit 1
fi

# Construct Datastore URL
DATASTORE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

echo ""
echo -e "${CYAN}--- Summary ---${NC}"
echo "  Target: $TARGET_IP"
echo "  Token:  ${K3S_TOKEN:0:5}..."
echo "  DB URL: postgresql://${DB_USER}:*****@${DB_HOST}..."
echo ""

read -p "Run install now? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Execution ---
echo -e "${GREEN}Running k3sup install...${NC}"

k3sup install \
  --context "$CONTEXT_NAME" \
  --datastore "$DATASTORE_URL" \
  --ip "$TARGET_IP" \
  --ssh-key "$SSH_KEY" \
  --user "$SSH_USER" \
  --token "${K3S_TOKEN}"