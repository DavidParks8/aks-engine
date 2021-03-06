#!/bin/bash
ERR_SYSTEMCTL_STOP_FAIL=3
ERR_SYSTEMCTL_START_FAIL=4
ERR_CLOUD_INIT_TIMEOUT=5
ERR_FILE_WATCH_TIMEOUT=6
ERR_HOLD_WALINUXAGENT=7
ERR_RELEASE_HOLD_WALINUXAGENT=8
ERR_APT_INSTALL_TIMEOUT=9
ERR_ETCD_DATA_DIR_NOT_FOUND=10
ERR_ETCD_RUNNING_TIMEOUT=11
ERR_ETCD_DOWNLOAD_TIMEOUT=12
ERR_ETCD_VOL_MOUNT_FAIL=13
ERR_ETCD_START_TIMEOUT=14
ERR_ETCD_CONFIG_FAIL=15
ERR_DOCKER_INSTALL_TIMEOUT=20
ERR_DOCKER_DOWNLOAD_TIMEOUT=21
ERR_DOCKER_KEY_DOWNLOAD_TIMEOUT=22
ERR_DOCKER_APT_KEY_TIMEOUT=23
ERR_DOCKER_START_FAIL=24
ERR_MOBY_APT_LIST_TIMEOUT=25
ERR_MS_GPG_KEY_DOWNLOAD_TIMEOUT=26
ERR_MOBY_INSTALL_TIMEOUT=27
ERR_K8S_RUNNING_TIMEOUT=30
ERR_K8S_DOWNLOAD_TIMEOUT=31
ERR_KUBECTL_NOT_FOUND=32
ERR_IMG_DOWNLOAD_TIMEOUT=33
ERR_KUBELET_START_FAIL=34
ERR_CONTAINER_IMG_PULL_TIMEOUT=35
ERR_CNI_DOWNLOAD_TIMEOUT=41
ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT=42
ERR_MS_PROD_DEB_PKG_ADD_FAIL=43
ERR_SYSTEMD_INSTALL_FAIL=48
ERR_MODPROBE_FAIL=49
ERR_OUTBOUND_CONN_FAIL=50
ERR_K8S_API_SERVER_CONN_FAIL=51
ERR_K8S_API_SERVER_DNS_LOOKUP_FAIL=52
ERR_K8S_API_SERVER_AZURE_DNS_LOOKUP_FAIL=53
ERR_KATA_KEY_DOWNLOAD_TIMEOUT=60
ERR_KATA_APT_KEY_TIMEOUT=61
ERR_KATA_INSTALL_TIMEOUT=62
ERR_CONTAINERD_DOWNLOAD_TIMEOUT=70
ERR_CUSTOM_SEARCH_DOMAINS_FAIL=80
ERR_GPU_DRIVERS_START_FAIL=84
ERR_GPU_DRIVERS_INSTALL_TIMEOUT=85
ERR_GPU_DRIVERS_CONFIG=86
ERR_SGX_DRIVERS_INSTALL_TIMEOUT=90
ERR_SGX_DRIVERS_START_FAIL=91
ERR_SGX_DRIVERS_NOT_SUPPORTED=92
ERR_SGX_DRIVERS_CHECKSUM_MISMATCH=93
ERR_APT_DAILY_TIMEOUT=98
ERR_APT_UPDATE_TIMEOUT=99
ERR_CSE_PROVISION_SCRIPT_NOT_READY_TIMEOUT=100
ERR_APT_DIST_UPGRADE_TIMEOUT=101
ERR_APT_PURGE_FAIL=102
ERR_SYSCTL_RELOAD=103
ERR_CIS_ASSIGN_ROOT_PW=111
ERR_CIS_ASSIGN_FILE_PERMISSION=112
ERR_PACKER_COPY_FILE=113
ERR_CIS_APPLY_PASSWORD_CONFIG=115
ERR_VHD_FILE_NOT_FOUND=124
ERR_VHD_BUILD_ERROR=125
ERR_AZURE_STACK_GET_ARM_TOKEN=120
ERR_AZURE_STACK_GET_NETWORK_CONFIGURATION=121
ERR_AZURE_STACK_GET_SUBNET_PREFIX=122
ERR_IOVISOR_KEY_DOWNLOAD_TIMEOUT=166
ERR_IOVISOR_APT_KEY_TIMEOUT=167
ERR_BCC_INSTALL_TIMEOUT=168
ERR_BPFTRACE_BIN_DOWNLOAD_FAIL=169
ERR_BPFTRACE_TOOLS_DOWNLOAD_FAIL=170

OS=$(sort -r /etc/*-release | gawk 'match($0, /^(ID=(.*))$/, a) { print toupper(a[2] a[3]); exit }')
UBUNTU_OS_NAME="UBUNTU"
RHEL_OS_NAME="RHEL"
DEBIAN_OS_NAME="DEBIAN"
if ! echo "${UBUNTU_OS_NAME} ${RHEL_OS_NAME} ${DEBIAN_OS_NAME}" | grep -q "${OS}"; then
    OS=$(sort -r /etc/*-release | gawk 'match($0, /^(ID_LIKE=(.*))$/, a) { print toupper(a[2] a[3]); exit }')
fi
KUBECTL=/usr/local/bin/kubectl
DOCKER=/usr/bin/docker
GPU_DV=418.40.04
GPU_DEST=/usr/local/nvidia
NVIDIA_DOCKER_VERSION=2.0.3
DOCKER_VERSION=1.13.1-1
NVIDIA_CONTAINER_RUNTIME_VERSION=2.0.0

configure_prerequisites() {
    ip_forward_path=/proc/sys/net/ipv4/ip_forward
    ip_forward_setting="net.ipv4.ip_forward=0"
    sysctl_conf=/etc/sysctl.conf
    if ! grep -qE "^1$" ${ip_forward_path}; then
        echo 1 > ${ip_forward_path}
    fi
    if grep -qE "${ip_forward_setting}" ${sysctl_conf}; then
        sed -i '/^net.ipv4.ip_forward=0$/d' ${sysctl_conf}
    fi
}

aptmarkWALinuxAgent() {
    wait_for_apt_locks
    retrycmd_if_failure 120 5 25 apt-mark $1 walinuxagent || \
    if [[ "$1" == "hold" ]]; then
        exit $ERR_HOLD_WALINUXAGENT
    elif [[ "$1" == "unhold" ]]; then
        exit $ERR_RELEASE_HOLD_WALINUXAGENT
    fi
}

retrycmd_if_failure() {
    retries=$1; wait_sleep=$2; timeout=$3; shift && shift && shift
    for i in $(seq 1 $retries); do
        timeout $timeout ${@} && break || \
        if [ $i -eq $retries ]; then
            echo Executed \"$@\" $i times;
            return 1
        else
            sleep $wait_sleep
        fi
    done
    echo Executed \"$@\" $i times;
}
retrycmd_if_failure_no_stats() {
    retries=$1; wait_sleep=$2; timeout=$3; shift && shift && shift
    for i in $(seq 1 $retries); do
        timeout $timeout ${@} && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
        fi
    done
}
retrycmd_get_tarball() {
    tar_retries=$1; wait_sleep=$2; tarball=$3; url=$4
    echo "${tar_retries} retries"
    for i in $(seq 1 $tar_retries); do
        tar -tzf $tarball && break || \
        if [ $i -eq $tar_retries ]; then
            return 1
        else
            timeout 60 curl -fsSL $url -o $tarball
            sleep $wait_sleep
        fi
    done
}
retrycmd_get_executable() {
    retries=$1; wait_sleep=$2; filepath=$3; url=$4; validation_args=$5
    echo "${retries} retries"
    for i in $(seq 1 $retries); do
        $filepath $validation_args && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            timeout 30 curl -fsSL $url -o $filepath
            chmod +x $filepath
            sleep $wait_sleep
        fi
    done
}
wait_for_file() {
    retries=$1; wait_sleep=$2; filepath=$3
    paved=/opt/azure/cloud-init-files.paved
    grep -Fq "${filepath}" $paved && return 0
    for i in $(seq 1 $retries); do
        grep -Fq '#EOF' $filepath && break
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
        fi
    done
    sed -i "/#EOF/d" $filepath
    echo $filepath >> $paved
}
wait_for_apt_locks() {
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo 'Waiting for release of apt locks'
        sleep 3
    done
}
apt_get_update() {
    retries=10
    apt_update_output=/tmp/apt-get-update.out
    for i in $(seq 1 $retries); do
        wait_for_apt_locks
        export DEBIAN_FRONTEND=noninteractive
        dpkg --configure -a --force-confdef
        apt-get -f -y install
        ! (apt-get update 2>&1 | tee $apt_update_output | grep -E "^([WE]:.*)|([eE]rr.*)$") && \
        cat $apt_update_output && break || \
        cat $apt_update_output
        if [ $i -eq $retries ]; then
            return 1
        else sleep 5
        fi
    done
    echo Executed apt-get update $i times
    wait_for_apt_locks
}
apt_get_install() {
    retries=$1; wait_sleep=$2; timeout=$3; shift && shift && shift
    for i in $(seq 1 $retries); do
        wait_for_apt_locks
        export DEBIAN_FRONTEND=noninteractive
        dpkg --configure -a --force-confdef
        apt-get install -o Dpkg::Options::="--force-confold" --no-install-recommends -y ${@} && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
            apt_get_update
        fi
    done
    echo Executed apt-get install --no-install-recommends -y \"$@\" $i times;
    wait_for_apt_locks
}
apt_get_purge() {
    retries=20; wait_sleep=30; timeout=120
    for package in $@; do
        if apt list --installed | grep $package; then
            for i in $(seq 1 $retries); do
                wait_for_apt_locks
                export DEBIAN_FRONTEND=noninteractive
                dpkg --configure -a --force-confdef
                apt-get purge -o Dpkg::Options::="--force-confold" -y $package && break || \
                if [ $i -eq $retries ]; then
                    return 1
                else
                    sleep $wait_sleep
                fi
            done
        fi
    done
    echo Executed apt-get purge -y \"$package\" $i times;
    wait_for_apt_locks
}
apt_get_dist_upgrade() {
  retries=10
  apt_dist_upgrade_output=/tmp/apt-get-dist-upgrade.out
  for i in $(seq 1 $retries); do
    wait_for_apt_locks
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confdef
    apt-get -f -y install
    apt-mark showhold
    ! (apt-get dist-upgrade -y 2>&1 | tee $apt_dist_upgrade_output | grep -E "^([WE]:.*)|([eE]rr.*)$") && \
    cat $apt_dist_upgrade_output && break || \
    cat $apt_dist_upgrade_output
    if [ $i -eq $retries ]; then
      return 1
    else sleep 5
    fi
  done
  echo Executed apt-get dist-upgrade $i times
  wait_for_apt_locks
}
systemctl_restart() {
    retries=$1; wait_sleep=$2; timeout=$3 svcname=$4
    for i in $(seq 1 $retries); do
        timeout $timeout systemctl daemon-reload
        timeout $timeout systemctl restart $svcname && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
        fi
    done
}
systemctl_stop() {
    retries=$1; wait_sleep=$2; timeout=$3 svcname=$4
    for i in $(seq 1 $retries); do
        timeout $timeout systemctl daemon-reload
        timeout $timeout systemctl stop $svcname && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
        fi
    done
}
sysctl_reload() {
    retries=$1; wait_sleep=$2; timeout=$3
    for i in $(seq 1 $retries); do
        timeout $timeout sysctl --system && break || \
        if [ $i -eq $retries ]; then
            return 1
        else
            sleep $wait_sleep
        fi
    done
}
version_gte() {
  test "$(printf '%s\n' "$@" | sort -rV | head -n 1)" == "$1"
}

#HELPERSEOF
