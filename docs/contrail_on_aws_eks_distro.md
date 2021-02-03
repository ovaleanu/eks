# Install Contrail Networking as a CNI on AWS EKS Distro

Couple of months ago, AWS introduced EKS Distro (EKS-D) a Kubernetes distribution based on and used by Amazon Elastic Kubernetes Service (Amazon EKS). With EKS-D, users can rely on the same versions of Kubernetes and its dependencies deployed on Amazon EKS and other cloud platforms (public/private).

In EKS on AWS EC2 setting a managed control plane — control plane runs in an account managed by AWS, and the Kubernetes API is exposed via the AWS EKS endpoint associated with your cluster. Each AWS EKS cluster control plane is single-tenant and unique, and runs on its own set of AWS EC2 instances.
Users can choose between a self-managed data plane or a aws managed data plane using node groups

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-1-components.png)

Users cannot access the control plane components. They can access only the DaemonSets deployed on nodes and the workloads.
Contrail is deployed on AWS EKS replacing aws node daemonsets. The installation procedure for how to install Contrail on AWS EKS is [here](https://www.juniper.net/documentation/en_US/contrail20/topics/task/installation/how-to-install-contrail-aws-eks.html).

On this article, I will focus on the integration of Contrail with EKS-D on-premises in my lab.

In EKS-D all the components are managed by the users. Creating the cluster can be done in different ways. A nomber of [AWS Partners](https://distro.eks.amazonaws.com/community/partners/) are already providing various installation methods.
All the LCM of the nodes, HA control plane, etc should be done by the users.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-2-components.png)

For this demo I chose to use `kubeadm` to bootstrap the cluster.

Comparing with AWS EKS, in EKS-D users have access to all the components, control plane and other worloads running on data plane.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-3-components.png)

I have 3 VMs, one for the master and two workers.

I will update the OS and install EKS-D. The following commands should be performed in parallel on all the nodes.

_Note: I created this [script](https://github.com/ovaleanujnpr/eks/blob/master/scripts/centos_prep_install_k8s_eks.sh) that will install everything for you. It needs to be run on all nodes._

[Tmux](https://github.com/tmux/tmux/wiki) can be used to run commands on multiple compute instances at the same time. Labs in this tutorial may require running the same commands across multiple compute instances, in those cases consider using tmux and splitting a window into multiple panes with synchronize-panes enabled to speed up the provisioning process.

![](https://github.com/ovaleanujnpr/eks/blob/master/images/eks-5-components.png)

_Enable synchronize-panes by pressing ctrl+b followed by shift+:. Next type set synchronize-panes on at the prompt. To disable synchronization: set synchronize-panes off._

### Updating the OS configurations

Perform the following commands as `root`
```
[lab@eks-master ~]$ sudo su -
```

Disable swap to prevent memory allocation issues
```
[root@eks-master ~]# sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
[root@eks-master ~]# swapoff -a
```

Disable SELinux and firewalld
```
[root@eks-master ~]# setenforce 0
[root@eks-master ~]# sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
[root@eks-master ~]# systemctl stop firewalld; systemctl disable firewalld
```

Enable the module for cluster communication
```
[root@eks-master ~]# cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

[root@eks-master ~]# sysctl --system
```
Install the necessary packages
```
[root@eks-master ~]# yum -y update && yum install -y epel-release yum-utils device-mapper-persistent-data lvm2 curl wget
```
Add the Docker repository
```
[root@eks-master ~]# yum-config-manager --add-repo \
  https://download.docker.com/linux/centos/docker-ce.repo
```
Install Docker CE
```
[root@eks-master ~]# yum -y update && yum install -y containerd.io-1.2.13 docker-ce-19.03.11 docker-ce-cli-19.03.11
```
Create `/etc/docker`
```
[root@eks-master ~]# mkdir /etc/docker
```
Set up the Docker daemon
```
[root@eks-master ~]# cat <<EOF > /etc/docker/daemon.json
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
[root@eks-master ~]# mkdir -p /etc/systemd/system/docker.service.d
```
Restart docker
```
[root@eks-master ~]# systemctl daemon-reload
[root@eks-master ~]# systemctl enable --now docker
```
Check docker service
```
[root@eks-master ~]# systemctl status docker
```

### Install EKS-D

Continue in the tmux sessions running the commands in parallel on all nodes

Download and install K8s CNI from AWS EKS-D repo.
```
[root@eks-master ~]# mkdir -p /opt/cni/bin
[root@eks-master ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/plugins/v0.8.7/cni-plugins-linux-amd64-v0.8.7.tar.gz
[root@eks-master ~]# tar zxf cni-plugins-linux-amd64-v0.8.7.tar.gz -C /opt/cni/bin/
```

Download kubeadm, kubelet, and kubectl from the AWS EKS-D repo
```
[root@eks-master ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubeadm
[root@eks-master ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubelet
[root@eks-master ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-18/releases/1/artifacts/kubernetes/v1.18.9/bin/linux/amd64/kubectl
[root@eks-master ~]# mv kubeadm kubelet kubectl /usr/bin/
[root@eks-master ~]# chmod +x /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl
```
Install dependencies for `kubelet`
```
[root@eks-master ~]# yum -y install conntrack ebtables socat
```
Create directories and files needed by kubeadm and kubelet
```
[root@eks-master ~]# mkdir -p /etc/kubernetes/manifests
[root@eks-master ~]# mkdir -p /usr/lib/systemd/system/kubelet.service.d

[root@eks-master ~]# cat <<EOF > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
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

[root@eks-master ~]# cat <<EOF > /usr/lib/systemd/system/kubelet.service
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

[root@eks-master ~]# systemctl enable kubelet
```

Download the EKS-D Docker images needed from the Amazon ECR public repo
```
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/etcd-io/etcd:v3.4.14-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/kubernetes/pause:v1.18.9-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/kubernetes/kube-scheduler:v1.18.9-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/kubernetes/kube-proxy:v1.18.9-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/kubernetes/kube-apiserver:v1.18.9-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/kubernetes/kube-controller-manager:v1.18.9-eks-1-18-1
[root@eks-master ~]# docker pull public.ecr.aws/eks-distro/coredns/coredns:v1.7.0-eks-1-18-1
```

Kubeadm is using some hardcoded values for pause and coredns. I need to change the tag for them
```
[root@eks-master ~]# docker tag public.ecr.aws/eks-distro/kubernetes/pause:v1.18.9-eks-1-18-1 public.ecr.aws/eks-distro/kubernetes/pause:3.2
[root@eks-master ~]# docker tag public.ecr.aws/eks-distro/coredns/coredns:v1.7.0-eks-1-18-1 public.ecr.aws/eks-distro/kubernetes/coredns:1.6.7
```

I have the following images downloaded on all three nodes
```
[root@eks-master ~]# docker images
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


At this point `set synchronize-panes off` in tmux session. On the master node as `root` create the following kubeadm config file.

```
[root@eks-master ~]# cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
controlPlaneEndpoint: "eks-master:6443"
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
  advertiseAddress: "10.87.68.155"
EOF
```

Initialise the Kubernetes cluster with the configuration file
```
[root@eks-master ~]# kubeadm init --config kubeadm-config.yaml
```

After master node is installed and initialised, join the workers with kubeadm join command generated.

```
kubeadm join eks-master:6443 --token <token> \
    --discovery-token-ca-cert-hash <discovery-token-ca-cert-hash>
```

On the master node as non-root, run the following commands

```
[lab@eks-master ~]$ mkdir -p $HOME/.kube
[lab@eks-master ~]$ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
[lab@eks-master ~]$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

The EKS-D cluster is ready. You only need to apply the contrail single yaml as described in this [Wiki](https://github.com/ovaleanujnpr/kubernetes/wiki/Installing-Kubernetes-with-Contrail#on-the-master).
```
[lab@eks-master ~]$ kubectl get no -owide
NAME          STATUS   ROLES    AGE   VERSION              INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                KERNEL-VERSION                CONTAINER-RUNTIME
eks-master    Ready    master   12m   v1.18.9-eks-1-18-1   10.87.68.155   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
eks-worker1   Ready    <none>   11m   v1.18.9-eks-1-18-1   10.87.68.156   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11
eks-worker2   Ready    <none>   11m   v1.18.9-eks-1-18-1   10.87.68.157   <none>        CentOS Linux 7 (Core)   3.10.0-1160.11.1.el7.x86_64   docker://19.3.11

[lab@eks-master ~]$ kubectl get po -A
NAMESPACE     NAME                                 READY   STATUS    RESTARTS   AGE
kube-system   config-zookeeper-w8dq5               1/1     Running   0          5m38s
kube-system   contrail-agent-7ccwk                 3/3     Running   0          5m34s
kube-system   contrail-agent-fjtrt                 3/3     Running   0          5m33s
kube-system   contrail-agent-l4blv                 3/3     Running   0          5m33s
kube-system   contrail-analytics-rqkrw             4/4     Running   0          5m38s
kube-system   contrail-configdb-7n5fj              3/3     Running   0          5m38s
kube-system   contrail-controller-config-688r6     6/6     Running   0          5m37s
kube-system   contrail-controller-control-xqfqs    5/5     Running   0          5m37s
kube-system   contrail-controller-webui-hbtd7      2/2     Running   0          5m37s
kube-system   contrail-kube-manager-xzd8d          1/1     Running   0          5m35s
kube-system   coredns-8f7b4cf65-549qs              1/1     Running   0          11m
kube-system   coredns-8f7b4cf65-8ln24              1/1     Running   0          11m
kube-system   etcd-eks-master                      1/1     Running   0          11m
kube-system   kube-apiserver-eks-master            1/1     Running   0          11m
kube-system   kube-controller-manager-eks-master   1/1     Running   0          11m
kube-system   kube-proxy-6fwbd                     1/1     Running   0          11m
kube-system   kube-proxy-7mtdh                     1/1     Running   0          11m
kube-system   kube-proxy-t5hqg                     1/1     Running   0          11m
kube-system   kube-scheduler-eks-master            1/1     Running   0          11m
kube-system   rabbitmq-twg6j                       1/1     Running   0          5m35s
kube-system   redis-82mvk                          1/1     Running   0          5m36s
```
