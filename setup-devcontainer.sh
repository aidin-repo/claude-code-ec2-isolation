#!/bin/bash
set -euo pipefail

# Setup Docker-based Claude Code devcontainer with iptables firewall
# Run as root on the EC2 instance: sudo bash setup-devcontainer.sh

echo "=== Phase 1: Install Docker ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

echo "Docker installed: $(docker --version)"

echo "=== Phase 2: Create Devcontainer Files ==="
mkdir -p /opt/claude-devcontainer/.devcontainer

# --- Dockerfile ---
cat > /opt/claude-devcontainer/.devcontainer/Dockerfile << 'DOCKERFILE'
FROM node:20

ARG TZ=America/New_York
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
  less git procps sudo fzf zsh man-db unzip gnupg2 \
  iptables ipset iproute2 dnsutils aggregate jq nano vim \
  bubblewrap socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/aws /tmp/awscliv2.zip

ARG USERNAME=node

RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/node/.claude /usr/local/share/npm-global && \
  chown -R node:node /workspace /home/node/.claude /usr/local/share/npm-global

WORKDIR /workspace
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/bash

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

RUN mkdir -p /etc/claude-code /opt/claude-hooks
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY block-db-access.sh /opt/claude-hooks/block-db-access.sh
RUN chmod +x /opt/claude-hooks/block-db-access.sh

USER node
DOCKERFILE

# --- Firewall script ---
cat > /opt/claude-devcontainer/.devcontainer/init-firewall.sh << 'FIREWALL'
#!/bin/bash
set -euo pipefail

echo "=== Configuring network firewall ==="

# Detect region from instance metadata
REGION=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")

# Extract Docker DNS rules BEFORE flushing
DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS via iptables-restore
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "$DOCKER_DNS_RULES" | while IFS= read -r rule; do
        if [[ -n "$rule" && "$rule" == -A* ]]; then
            iptables -t nat $rule 2>/dev/null || true
        fi
    done
fi

# Allow DNS, SSH, localhost before restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset for allowed domains
ipset create allowed-domains hash:net

# Resolve and add allowed domains
for domain in \
    "api.anthropic.com" \
    "bedrock-runtime.${REGION}.amazonaws.com" \
    "sts.${REGION}.amazonaws.com" \
    "ssm.${REGION}.amazonaws.com" \
    "registry.npmjs.org" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
    if [ -n "$ips" ]; then
        while read -r ip; do
            if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                ipset add allowed-domains "$ip" 2>/dev/null || true
            fi
        done <<< "$ips"
    else
        echo "WARNING: Could not resolve $domain"
    fi
done

# EC2 instance metadata service
iptables -A OUTPUT -d 169.254.169.254/32 -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -d 169.254.169.254/32 -p tcp --dport 443 -j ACCEPT
ipset add allowed-domains 169.254.169.254 2>/dev/null || true

# VPC CIDR for VPC endpoints
# IMPORTANT: restrict to your actual VPC CIDR — broad ranges (10.0.0.0/8)
# would allow access to production databases in the same VPC.
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
ipset add allowed-domains "$VPC_CIDR" 2>/dev/null || true

# Host network (Docker bridge)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -n "$HOST_IP" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# Default policies: DROP everything
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow only traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "=== Firewall configured ==="
echo "Allowed IPs: $(ipset list allowed-domains | grep -c '^[0-9]')"
FIREWALL

# --- Managed settings ---
cat > /opt/claude-devcontainer/.devcontainer/managed-settings.json << 'MANAGED'
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "DISABLE_AUTOUPDATER": "1",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-4-20250514-v1:0",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "AWS_SDK_UA_APP_ID": "ClaudeCode"
  },
  "permissions": {
    "deny": ["Bash(sudo *)"]
  }
}
MANAGED

# --- DB blocking hook ---
cat > /opt/claude-devcontainer/.devcontainer/block-db-access.sh << 'HOOK'
#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if echo "$COMMAND" | grep -qEi '(psql|mysql|mongosh|redis-cli|sqlcmd|cqlsh)'; then
  echo '{"decision":"deny","reason":"Database client connections are blocked by policy"}'
  exit 2
fi
if echo "$COMMAND" | grep -qEi '(jdbc:|mongodb://|postgres://|mysql://|redis://)'; then
  echo '{"decision":"deny","reason":"Database connection strings are blocked by policy"}'
  exit 2
fi
if echo "$COMMAND" | grep -qEi 'aws (rds|dynamodb|redshift|neptune|docdb)'; then
  echo '{"decision":"deny","reason":"Direct database service access is blocked by policy"}'
  exit 2
fi
exit 0
HOOK

# --- docker-compose.yml ---
cat > /opt/claude-devcontainer/docker-compose.yml << 'COMPOSE'
services:
  claude-code:
    build:
      context: .devcontainer
      dockerfile: Dockerfile
    container_name: claude-code-dev
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      - CLAUDE_CODE_USE_BEDROCK=1
      - NODE_OPTIONS=--max-old-space-size=4096
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - AWS_EC2_METADATA_SERVICE_ENDPOINT=http://169.254.169.254
    volumes:
      - claude-config:/home/node/.claude
      - claude-history:/commandhistory
      - /workspace:/workspace
    working_dir: /workspace
    extra_hosts:
      - "169.254.169.254:host-gateway"
    stdin_open: true
    tty: true
    restart: unless-stopped

volumes:
  claude-config:
  claude-history:
COMPOSE

# --- Launch script ---
cat > /opt/claude-devcontainer/launch.sh << 'LAUNCH'
#!/bin/bash
PROJECT_DIR="${1:-/workspace}"
CONTAINER_NAME="claude-code-dev"

if docker ps --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    echo "Attaching to running container..."
    docker exec -it -u node "$CONTAINER_NAME" bash -c "cd $PROJECT_DIR && claude"
else
    echo "Starting devcontainer..."
    cd /opt/claude-devcontainer
    docker compose up -d --build
    echo "Waiting for container..."
    sleep 5
    echo "Initializing firewall..."
    docker exec -u node "$CONTAINER_NAME" sudo /usr/local/bin/init-firewall.sh
    echo "Launching Claude Code..."
    docker exec -it -u node "$CONTAINER_NAME" bash -c "cd $PROJECT_DIR && claude"
fi
LAUNCH
chmod +x /opt/claude-devcontainer/launch.sh

echo "=== Phase 3: Build Docker Image ==="
cd /opt/claude-devcontainer
docker compose build 2>&1 | tail -20

echo "=== Setup Complete ==="
echo "Run: /opt/claude-devcontainer/launch.sh"
