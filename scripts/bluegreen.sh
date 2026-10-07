#!/usr/bin/env bash
# Blue/green helper used by the Jenkinsfile. Can also be run by hand:
#   scripts/bluegreen.sh live
#   scripts/bluegreen.sh prewarm blue green
# Everything is discovered from AWS by name and tag, so nothing is hardcoded
# and it survives a terraform destroy/apply (new ARNs, new IPs).
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-2}"
PROJECT="${PROJECT:-bluegreen-bankapp}"
APP_PORT="${APP_PORT:-8080}"

log() { echo "[bluegreen] $*" >&2; }

lb_arn()       { aws elbv2 describe-load-balancers --names "${PROJECT}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text; }
alb_dns()      { aws elbv2 describe-load-balancers --names "${PROJECT}-alb" --query 'LoadBalancers[0].DNSName' --output text; }
listener_arn() { aws elbv2 describe-listeners --load-balancer-arn "$(lb_arn)" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text; }
tg_arn()       { aws elbv2 describe-target-groups --names "${PROJECT}-$1-tg" --query 'TargetGroups[0].TargetGroupArn' --output text; }

other_color() { if [ "$1" = "blue" ]; then echo green; else echo blue; fi; }

# Which color currently receives the traffic (the one with the highest weight).
live_color() {
  local listener arn
  listener=$(listener_arn)
  arn=$(aws elbv2 describe-listeners --listener-arns "$listener" \
        --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups | sort_by(@, &Weight) | [-1].TargetGroupArn' \
        --output text 2>/dev/null || true)
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn=$(aws elbv2 describe-listeners --listener-arns "$listener" \
          --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)
  fi
  if   [ "$arn" = "$(tg_arn blue)" ];  then echo blue
  elif [ "$arn" = "$(tg_arn green)" ]; then echo green
  else log "ERROR: listener points at an unknown target group: $arn"; return 1
  fi
}

# set_weights <blue weight> <green weight>
set_weights() {
  local b g
  b=$(tg_arn blue); g=$(tg_arn green)
  aws elbv2 modify-listener --listener-arn "$(listener_arn)" \
    --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$b\",\"Weight\":$1},{\"TargetGroupArn\":\"$g\",\"Weight\":$2}]}}]" \
    --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].Weight' --output text >/dev/null
}

# shift_traffic <color that should receive 100%>
shift_traffic() {
  if [ "$1" = "blue" ]; then set_weights 100 0; else set_weights 0 100; fi
}

# wait_healthy <color> [timeout seconds]: ALB health state, not just a curl
wait_healthy() {
  local color=$1 timeout=${2:-240} waited=0 state
  while [ "$waited" -lt "$timeout" ]; do
    state=$(aws elbv2 describe-target-health --target-group-arn "$(tg_arn "$color")" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo unknown)
    log "$color target health: $state (${waited}s)"
    [ "$state" = "healthy" ] && return 0
    sleep 5; waited=$((waited + 5))
  done
  log "ERROR: $color never became healthy within ${timeout}s"; return 1
}

probe() { curl -s -m 5 "http://$(alb_dns)/version" || true; }

# wait_live <color> [version] [timeout seconds]: poll the public ALB until it
# answers as the expected color (a listener change takes ~15s to propagate)
wait_live() {
  local color=$1 version=${2:-} timeout=${3:-90} waited=0 want out
  want="color=${color}"; [ -n "$version" ] && want="color=${color} version=${version}"
  while [ "$waited" -lt "$timeout" ]; do
    out=$(probe)
    log "ALB answers: ${out:-<no answer>}"
    case "$out" in "$want"*) return 0 ;; esac
    sleep 3; waited=$((waited + 3))
  done
  log "ERROR: ALB did not answer as '$want' within ${timeout}s"; return 1
}

# soak <color> <version> [requests]: every answer must come from the new version
soak() {
  local color=$1 version=$2 n=${3:-10} i out
  for i in $(seq 1 "$n"); do
    out=$(probe)
    if [ "$out" != "color=${color} version=${version}" ]; then
      log "ERROR: request $i answered '${out:-<no answer>}'"; return 1
    fi
    sleep 1
  done
  log "soak passed: $n/$n requests served by $color $version"
}

instance_ip() {
  aws ec2 describe-instances \
    --filters "Name=tag:Color,Values=$1" "Name=tag:Name,Values=${PROJECT}-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}

rds_endpoint() {
  aws rds describe-db-instances --db-instance-identifier "${PROJECT}-db" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

# inventory <color> <file>: Ansible inventory containing only that color
write_inventory() {
  local color=$1 file=$2 ip rds
  ip=$(instance_ip "$color"); rds=$(rds_endpoint)
  if [ -z "$ip" ] || [ "$ip" = "None" ] || [ -z "$rds" ] || [ "$rds" = "None" ]; then
    log "ERROR: could not find the $color instance or the database"; return 1
  fi
  cat > "$file" <<INV
[${color}]
${ip} color=${color}

[all:vars]
ansible_user=ec2-user
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
rds_endpoint=${rds}
INV
  log "inventory written: $color=$ip"
}

# verify <color> <version> <ssh key>: ask the server itself what it is running.
# The app port is only open to the ALB, so this goes over SSH.
verify_direct() {
  local color=$1 version=$2 key=$3 ip out i
  ip=$(instance_ip "$color")
  for i in 1 2 3 4 5; do
    out=$(ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
          "ec2-user@${ip}" "curl -s -m 5 localhost:${APP_PORT}/version" || true)
    log "$color server says: ${out:-<no answer>}"
    [ "$out" = "color=${color} version=${version}" ] && return 0
    sleep 5
  done
  log "ERROR: $color is not running $version"; return 1
}

cmd=${1:-}; shift || true
case "$cmd" in
  live)      live_color ;;
  idle)      other_color "$(live_color)" ;;
  inventory) write_inventory "$@" ;;
  verify)    verify_direct "$@" ;;
  prewarm)   # prewarm <live> <idle>: attach idle at 0% so the ALB health-checks it
             shift_traffic "$1"; wait_healthy "$2" ;;
  flip)      shift_traffic "$1" ;;
  wait-live) wait_live "$@" ;;
  soak)      soak "$@" ;;
  rollback)  # rollback <color to restore>
             shift_traffic "$1"; wait_live "$1" "" 90 ;;
  *) echo "usage: $0 {live|idle|inventory|verify|prewarm|flip|wait-live|soak|rollback}" >&2; exit 2 ;;
esac
