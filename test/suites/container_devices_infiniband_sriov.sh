# Activating Infiniband VFs:
# Mellanox example:
# wget http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.6-1.0.1.1/MLNX_OFED_LINUX-4.6-1.0.1.1-ubuntu18.04-x86_64.tgz
# tar zxvf MLNX_OFED_LINUX-4.6-1.0.1.1-ubuntu18.04-x86_64.tgz
# cd MLNX_OFED_LINUX-4.6-1.0.1.1-ubuntu18.04-x86_64/
# sudo ./mlnxofedinstall  --force
# sudo mlxconfig --yes -d /dev/mst/mt4099_pciconf0 set LINK_TYPE_P2=2
# echo "options mlx4_core num_vfs=4 probe_vf=4" | sudo tee /etc/modprobe.d/mellanox.conf
# reboot
test_container_devices_ib_sriov() {
  ensure_import_testimage
  ensure_has_localhost_remote "${LXD_ADDR}"

  parent=${LXD_IB_SRIOV_PARENT:-""}

  if [ "$parent" = "" ]; then
    echo "==> SKIP: No SR-IOV IB parent specified"
    return
  fi

  ctName="nt$$"

  # Set a known start point config
  ip link set "${parent}" up

  # Record how many nics we started with.
  startNicCount=$(find /sys/class/net | wc -l)

  # Test basic container with SR-IOV IB. Add 2 devices to check reservation system works.
  lxc init testimage "${ctName}"
  lxc config device add "${ctName}" eth0 infiniband \
    nictype=sriov \
    parent="${parent}" \
    mtu=1500
  lxc config device add "${ctName}" eth1 infiniband \
    nictype=sriov \
    parent="${parent}" \
    mtu=1500
  lxc start "${ctName}"

  # Check host devices are created.
  ibDevCount=$(find "${LXD_DIR}"/devices/"${ctName}" -type c | wc -l)
  if [ "$ibDevCount" != "6" ]; then
    echo "unexpected IB device count after creation"
    false
  fi

  # Check devices are mounted inside container.
  ibMountCount=$(lxc exec "${ctName}" -- mount | grep -c infiniband)
  if [ "$ibMountCount" != "6" ]; then
    echo "unexpected IB mount count after creation"
    false
  fi

  # Check unprivileged cgroup device rule count.
  cgroupDeviceCount=$(wc -l < /sys/fs/cgroup/devices/lxc.payload/"${ctName}"/devices.list)
  if [ "$cgroupDeviceCount" != "1" ]; then
    echo "unexpected unprivileged cgroup device rule count after creation"
    false
  fi

  # Check ownership of char devices.
  nonRootDeviceCount=$(find "${LXD_DIR}"/devices/"${ctName}" ! -uid 0 -type c | wc -l)
  if [ "$nonRootDeviceCount" != "6" ]; then
    echo "unexpected unprivileged non-root device ownership count after creation"
    false
  fi

  # Check volatile cleanup on stop.
  lxc stop -f "${ctName}"
  if lxc config show "${ctName}" | grep volatile.eth0 | grep -v volatile.eth0.name ; then
    echo "unexpected volatile key remains"
    false
  fi

  # Check host devices are removed.
  ibDevCount=$(find "${LXD_DIR}"/devices/"${ctName}" -type c | wc -l)
  if [ "$ibDevCount" != "0" ]; then
    echo "unexpected IB device count after removal"
    false
  fi

  # Check privileged cgroup rules and device ownership.
  lxc config set "${ctName}" security.privileged true
  lxc start "${ctName}"

  # Check privileged cgroup device rule count.
  cgroupDeviceCount=$(wc -l < /sys/fs/cgroup/devices/lxc.payload/"${ctName}"/devices.list)
  if [ "$cgroupDeviceCount" != "19" ]; then
    echo "unexpected privileged cgroup device rule count after creation"
    false
  fi

  # Check ownership of char devices.
  rootDeviceCount=$(find "${LXD_DIR}"/devices/"${ctName}" -uid 0 -type c | wc -l)
  if [ "$rootDeviceCount" != "6" ]; then
    echo "unexpected privileged root device ownership count after creation"
    false
  fi

  lxc stop -f "${ctName}"

  lxc config device remove "${ctName}" eth0
  lxc config device remove "${ctName}" eth1

  # Test hotplugging.
  lxc start "${ctName}"
  lxc config device add "${ctName}" eth0 infiniband \
    nictype=sriov \
    parent="${parent}" \
    mtu=1500

  # Check host devices are created.
  ibDevCount=$(find "${LXD_DIR}"/devices/"${ctName}" -type c | wc -l)
  if [ "$ibDevCount" != "3" ]; then
    echo "unexpected IB device count after creation"
    false
  fi

  # Test hot unplug.
  lxc config device remove "${ctName}" eth0

  # Check host devices are removed.
  ibDevCount=$(find "${LXD_DIR}"/devices/"${ctName}" -type c | wc -l)
  if [ "$ibDevCount" != "0" ]; then
    echo "unexpected IB device count after removal"
    false
  fi

  # Check devices are unmounted inside container.
  if lxc exec "${ctName}" -- mount | grep -c infiniband ; then
    echo "unexpected IB mounts remain after removal"
    false
  fi

  lxc delete -f "${ctName}"

  # Check we haven't left any NICS lying around.
  endNicCount=$(find /sys/class/net | wc -l)
  if [ "$startNicCount" != "$endNicCount" ]; then
    echo "leftover NICS detected"
    false
  fi
}
