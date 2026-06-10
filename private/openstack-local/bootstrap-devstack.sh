#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER="${HA_OPENSTACK_CONTAINER:-ha-openstack}"
IMAGE="${HA_OPENSTACK_LXD_IMAGE:-ubuntu:24.04}"
BRANCH="${HA_DEVSTACK_BRANCH:-master}"
PASSWORD="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
LIBVIRT_TYPE="${HA_DEVSTACK_LIBVIRT_TYPE:-auto}"
PERSISTENT_STORAGE="${HA_OPENSTACK_PERSISTENT_STORAGE:-true}"
PERSISTENT_DIR="${HA_OPENSTACK_PERSISTENT_DIR:-${PROJECT_ROOT}/.ha/openstack/persistent}"
GLANCE_STORE_DIR="${HA_OPENSTACK_GLANCE_STORE_DIR:-${PERSISTENT_DIR}/glance-images}"
NOVA_INSTANCES_DIR="${HA_OPENSTACK_NOVA_INSTANCES_DIR:-${PERSISTENT_DIR}/nova-instances}"
GLANCE_STORE_LXD_DEVICE="${HA_OPENSTACK_GLANCE_STORE_LXD_DEVICE:-hybrid-ai-glance-store}"
NOVA_INSTANCES_LXD_DEVICE="${HA_OPENSTACK_NOVA_INSTANCES_LXD_DEVICE:-hybrid-ai-nova-instances}"
GLANCE_STORE_CONTAINER_DIR="${HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR:-/opt/stack/data/glance/images}"
NOVA_INSTANCES_CONTAINER_DIR="${HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR:-/opt/stack/data/nova/instances}"
GPU_PCI_ALIAS="${HA_OPENSTACK_GPU_PCI_ALIAS:-nvidia-gpu}"
GPU_PCI_VENDOR_ID="$(printf '%s' "${HA_OPENSTACK_GPU_PCI_VENDOR_ID:-10de}" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
GPU_PCI_PRODUCT_ID="${HA_OPENSTACK_GPU_PCI_PRODUCT_ID:-auto}"
GPU_PCI_DEVICE_TYPE="${HA_OPENSTACK_GPU_PCI_DEVICE_TYPE:-type-PF}"
GPU_PCI_NUMA_POLICY="${HA_OPENSTACK_GPU_PCI_NUMA_POLICY:-preferred}"
GPU_BIND_IOMMU_GROUP="${HA_OPENSTACK_GPU_BIND_IOMMU_GROUP:-true}"
GPU_FLAVOR_NAME="${HA_OPENSTACK_GPU_FLAVOR_NAME:-g1.large}"
GPU_FLAVOR_RAM="${HA_OPENSTACK_GPU_FLAVOR_RAM:-8192}"
GPU_FLAVOR_VCPUS="${HA_OPENSTACK_GPU_FLAVOR_VCPUS:-4}"
GPU_FLAVOR_DISK="${HA_OPENSTACK_GPU_FLAVOR_DISK:-80}"
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

lxd_container_running() {
  [[ "$(lxc list "$CONTAINER" -c s --format csv | tr -d '"')" == "RUNNING" ]]
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

desired_lxc_raw_lines() {
  printf '%s\n' \
    'lxc.apparmor.profile=unconfined' \
    'lxc.cap.drop=' \
    'lxc.mount.auto=proc:rw sys:rw cgroup:rw'

  if [[ -d /dev/vfio ]]; then
    printf '%s\n' 'lxc.cgroup2.devices.allow = c 10:196 rwm'
    awk '/vfio/ {print "lxc.cgroup2.devices.allow = c " $1 ":* rwm"}' /proc/devices
  fi
}

ensure_lxc_raw_config() {
  local current
  local line
  local updated

  current="$(lxc config get "$CONTAINER" raw.lxc 2>/dev/null || true)"
  updated="$current"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! printf '%s\n' "$updated" | grep -Fxq "$line"; then
      if [[ -n "$updated" ]]; then
        updated="${updated}"$'\n'"${line}"
      else
        updated="$line"
      fi
    fi
  done < <(desired_lxc_raw_lines)

  if [[ "$updated" != "$current" ]]; then
    if lxd_container_running; then
      info "Stopping ${CONTAINER} to update LXD raw.lxc"
      lxc stop "$CONTAINER" --timeout 60 || lxc stop "$CONTAINER" --force
    fi
    lxc config set "$CONTAINER" raw.lxc "$updated"
    return 0
  fi

  return 1
}

ensure_lxc_config_value() {
  local current
  local key="$1"
  local value="$2"

  current="$(lxc config get "$CONTAINER" "$key" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    return 1
  fi

  if lxd_container_running; then
    info "Stopping ${CONTAINER} to update LXD ${key}"
    lxc stop "$CONTAINER" --timeout 60 || lxc stop "$CONTAINER" --force
  fi
  lxc config set "$CONTAINER" "$key" "$value"
  return 0
}

configure_lxc_devices() {
  local kernel_modules_source

  kernel_modules_source="$(readlink -f /lib/modules)"
  lxc config device add "$CONTAINER" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
  lxc config device remove "$CONTAINER" host-kernel-modules >/dev/null 2>&1 || true
  lxc config device add "$CONTAINER" host-kernel-modules disk source="$kernel_modules_source" path=/usr/lib/modules readonly=true >/dev/null 2>&1 || true
  if [[ -e /dev/kvm ]]; then
    lxc config device add "$CONTAINER" kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
  fi
  if [[ -d /dev/vfio ]]; then
    lxc config device add "$CONTAINER" vfio disk source=/dev/vfio path=/dev/vfio >/dev/null 2>&1 || true
  fi
}

persistent_host_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PROJECT_ROOT" "$path"
  fi
}

configure_persistent_mount() {
  local device="$1"
  local host_dir="$2"
  local container_dir="$3"
  local container_parent source path

  [[ "$PERSISTENT_STORAGE" == "true" ]] || return 0

  mkdir -p "$host_dir"
  container_parent="${container_dir%/*}"
  lxc exec "$CONTAINER" -- mkdir -p "$container_parent" >/dev/null

  source="$(lxc config device get "$CONTAINER" "$device" source 2>/dev/null || true)"
  path="$(lxc config device get "$CONTAINER" "$device" path 2>/dev/null || true)"
  if [[ -n "$source" || -n "$path" ]]; then
    if [[ "$source" != "$host_dir" || "$path" != "$container_dir" ]]; then
      lxc config device remove "$CONTAINER" "$device" >/dev/null
      source=""
      path=""
    fi
  fi
  if [[ -z "$source" && -z "$path" ]]; then
    lxc config device add "$CONTAINER" "$device" disk \
      source="$host_dir" \
      path="$container_dir" >/dev/null
  fi

  lxc exec "$CONTAINER" -- bash -s -- "$container_dir" <<'EOS'
set -euo pipefail
container_dir="$1"
container_parent="${container_dir%/*}"
mkdir -p "$container_dir"
if id stack >/dev/null 2>&1; then
  mkdir -p /opt/stack/data "$container_parent"
  chown stack:stack /opt/stack /opt/stack/data "$container_parent"
  chown -R stack:stack "$container_dir"
fi
chmod 0755 "$container_dir"
EOS
}

configure_persistent_storage() {
  [[ "$PERSISTENT_STORAGE" == "true" ]] || return 0

  info "Configuring persistent OpenStack storage mounts"
  configure_persistent_mount "$GLANCE_STORE_LXD_DEVICE" "$(persistent_host_path "$GLANCE_STORE_DIR")" "$GLANCE_STORE_CONTAINER_DIR"
  configure_persistent_mount "$NOVA_INSTANCES_LXD_DEVICE" "$(persistent_host_path "$NOVA_INSTANCES_DIR")" "$NOVA_INSTANCES_CONTAINER_DIR"
}

ensure_container() {
  local raw_lxc
  local raw_lxc_changed

  raw_lxc=$'lxc.apparmor.profile=unconfined\nlxc.cap.drop=\nlxc.mount.auto=proc:rw sys:rw cgroup:rw'
  ensure_lxd_initialized

  if ! lxc info "$CONTAINER" >/dev/null 2>&1; then
    info "Creating LXD container: ${CONTAINER}"
    lxc init "$IMAGE" "$CONTAINER" \
      -c security.nesting=true \
      -c security.privileged=true \
      -c raw.lxc="$raw_lxc"
    ensure_lxc_raw_config || true
    configure_lxc_devices
    lxc start "$CONTAINER"
  else
    info "Using existing LXD container: ${CONTAINER}"
    ensure_lxc_config_value security.nesting true || true
    ensure_lxc_config_value security.privileged true || true
    raw_lxc_changed=false
    if ensure_lxc_raw_config; then
      raw_lxc_changed=true
    fi
    configure_lxc_devices
    if ! lxd_container_running; then
      lxc start "$CONTAINER"
    elif [[ "$raw_lxc_changed" == "true" ]]; then
      info "Restarting ${CONTAINER} to apply LXD VFIO cgroup rules"
      lxc restart "$CONTAINER"
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
  ' >/dev/null 2>&1
}

detect_gpu_product_id() {
  local vendor_id

  vendor_id="$GPU_PCI_VENDOR_ID"
  lxc exec "$CONTAINER" -- bash -s -- "$vendor_id" <<'EOS'
set -euo pipefail
vendor_id="$1"
for device in /sys/bus/pci/devices/*; do
  vendor="$(cat "${device}/vendor" 2>/dev/null || true)"
  product="$(cat "${device}/device" 2>/dev/null || true)"
  class="$(cat "${device}/class" 2>/dev/null || true)"
  vendor="${vendor#0x}"
  product="${product#0x}"
  vendor="$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$vendor" == "$vendor_id" && "$class" == 03* && -n "$product" ]]; then
    printf '%s\n' "$product"
    exit 0
  fi
done
EOS
}

resolve_gpu_product_id() {
  local product_id

  if [[ "$GPU_PCI_PRODUCT_ID" != "auto" ]]; then
    printf '%s\n' "$(printf '%s' "$GPU_PCI_PRODUCT_ID" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
    return
  fi

  product_id="$(detect_gpu_product_id || true)"
  if [[ -z "$product_id" ]]; then
    return
  fi

  printf '%s\n' "$product_id"
}

bind_gpu_iommu_group_to_vfio() {
  local product_id="$1"

  [[ "$GPU_BIND_IOMMU_GROUP" == "true" ]] || return 0
  [[ -n "$product_id" ]] || return 0

  lxc exec "$CONTAINER" -- bash -s -- "$GPU_PCI_VENDOR_ID" "$product_id" <<'EOS'
set -euo pipefail
vendor_id="$1"
product_id="$2"
bdf=""
for device in /sys/bus/pci/devices/*; do
  vendor="$(cat "${device}/vendor" 2>/dev/null || true)"
  product="$(cat "${device}/device" 2>/dev/null || true)"
  class="$(cat "${device}/class" 2>/dev/null || true)"
  vendor="$(printf '%s' "${vendor#0x}" | tr '[:upper:]' '[:lower:]')"
  product="$(printf '%s' "${product#0x}" | tr '[:upper:]' '[:lower:]')"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$vendor" == "$vendor_id" && "$product" == "$product_id" && "$class" == 03* ]]; then
    bdf="${device##*/}"
    break
  fi
done

if [[ -z "$bdf" ]]; then
  echo "warn: could not find GPU PCI device for ${vendor_id}:${product_id}; skipping VFIO bind"
  exit 0
fi

group_dir="$(readlink -f "/sys/bus/pci/devices/${bdf}/iommu_group" 2>/dev/null || true)"
if [[ -z "$group_dir" || ! -d "$group_dir" ]]; then
  echo "warn: GPU PCI device ${bdf} has no IOMMU group; skipping VFIO bind"
  exit 0
fi

echo "Binding GPU IOMMU group $(basename "$group_dir") to vfio-pci"
modprobe vfio-pci
for member in "${group_dir}"/devices/*; do
  [[ -e "$member" ]] || continue
  member_bdf="${member##*/}"
  vendor="$(cat "${member}/vendor" 2>/dev/null || true)"
  product="$(cat "${member}/device" 2>/dev/null || true)"
  class="$(cat "${member}/class" 2>/dev/null || true)"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$class" == 06* ]]; then
    echo "skip: ${member_bdf} (${vendor}:${product}) is a PCI bridge class 0x${class}"
    continue
  fi
  current_driver="$(basename "$(readlink -f "${member}/driver" 2>/dev/null)" 2>/dev/null || true)"
  if [[ "$current_driver" == "vfio-pci" ]]; then
    echo "ok: ${member_bdf} (${vendor}:${product}) is already bound to vfio-pci"
    continue
  fi

  echo "Binding ${member_bdf} (${vendor}:${product}, driver=${current_driver:-none}) to vfio-pci"
  printf vfio-pci >"${member}/driver_override"
  driver_path="$(readlink -f "${member}/driver" 2>/dev/null || true)"
  if [[ -n "$driver_path" ]]; then
    printf '%s' "$member_bdf" >"${driver_path}/unbind"
  fi
  printf '%s' "$member_bdf" >/sys/bus/pci/drivers_probe
  current_driver="$(basename "$(readlink -f "${member}/driver" 2>/dev/null)" 2>/dev/null || true)"
  [[ "$current_driver" == "vfio-pci" ]] || {
    echo "error: failed to bind ${member_bdf} to vfio-pci; current driver=${current_driver:-none}" >&2
    exit 1
  }
done
EOS
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
  local gpu_product_id="$2"

  info "Writing DevStack local.conf for ${host_ip}"
  lxc exec "$CONTAINER" -- bash -s -- \
    "$host_ip" \
    "$PASSWORD" \
    "$GPU_PCI_ALIAS" \
    "$GPU_PCI_VENDOR_ID" \
    "$gpu_product_id" \
    "$GPU_PCI_DEVICE_TYPE" \
    "$GPU_PCI_NUMA_POLICY" \
    "$LIBVIRT_TYPE" \
    "$NOVA_INSTANCES_CONTAINER_DIR" \
    "$GLANCE_STORE_CONTAINER_DIR" <<'EOS'
set -euo pipefail
host_ip="$1"
password="$2"
gpu_alias="$3"
gpu_vendor_id="$4"
gpu_product_id="$5"
gpu_device_type="$6"
gpu_numa_policy="$7"
requested_libvirt_type="$8"
nova_instances_dir="$9"
glance_store_dir="${10}"
if [[ "$requested_libvirt_type" == "auto" ]]; then
  if [[ -e /dev/kvm ]]; then
    libvirt_type="kvm"
  else
    libvirt_type="qemu"
  fi
else
  libvirt_type="$requested_libvirt_type"
fi
printf 'DevStack libvirt type: %s\n' "$libvirt_type"
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
LIBVIRT_TYPE=${libvirt_type}
ENABLE_VOLUME_BACKING_FILE=True
disable_service tempest

[[post-config|\$NOVA_CONF]]
[DEFAULT]
instances_path = ${nova_instances_dir}
force_raw_images = False

[neutron]
project_domain_name = Default

[[post-config|/etc/nova/nova-cpu.conf]]
[DEFAULT]
instances_path = ${nova_instances_dir}
force_raw_images = False

[neutron]
project_domain_name = Default

[[post-config|\$GLANCE_API_CONF]]
[glance_store]
filesystem_store_datadir = ${glance_store_dir}
EOF
if [[ -n "$gpu_product_id" ]]; then
  cat >>/opt/stack/devstack/local.conf <<EOF

[pci]
EOF
  if [[ -n "$gpu_device_type" ]]; then
    printf 'device_spec = { "vendor_id": "%s", "product_id": "%s", "dev_type": "%s" }\n' \
      "$gpu_vendor_id" "$gpu_product_id" "$gpu_device_type" >>/opt/stack/devstack/local.conf
  else
    printf 'device_spec = { "vendor_id": "%s", "product_id": "%s" }\n' \
      "$gpu_vendor_id" "$gpu_product_id" >>/opt/stack/devstack/local.conf
  fi
  if [[ -n "$gpu_device_type" ]]; then
    printf 'alias = { "name": "%s", "vendor_id": "%s", "product_id": "%s", "device_type": "%s", "numa_policy": "%s" }\n' \
      "$gpu_alias" "$gpu_vendor_id" "$gpu_product_id" "$gpu_device_type" "$gpu_numa_policy" >>/opt/stack/devstack/local.conf
  else
    printf 'alias = { "name": "%s", "vendor_id": "%s", "product_id": "%s", "numa_policy": "%s" }\n' \
      "$gpu_alias" "$gpu_vendor_id" "$gpu_product_id" "$gpu_numa_policy" >>/opt/stack/devstack/local.conf
  fi
  cat >>/opt/stack/devstack/local.conf <<EOF

[filter_scheduler]
available_filters = nova.scheduler.filters.all_filters
enabled_filters = ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,SameHostFilter,DifferentHostFilter,PciPassthroughFilter
EOF
fi
chown stack:stack /opt/stack/devstack/local.conf
chmod 600 /opt/stack/devstack/local.conf
EOS
}

configure_gpu_passthrough() {
  local gpu_product_id="$1"

  [[ -n "$gpu_product_id" ]] || return 0

  info "Configuring Nova GPU passthrough alias ${GPU_PCI_ALIAS} for ${GPU_PCI_VENDOR_ID}:${gpu_product_id}"
  lxc exec "$CONTAINER" -- sudo -u stack -H bash -s -- \
    "$GPU_PCI_ALIAS" \
    "$GPU_PCI_VENDOR_ID" \
    "$gpu_product_id" \
    "$GPU_PCI_DEVICE_TYPE" \
    "$GPU_PCI_NUMA_POLICY" \
    "$GPU_FLAVOR_NAME" \
    "$GPU_FLAVOR_RAM" \
    "$GPU_FLAVOR_VCPUS" \
    "$GPU_FLAVOR_DISK" <<'EOS'
set -euo pipefail
gpu_alias="$1"
gpu_vendor_id="$2"
gpu_product_id="$3"
gpu_device_type="$4"
gpu_numa_policy="$5"
gpu_flavor_name="$6"
gpu_flavor_ram="$7"
gpu_flavor_vcpus="$8"
gpu_flavor_disk="$9"

cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
source functions-common
set -u

if [[ -n "$gpu_device_type" ]]; then
  device_spec="{ \"vendor_id\": \"${gpu_vendor_id}\", \"product_id\": \"${gpu_product_id}\", \"dev_type\": \"${gpu_device_type}\" }"
  alias_spec="{ \"name\": \"${gpu_alias}\", \"vendor_id\": \"${gpu_vendor_id}\", \"product_id\": \"${gpu_product_id}\", \"device_type\": \"${gpu_device_type}\", \"numa_policy\": \"${gpu_numa_policy}\" }"
else
  device_spec="{ \"vendor_id\": \"${gpu_vendor_id}\", \"product_id\": \"${gpu_product_id}\" }"
  alias_spec="{ \"name\": \"${gpu_alias}\", \"vendor_id\": \"${gpu_vendor_id}\", \"product_id\": \"${gpu_product_id}\", \"numa_policy\": \"${gpu_numa_policy}\" }"
fi
filters="ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,SameHostFilter,DifferentHostFilter,PciPassthroughFilter"

for conf in /etc/nova/nova.conf /etc/nova/nova-cpu.conf; do
  [[ -f "$conf" ]] || continue
  iniset -sudo "$conf" pci device_spec "$device_spec"
  iniset -sudo "$conf" pci alias "$alias_spec"
  iniset -sudo "$conf" filter_scheduler available_filters "nova.scheduler.filters.all_filters"
  iniset -sudo "$conf" filter_scheduler enabled_filters "$filters"
done

if ! openstack flavor show "$gpu_flavor_name" >/dev/null 2>&1; then
  openstack flavor create \
    --ram "$gpu_flavor_ram" \
    --vcpus "$gpu_flavor_vcpus" \
    --disk "$gpu_flavor_disk" \
    "$gpu_flavor_name" >/dev/null
fi
openstack flavor set \
  --property "pci_passthrough:alias=${gpu_alias}:1" \
  --property "hw:pci_numa_affinity_policy=${gpu_numa_policy}" \
  --property "hw_rng:allowed=True" \
  "$gpu_flavor_name"

sudo systemctl restart devstack@n-api.service devstack@n-sch.service devstack@n-super-cond.service devstack@n-cpu.service
EOS
}

run_devstack() {
  local attempt

  for attempt in {1..30}; do
    if openstack_ready; then
      info "ok: local OpenStack API is already reachable"
      return
    fi
    if [[ "$attempt" -lt 30 ]]; then
      sleep 10
    fi
  done

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

  info "Wrote ${OPENSTACK_DIR#"${PROJECT_ROOT}"/}/openrc.sh"
  info "Wrote ${HANDOFF_DIR#"${PROJECT_ROOT}"/}/local-openstack.env"
}

main() {
  local host_ip
  local gpu_product_id

  require_tool lxc
  ensure_container
  host_ip="$(lxd_container_ip)"
  [[ -n "$host_ip" ]] || die "could not resolve LXD container IP"
  gpu_product_id="$(resolve_gpu_product_id)"
  if [[ -n "$gpu_product_id" ]]; then
    info "Detected GPU PCI device: ${GPU_PCI_VENDOR_ID}:${gpu_product_id}"
  else
    info "warn: no NVIDIA display/3D PCI device detected; Nova GPU passthrough will be skipped"
  fi
  bind_gpu_iommu_group_to_vfio "$gpu_product_id"

  prepare_container
  if ! openstack_ready; then
    configure_persistent_storage
  fi
  clone_devstack
  write_local_conf "$host_ip" "$gpu_product_id"
  ensure_kernel_modules
  run_devstack

  if ! openstack_ready; then
    lxc exec "$CONTAINER" -- bash -lc 'tail -n 160 /opt/stack/logs/stack.sh.log 2>/dev/null || true'
    die "local OpenStack did not become ready"
  fi

  configure_gpu_passthrough "$gpu_product_id"
  write_handoff "$host_ip"
  info "ok: local OpenStack API is reachable at http://${host_ip}/identity/v3"
}

main "$@"
