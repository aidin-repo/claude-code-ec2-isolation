#!/bin/bash
# Connect to Claude Code on EC2 (SSO auth — no port forwarding needed)
# Usage: ./connect-sso.sh [username]

INSTANCE_ID="<your-instance-id>"
USERNAME="${1:-$(whoami)}"

echo "Connecting to Claude Code EC2 as $USERNAME..."
echo ""
echo "Once connected, run:"
echo "  sudo su - $USERNAME"
echo "  auth        # SSO login — open URL in browser, enter code"
echo "  claude      # Start Claude Code"
echo ""

aws ssm start-session --target "$INSTANCE_ID"
echo "Disconnected."
