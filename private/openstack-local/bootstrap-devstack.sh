#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER="${HA_OPENSTACK_CONTAINER:-ha-openstack}"
IMAGE="${HA_OPENSTACK_LXD_IMAGE:-ubuntu:24.04}"
BRANCH="${HA_DEVSTACK_BRANCH:-master}"
PASSWORD="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
HANDOFF_DIR="${PROJECT_ROOT}/.ha/handoff"
OPENSTACK_DIR="${PROJECT_ROOT}/.ha/openstack-local"

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'openstack-local: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

lxd_container_ip() {
  lxc list "$CONTAINER" -c 4 --format csv | awk -F'[ ()]' '
    /eth0/ {
      gsub(/"/, "", $1)
      print $1
      exit
    }
  '
}

ensure_lxd_initialized() {
  if ! lxc profile show default >/dev/null 2>&1; then
    lxd init --auto
    return
  fi

  if ! lxc profile show default | grep -q 'pool: default'; then
    lxd init --auto
  fi
}

ensure_container() {
  local raw_lxc

  raw_lxc=$'lxc.apparmor.profile=unconfined\nlxc.cap.drop=\nlxc.mount.auto=proc:rw sys:rw cgroup:rw'
  ensure_lxd_initialized

  if ! lxc info "$CONTAINER" >/dev/null 2>&1; then
    info "Creating LXD container: ${CONTAINER}"
    lxc init "$IMAGE" "$CONTAINER" \
      -c security.nesting=true \
      -c security.privileged=true \
      -c raw.lxc="$raw_lxc"
    lxc config device add "$CONTAINER" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
    lxc config device add "$CONTAINER" host-kernel-modules disk source=/lib/modules path=/lib/modules readonly=true >/dev/null 2>&1 || true
    if [[ -e /dev/kvm ]]; then
      lxc config device add "$CONTAINER" kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
    fi
    lxc start "$CONTAINER"
  else
    info "Using existing LXD container: ${CONTAINER}"
    lxc config set "$CONTAINER" security.nesting true
    lxc config set "$CONTAINER" security.privileged true
    lxc config set "$CONTAINER" raw.lxc "$raw_lxc"
    lxc config device add "$CONTAINER" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
    lxc config device add "$CONTAINER" host-kernel-modules disk source=/lib/modules path=/lib/modules readonly=true >/dev/null 2>&1 || true
    if [[ -e /dev/kvm ]]; then
      lxc config device add "$CONTAINER" kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
    fi
    if ! lxc info "$CONTAINER" | grep -q '^Status: RUNNING'; then
      lxc start "$CONTAINER"
    fi
  fi

  lxc exec "$CONTAINER" -- cloud-init status --wait >/dev/null 2>&1 || true
}

ensure_kernel_modules() {
  info "Loading Open vSwitch kernel modules"
  lxc exec "$CONTAINER" -- bash -lc '
    set -euo pipefail
    modprobe openvswitch
    modprobe vport-geneve
    modprobe vport-vxlan
  ' || die "failed to load Open vSwitch kernel modules; make sure linux-modules-extra-$(uname -r) is installed on the host"
}

openstack_ready() {
  lxc exec "$CONTAINER" -- sudo -u stack -H bash -lc '
    set -e
    cd /opt/stack/devstack
    [ -f openrc ] || exit 1
    source openrc admin admin
    openstack token issue -f value -c id >/dev/null
    openstack compute service list -f value >/dev/null
    openstack network list -f value >/dev/null
    openstack image list -f value >/dev/null
    openstack volume service list -f value >/dev/null
  ' >/dev/null 2>&1
}

prepare_container() {
  info "Preparing DevStack prerequisites"
  lxc exec "$CONTAINER" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git sudo curl ca-certificates iproute2 net-tools kmod python3-openstackclient
    if ! id stack >/dev/null 2>&1; then
      useradd -s /bin/bash -d /opt/stack -m stack
    fi
    chmod +x /opt/stack
    printf "stack ALL=(ALL) NOPASSWD: ALL\n" >/etc/sudoers.d/stack
    chmod 440 /etc/sudoers.d/stack
    chown -R stack:stack /opt/stack
  '
}

clone_devstack() {
  if lxc exec "$CONTAINER" -- test -d /opt/stack/devstack/.git; then
    return
  fi

  info "Cloning DevStack branch: ${BRANCH}"
  lxc exec "$CONTAINER" -- sudo -u stack -H bash -lc \
    "git clone --depth=1 --branch '${BRANCH}' https://opendev.org/openstack/devstack /opt/stack/devstack"
}

write_local_conf() {
  local host_ip="$1"

  info "Writing DevStack local.conf for ${host_ip}"
  lxc exec "$CONTAINER" -- bash -s -- "$host_ip" "$PASSWORD" <<'EOS'
set -euo pipefail
host_ip="$1"
password="$2"
install -d -o stack -g stack /opt/stack/devstack
cat >/opt/stack/devstack/local.conf <<EOF
[[local|localrc]]
ADMIN_PASSWORD=${password}
DATABASE_PASSWORD=${password}
RABBIT_PASSWORD=${password}
SERVICE_PASSWORD=${password}
HOST_IP=${host_ip}
SERVICE_HOST=${host_ip}
LOGFILE=/opt/stack/logs/stack.sh.log
LOG_COLOR=False
VERBOSE=True
LIBVIRT_TYPE=qemu
ENABLE_VOLUME_BACKING_FILE=True
disable_service tempest
EOF
chown stack:stack /opt/stack/devstack/local.conf
chmod 600 /opt/stack/devstack/local.conf
EOS
}

run_devstack() {
  if openstack_ready; then
    info "ok: local OpenStack API is already reachable"
    return
  fi

  info "Running DevStack stack.sh. This can take 30-60 minutes."
  lxc exec "$CONTAINER" -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && ./stack.sh'
}

write_handoff() {
  local host_ip="$1"

  mkdir -p "$HANDOFF_DIR" "$OPENSTACK_DIR"

  {
    printf 'export OS_AUTH_URL=%q\n' "http://${host_ip}/identity/v3"
    printf 'export OS_PROJECT_NAME=%q\n' "admin"
    printf 'export OS_USERNAME=%q\n' "admin"
    printf 'export OS_PASSWORD=%q\n' "$PASSWORD"
    printf 'export OS_USER_DOMAIN_NAME=%q\n' "Default"
    printf 'export OS_PROJECT_DOMAIN_NAME=%q\n' "Default"
    printf 'export OS_REGION_NAME=%q\n' "RegionOne"
    printf 'export OS_IDENTITY_API_VERSION=%q\n' "3"
  } >"${OPENSTACK_DIR}/openrc.sh"
  chmod 600 "${OPENSTACK_DIR}/openrc.sh"

  {
    printf 'HA_OPENSTACK_CONTAINER=%q\n' "$CONTAINER"
    printf 'OS_AUTH_URL=%q\n' "http://${host_ip}/identity/v3"
    printf 'OS_PROJECT_NAME=%q\n' "admin"
    printf 'OS_USERNAME=%q\n' "admin"
    printf 'OS_REGION_NAME=%q\n' "RegionOne"
    printf 'OPENRC=%q\n' "${OPENSTACK_DIR}/openrc.sh"
  } >"${HANDOFF_DIR}/local-openstack.env"
  chmod 600 "${HANDOFF_DIR}/local-openstack.env"

  info "Wrote ${OPENSTACK_DIR#${PROJECT_ROOT}/}/openrc.sh"
  info "Wrote ${HANDOFF_DIR#${PROJECT_ROOT}/}/local-openstack.env"
}

main() {
  local host_ip

  require_tool lxc
  ensure_container
  host_ip="$(lxd_container_ip)"
  [[ -n "$host_ip" ]] || die "could not resolve LXD container IP"

  prepare_container
  clone_devstack
  write_local_conf "$host_ip"
  ensure_kernel_modules
  run_devstack

  if ! openstack_ready; then
    lxc exec "$CONTAINER" -- bash -lc 'tail -n 160 /opt/stack/logs/stack.sh.log 2>/dev/null || true'
    die "local OpenStack did not become ready"
  fi

  write_handoff "$host_ip"
  info "ok: local OpenStack API is reachable at http://${host_ip}/identity/v3"
}

main "$@"
