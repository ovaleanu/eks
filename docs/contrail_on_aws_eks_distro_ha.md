# Install Contrail Networking as a CNI on AWS EKS Distro

Couple of months ago, AWS introduced EKS Distro (EKS-D) a Kubernetes distribution based on and used by Amazon Elastic Kubernetes Service (Amazon EKS). With EKS-D, users can rely on the same versions of Kubernetes and its dependencies deployed on Amazon EKS and other cloud platforms (public/private).

In EKS on AWS EC2 setting a managed control plane — control plane runs in an account managed by AWS, and the Kubernetes API is exposed via the AWS EKS endpoint associated with your cluster. Each AWS EKS cluster control plane is single-tenant and unique, and runs on its own set of AWS EC2 instances.
Users can choose between a self-managed data plane or a aws managed data plane using node groups

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-1-components.png)

Users cannot access the contol plane components. They can access only the daemonsets deployed on nodes and the workloads.
Contrail is deployed on AWS EKS replacing aws node daemonsets. The installation procedure for how to install Contrail on EKS is [here](https://www.juniper.net/documentation/en_US/contrail20/topics/task/installation/how-to-install-contrail-aws-eks.html).

In here I will focus on the integration of Contrail with EKS-D.

In EKS-D all the components are managed by the users. Creating the cluster can be done in different ways. A nomber of [AWS Partners](https://distro.eks.amazonaws.com/community/partners/) are already providing various installation methods.
All the LCM of the nodes, HA control plane, etc should be done by the users.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-2-components.png)

For this demo I will use `kubeadm` to bootstrap the cluster.

Comparing with AWS EKS, in EKS-D users have access to all the components, control plane and other worloads running on data plane.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-3-components.png)

For this demo, I have prepared 3 x VMs for control plane, 3 x VMs for data plane and 1 x VM with HAproxy for Kubernetes API server.

For the HAproxy I have the following configuration in `/etc/haproy/haproxy.cfg`

```
listen stats
         bind    *:9000
         mode    http
         stats   enable
         stats   hide-version
         stats   uri       /stats
         stats   refresh   30s
         stats   realm     Haproxy\ Statistics
         stats   auth      Admin:Password

       ############## Configure HAProxy Secure Frontend #############
       frontend k8s-api-https-proxy
           bind :6443
           mode tcp
           tcp-request inspect-delay 5s
           tcp-request content accept if { req.ssl_hello_type 1 }
           default_backend k8s-api-https

       ############## Configure HAProxy SecureBackend #############
       backend k8s-api-https
           balance source
           mode tcp
           option tcplog
           option tcp-check
           default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
           server 5b4s34-vm3 10.87.68.153:6443 check
           server 5b4s34-vm4 10.87.68.154:6443 check
           server 5b4s34-vm5 10.87.68.155:6443 check
```

Port 6443 is opened and listening

```
# netstat -tlnp | grep 6443
tcp        0      0 0.0.0.0:6443            0.0.0.0:*               LISTEN      3477/haproxy
```

Next, I will update the OS on the control plane nodes and install EKS-D. The following commands should be performed in parallel on all the control plane nodes.

[Tmux](https://github.com/tmux/tmux/wiki) can be used to run commands on multiple compute instances at the same time. Labs in this tutorial may require running the same commands across multiple compute instances, in those cases consider using tmux and splitting a window into multiple panes with synchronize-panes enabled to speed up the provisioning process.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-4-components.png)

_Enable synchronize-panes by pressing ctrl+b followed by shift+:. Next type set synchronize-panes on at the prompt. To disable synchronization: set synchronize-panes off._

### Updating the OS configurations

Perform the following commands as `root`
```
$ sudo su -
```

Disable swap to prevent memory allocation issues
```
# sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
# swapoff -a
```

Disable SELinux and firewalld
```
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
systemctl stop firewalld; systemctl disable firewalld
```

Enable the module for cluster communication
```
# cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# sysctl --system
```
Install the necessary packages
```
# yum -y update && yum install -y epel-release yum-utils device-mapper-persistent-data lvm2 curl wget
```
Add the Docker repository
```
# yum-config-manager --add-repo \
  https://download.docker.com/linux/centos/docker-ce.repo
```
Install Docker CE
```
# yum -y update && yum install -y containerd.io-1.2.13 docker-ce-19.03.11 docker-ce-cli-19.03.11
```
Create `/etc/docker`
```
# mkdir /etc/docker
```
Set up the Docker daemon
```
# cat <<EOF > /etc/docker/daemon.json
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
EOF
```

Create /etc/systemd/system/docker.service.d
```
# mkdir -p /etc/systemd/system/docker.service.d
```
Restart docker
```
# systemctl daemon-reload
# systemctl enable --now docker
```
Check docker service
```
# systemctl status docker
```

### Install EKS-D

Continue in the tmux sessions running the commands in parallel on all control plane nodes

Download and install K8s CNI from AWS EKS-D repo.
```
# mkdir -p /opt/cni/bin
# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/plugins/v0.8.7/cni-plugins-linux-amd64-v0.8.7.tar.gz
# tar zxf cni-plugins-linux-amd64-v0.8.7.tar.gz -C /opt/cni/bin/
```

Download kubeadm, kubelet, and kubectl from the AWS EKS-D repo
```
# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubeadm
# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubelet
# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubectl
# mv kubeadm kubelet kubectl /usr/bin/
# chmod +x /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl
```
Install dependencies for `kubelet`
```
# yum -y install conntrack ebtables socat
```
Create directories and files needed by kubeadm and kubelet
```
# mkdir -p /etc/kubernetes/manifests
# mkdir -p /usr/lib/systemd/system/kubelet.service.d

# cat <<EOF > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
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
EOF

# cat <<EOF > /usr/lib/systemd/system/kubelet.service
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
EOF

# systemctl enable kubelet
```

Download the EKS-D Docker images needed for the control plane from the Amazon ECR public repo
```
# docker pull public.ecr.aws/eks-distro/etcd-io/etcd:v3.4.14-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/kubernetes/pause:v1.18.9-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/kubernetes/kube-scheduler:v1.18.9-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/kubernetes/kube-proxy:v1.18.9-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/kubernetes/kube-apiserver:v1.18.9-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/kubernetes/kube-controller-manager:v1.18.9-eks-1-18-1
# docker pull public.ecr.aws/eks-distro/coredns/coredns:v1.7.0-eks-1-18-1
```

Kubeadm is using some hardcoded values for pause and coredns. I need to change the tag for them
```
# docker tag public.ecr.aws/eks-distro/kubernetes/pause:v1.18.9-eks-1-18-1 public.ecr.aws/eks-distro/kubernetes/pause:3.2
# docker tag public.ecr.aws/eks-distro/coredns/coredns:v1.7.0-eks-1-18-1 public.ecr.aws/eks-distro/kubernetes/coredns:1.6.7
```

I have the following images downloaded on all thre nodes
```
# docker images
REPOSITORY                                                     TAG                  IMAGE ID            CREATED             SIZE
public.ecr.aws/eks-distro/kubernetes/pause                     3.2                  ff45cda5b28a        2 months ago        702kB
public.ecr.aws/eks-distro/kubernetes/pause                     v1.18.9-eks-1-18-1   ff45cda5b28a        2 months ago        702kB
public.ecr.aws/eks-distro/kubernetes/kube-proxy                v1.18.9-eks-1-18-1   7b3d7533dd46        2 months ago        580MB
public.ecr.aws/eks-distro/kubernetes/kube-scheduler            v1.18.9-eks-1-18-1   3f6c60b31475        2 months ago        504MB
public.ecr.aws/eks-distro/kubernetes/kube-controller-manager   v1.18.9-eks-1-18-1   b50f3c224c59        2 months ago        573MB
public.ecr.aws/eks-distro/kubernetes/kube-apiserver            v1.18.9-eks-1-18-1   a2ea61c746e1        2 months ago        583MB
public.ecr.aws/eks-distro/etcd-io/etcd                         v3.4.14-eks-1-18-1   e77eead05c5e        2 months ago        498MB
public.ecr.aws/eks-distro/coredns/coredns                      v1.7.0-eks-1-18-1    6dbf7f0180db        2 months ago        46.7MB
public.ecr.aws/eks-distro/kubernetes/coredns                   1.6.7                6dbf7f0180db        2 months ago        46.7MB
```

Repeat all these steps on the workers as well! You can use this script for this.

At this point `set synchronize-panes off` in tmux session. On the first control plane node as `root` create the following kubeadm config file.

```
# cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
controlPlaneEndpoint: "5b4s34-vm1.englab.juniper.net:6443"
networking:
  podSubnet: "10.32.0.0/12"
etcd:
  local:
    imageRepository: public.ecr.aws/eks-distro/etcd-io
    imageTag: v3.4.14-eks-1-18-1
    extraArgs:
      listen-peer-urls: "https://0.0.0.0:2380"
      listen-client-urls: "https://0.0.0.0:2379"
imageRepository: public.ecr.aws/eks-distro/kubernetes
kubernetesVersion: v1.18.9-eks-1-18-1
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.87.68.153"
EOF
```


`advertiseAddress` is used to set the advertise address for this particular control plane node’s API server. `controlPlaneEndpoint` is used to set the load balancer’s endpoint for nodes to reach control-plane API server.

Initialize the Kubernetes cluster with the configuration file
```
# kubeadm init --config kubeadm-config.yaml --upload-certs
```

For the rest of the control plane nodes you need to specify node ip address with parameter `--apiserver-advertise-address`. Your command for joining the rest of the control plane ndoes will be like this
```
kubeadm join 5b4s34-vm1.englab.juniper.net:6443 --token <token> \
    --discovery-token-ca-cert-hash <discovery-token-ca-cert-hash> \
    --control-plane --certificate-key <certificate-key> \
    --apiserver-advertise-address=<current_node_IP>
```

For the data plane nodes use there is no need to specify IP address. Use only kubeadm join command generated.

```
kubeadm join 5b4s34-vm1.englab.juniper.net:6443 --token <token> \
    --discovery-token-ca-cert-hash <discovery-token-ca-cert-hash>
```

On the first control plane node as non-root, run the following commands

```
$ mkdir -p $HOME/.kube
$ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

The EKS-D cluster is ready. You only need to apply the contrail single yaml as described in this [Wiki](https://github.com/ovaleanujnpr/kubernetes/wiki/Installing-Kubernetes-with-Contrail#on-the-master).
```
$ kubectl get nodes -o wide
NAME                            STATUS     ROLES    AGE     VERSION              INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                KERNEL-VERSION                CONTAINER-RUNTIME
5b4s34-vm3.englab.juniper.net   NotReady   master   24m     v1.18.9-eks-1-18-1   10.87.68.153   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
5b4s34-vm4.englab.juniper.net   NotReady   master   6m48s   v1.18.9-eks-1-18-1   10.87.68.154   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
5b4s34-vm5.englab.juniper.net   NotReady   master   5m55s   v1.18.9-eks-1-18-1   10.87.68.155   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
5b4s34-vm6.englab.juniper.net   NotReady   <none>   2m4s    v1.18.9-eks-1-18-1   10.87.68.156   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
5b4s34-vm7.englab.juniper.net   NotReady   <none>   2m54s   v1.18.9-eks-1-18-1   10.87.68.157   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
5b4s34-vm8.englab.juniper.net   NotReady   <none>   3m39s   v1.18.9-eks-1-18-1   10.87.68.158   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
```
