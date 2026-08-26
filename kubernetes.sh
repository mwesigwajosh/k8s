#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Kubernetes Node Preparation Script
# Ubuntu 22.04 / 24.04
#
# Prepares a node for kubeadm.
#
# This script:
#   - Disables swap
#   - Loads required kernel modules
#   - Configures sysctl parameters
#   - Installs and configures containerd
#   - Configures systemd cgroups
#   - Adds Kubernetes package repository
#   - Installs kubelet, kubeadm and kubectl
#   - Configures crictl
#
# This script DOES NOT:
#   - Configure Netplan/IP addresses
#   - Run kubeadm init
#   - Run kubeadm join
#   - Install a CNI plugin
# ============================================================


# -----------------------------
# Variables
# -----------------------------

KUBERNETES_MINOR="v1.36"
CRI_SOCKET="unix:///run/containerd/containerd.sock"


# -----------------------------
# Check root
# -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi


echo "=========================================="
echo " Kubernetes node preparation"
echo "=========================================="


# ============================================================
# 1. Disable swap
# ============================================================

echo "[1/9] Disabling swap..."

swapoff -a

# Comment active swap entries in /etc/fstab
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

echo "Swap disabled."


# ============================================================
# 2. Load required kernel modules
# ============================================================

echo "[2/9] Configuring kernel modules..."

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter


# ============================================================
# 3. Configure networking sysctl settings
# ============================================================

echo "[3/9] Configuring Kubernetes networking sysctl..."

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system


# ============================================================
# 4. Install required packages
# ============================================================

echo "[4/9] Installing prerequisites..."

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg \
    apt-transport-https \
    containerd \
    conntrack \
    socat \
    ebtables \
    ethtool


# ============================================================
# 5. Configure containerd
# ============================================================

echo "[5/9] Configuring containerd..."

mkdir -p /etc/containerd

# Generate a clean default configuration
containerd config default > /etc/containerd/config.toml


# Kubernetes + systemd should use the systemd cgroup driver.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml


systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd


# ============================================================
# 6. Verify cgroup v2
# ============================================================

echo "[6/9] Checking cgroup version..."

CGROUP_TYPE="$(stat -fc %T /sys/fs/cgroup/)"

if [[ "$CGROUP_TYPE" == "cgroup2fs" ]]; then
    echo "cgroup v2 detected."
else
    echo
    echo "ERROR: cgroup v2 is not enabled."
    echo "Detected: $CGROUP_TYPE"
    echo
    echo "Kubernetes ${KUBERNETES_MINOR} expects cgroup v2."
    exit 1
fi


# ============================================================
# 7. Add Kubernetes repository
# ============================================================

echo "[7/9] Adding Kubernetes ${KUBERNETES_MINOR} repository..."

mkdir -p -m 755 /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
    | gpg --dearmor \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg


cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF


apt-get update


# ============================================================
# 8. Install Kubernetes components
# ============================================================

echo "[8/9] Installing Kubernetes components..."

apt-get install -y \
    kubelet \
    kubeadm \
    kubectl


# Prevent accidental Kubernetes upgrades
apt-mark hold kubelet kubeadm kubectl


systemctl enable kubelet


# ============================================================
# 9. Configure crictl
# ============================================================

echo "[9/9] Configuring crictl..."

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: ${CRI_SOCKET}
image-endpoint: ${CRI_SOCKET}
timeout: 10
debug: false
EOF


# ============================================================
# Verification
# ============================================================

echo
echo "=========================================="
echo " Verification"
echo "=========================================="

echo
echo "--- Swap ---"
swapon --show || true

echo
echo "--- Kernel modules ---"
lsmod | grep -E 'overlay|br_netfilter' || true

echo
echo "--- IP forwarding ---"
sysctl net.ipv4.ip_forward

echo
echo "--- Containerd ---"
systemctl is-active containerd

echo
echo "--- Container runtime ---"
containerd --version

echo
echo "--- Kubernetes ---"
kubeadm version
kubelet --version
kubectl version --client

echo
echo "--- CRI ---"
crictl info >/dev/null && echo "CRI communication successful."

echo
echo "--- cgroup ---"
echo "cgroup filesystem: $(stat -fc %T /sys/fs/cgroup/)"

echo
echo "=========================================="
echo " Node preparation complete"
echo "=========================================="

echo
echo "Next step:"
echo
echo "  Control plane:"
echo "      kubeadm init ..."
echo
echo "  Worker:"
echo "      kubeadm join ..."
echo