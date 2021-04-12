#!/bin/bash

sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab
swapoff -a
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
systemctl stop firewalld; systemctl disable firewalld

bash -c 'cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF'

sysctl --system

yum -y update && yum install -y epel-release yum-utils device-mapper-persistent-data lvm2 curl wget

yum-config-manager --add-repo \
  https://download.docker.com/linux/centos/docker-ce.repo

yum -y update && yum install -y containerd.io docker-ce-19.03.11 docker-ce-cli-19.03.11

mkdir /etc/docker

bash -c 'cat <<EOF > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF'

mkdir -p /etc/systemd/system/docker.service.d

systemctl daemon-reload
systemctl enable --now docker

mkdir -p /opt/cni/bin
wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/plugins/v0.8.7/cni-plugins-linux-amd64-v0.8.7.tar.gz
tar zxf cni-plugins-linux-amd64-v0.8.7.tar.gz -C /opt/cni/bin/

wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubeadm
wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubelet
wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubectl
mv kubeadm kubelet kubectl /usr/bin/
chmod +x /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl

yum -y install conntrack ebtables socat

mkdir -p /etc/kubernetes/manifests
mkdir -p /usr/lib/systemd/system/kubelet.service.d

bash -c 'cat <<EOF > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/sysconfig/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF'

bash -c 'cat <<EOF > /usr/lib/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF'

systemctl enable kubelet
