#!/usr/bin/env bash
# Run from the Jenkins pipeline (or manually) before any Ansible step.
# Pulls current instance IPs and the RDS endpoint straight from Terraform state
# so the inventory can never drift from what's actually provisioned.
set -euo pipefail

TERRAFORM_DIR="${TERRAFORM_DIR:-../terraform}"
OUTPUT_FILE="$(dirname "$0")/hosts.ini"

cd "$TERRAFORM_DIR"

BLUE_IP=$(terraform output -raw blue_instance_public_ip)
GREEN_IP=$(terraform output -raw green_instance_public_ip)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)

if [ -z "$BLUE_IP" ] || [ -z "$GREEN_IP" ] || [ -z "$RDS_ENDPOINT" ]; then
  echo "ERROR: Terraform returned empty outputs. Is the infrastructure applied?" >&2
  exit 1
fi

cd - > /dev/null

cat > "$OUTPUT_FILE" <<EOF
[blue]
${BLUE_IP} color=blue

[green]
${GREEN_IP} color=green

[all:vars]
ansible_user=ec2-user
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
rds_endpoint=${RDS_ENDPOINT}
EOF

echo "Wrote inventory: blue=${BLUE_IP} green=${GREEN_IP} rds=${RDS_ENDPOINT}"
