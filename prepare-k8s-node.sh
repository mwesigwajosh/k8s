#!/usr/bin/env bash
#
# prepare-k8s-node.sh
# Prepares a Debian/Ubuntu host to join a Kubernetes cluster
# (as a control-plane node via `kubeadm init` or a worker via `kubeadm join`).
#
# Usage:
#   sudo ./prepare-k8s-node.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Target Kubernetes minor version (must match a channel published at pkgs.k8s.io)
K8S_VERSION="v1.37"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script with sudo or as root." >&2
  exit 1
fi

echo "===> [1/6] Disabling Swap..."
swapoff -a
# Comment out any swap line in fstab (idempotent: re-commenting an already
# commented line is a no-op).
sed -i '/ swap / s/^\([^#]\)/#\1/' /etc/fstab

echo "===> [2/6] Loading Kernel Modules..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "===> [3/6] Setting Sysctl Parameters..."
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "===> [4/6] Installing and Configuring Containerd..."
apt-get update -y
apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable the SystemdCgroup driver (required to match kubelet's default
# cgroup driver on modern systemd-based distros).
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "===> [5/6] Configuring Firewall Rules (UFW)..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 6443/tcp    comment 'K8s API Server'
    ufw allow 2379:2380/tcp comment 'etcd cluster API'
    ufw allow 10250/tcp   comment 'Kubelet API'
    ufw allow 10259/tcp   comment 'Kube Scheduler'
    ufw allow 10257/tcp   comment 'Kube Controller Manager'
    ufw allow 179/tcp     comment 'Calico BGP'
    ufw allow 4789/udp    comment 'Overlay Network (Calico/Flannel VXLAN)'
else
    echo "UFW is not installed. Skipping firewall rules."
fi

echo "===> [6/6] Installing Kubernetes Components (${K8S_VERSION})..."
apt-get install -y apt-transport-https ca-certificates curl gpg

mkdir -p -m 755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo ""
echo "================================================================="
echo "  Node preparation complete!"
echo "  You can now run 'sudo kubeadm init' (Control Plane) "
echo "  or 'sudo kubeadm join ...' (Worker Node)."
echo "================================================================="
