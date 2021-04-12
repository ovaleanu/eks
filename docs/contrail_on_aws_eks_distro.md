# Install Contrail Networking as a CNI on AWS EKS Distro

**Update for EKS 1.19.6**

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

I have one VM for this demonstration.

_Note: I created this [script](https://github.com/ovaleanujnpr/eks/blob/master/scripts/centos_prep_install_k8s_eks.sh) that will install everything for you._


### Updating the OS configurations

Perform the following commands as `root`
```
[lab@master1-tf ~]$ sudo su -
```

Disable swap to prevent memory allocation issues
```
[root@master1-tf ~]# sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab
[root@master1-tf ~]# swapoff -a
```

Disable SELinux and firewalld
```
[root@master1-tf ~]# setenforce 0
[root@master1-tf ~]# sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
[root@master1-tf ~]# systemctl stop firewalld; systemctl disable firewalld
```

Enable the module for cluster communication
```
[root@master1-tf ~]# cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

[root@master1-tf ~]# sysctl --system
```
Install the necessary packages
```
[root@master1-tf ~]# yum -y update && yum install -y epel-release yum-utils device-mapper-persistent-data lvm2 curl wget
```
Add the Docker repository
```
[root@master1-tf ~]# yum-config-manager --add-repo \
  https://download.docker.com/linux/centos/docker-ce.repo
```
Install Docker CE
```
[root@master1-tf ~]# yum -y update && yum install -y containerd.io docker-ce-19.03.11 docker-ce-cli-19.03.11
```
Create `/etc/docker`
```
[root@master1-tf ~]# mkdir /etc/docker
```
Set up the Docker daemon
```
[root@master1-tf ~]# cat <<EOF > /etc/docker/daemon.json
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
[root@master1-tf ~]# mkdir -p /etc/systemd/system/docker.service.d
```
Restart docker
```
[root@master1-tf ~]# systemctl daemon-reload
[root@master1-tf ~]# systemctl enable --now docker
```
Check docker service
```
[root@master1-tf ~]# systemctl status docker
```

### Install EKS-D

Download and install K8s CNI from AWS EKS-D repo.
```
[root@master1-tf ~]# mkdir -p /opt/cni/bin
[root@master1-tf ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/plugins/v0.8.7/cni-plugins-linux-amd64-v0.8.7.tar.gz
[root@master1-tf ~]# tar zxf cni-plugins-linux-amd64-v0.8.7.tar.gz -C /opt/cni/bin/
```

Download kubeadm, kubelet, and kubectl from the AWS EKS-D repo
```
[root@master1-tf ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubeadm
[root@master1-tf ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubelet
[root@master1-tf ~]# wget -q https://distro.eks.amazonaws.com/kubernetes-1-19/releases/1/artifacts/kubernetes/v1.19.6/bin/linux/amd64/kubectl
[root@master1-tf ~]# mv kubeadm kubelet kubectl /usr/bin/
[root@master1-tf ~]# chmod +x /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl
```
Install dependencies for `kubelet`
```
[root@master1-tf ~]# yum -y install conntrack ebtables socat
```
Create directories and files needed by kubeadm and kubelet
```
[root@master1-tf ~]# mkdir -p /etc/kubernetes/manifests
[root@master1-tf ~]# mkdir -p /usr/lib/systemd/system/kubelet.service.d

[root@master1-tf ~]# cat <<EOF > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
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

[root@master1-tf ~]# cat <<EOF > /usr/lib/systemd/system/kubelet.service
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

[root@master1-tf ~]# systemctl enable kubelet
```

Create the following kuberntes configurastion file for `kubeadm init`. Update `primary_ip` nad `primary_hostname_fqdn` with your details.
You can generate `bootstrap_token` using command `kubeadm token generate`

```
[root@master1-tf ~]# cat <<EOF > eksd-kube.yaml
apiVersion: kubeadm.k8s.io/v1beta2
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: {{ bootstrap_token }}
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: {{ primary_ip }}
  bindPort: 6443
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  name: {{ primary_hostname_fqdn }}
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta2
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns:
  type: CoreDNS
  imageRepository: public.ecr.aws/eks-distro/coredns
  imageTag: v1.8.0-eks-1-19-1
etcd:
  local:
    dataDir: /var/lib/etcd
    imageRepository: public.ecr.aws/eks-distro/etcd-io
    imageTag: v3.4.14-eks-1-19-1
imageRepository: public.ecr.aws/eks-distro/kubernetes
kind: ClusterConfiguration
kubernetesVersion: v1.19.6-eks-1-19-1
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
scheduler: {}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: ""
  burst: 0
  contentType: ""
  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
  qps: 0
clusterCIDR: ""
configSyncPeriod: 0s
conntrack:
  maxPerCore: null
  min: null
  tcpCloseWaitTimeout: null
  tcpEstablishedTimeout: null
detectLocalMode: ""
enableProfiling: false
healthzBindAddress: ""
hostnameOverride: ""
iptables:
  masqueradeAll: false
  masqueradeBit: null
  minSyncPeriod: 0s
  syncPeriod: 0s
ipvs:
  excludeCIDRs: null
  minSyncPeriod: 0s
  scheduler: ""
  strictARP: false
  syncPeriod: 0s
  tcpFinTimeout: 0s
  tcpTimeout: 0s
  udpTimeout: 0s
kind: KubeProxyConfiguration
metricsBindAddress: ""
mode: ""
nodePortAddresses: null
oomScoreAdj: null
portRange: ""
showHiddenMetricsForVersion: ""
udpIdleTimeout: 0s
winkernel:
  enableDSR: false
  networkName: ""
  sourceVip: ""
---
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
cpuManagerReconcilePeriod: 0s
evictionPressureTransitionPeriod: 0s
fileCheckFrequency: 0s
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 0s
imageMinimumGCAge: 0s
kind: KubeletConfiguration
nodeStatusReportFrequency: 0s
nodeStatusUpdateFrequency: 0s
rotateCertificates: true
runtimeRequestTimeout: 0s
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 0s
syncFrequency: 0s
volumeStatsAggPeriod: 0s
EOF
```

Initialise the Kubernetes cluster with the configuration file
```
[root@master1-tf ~]# kubeadm init --config eksd-kube.yaml
```

On the master node as non-root, run the following commands

```
[lab@master1-tf ~]$ mkdir -p $HOME/.kube
[lab@master1-tf ~]$ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
[lab@master1-tf ~]$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

The EKS-D cluster is ready. You only need to apply the contrail single yaml as described in this [Wiki](https://github.com/ovaleanujnpr/kubernetes/wiki/Installing-Kubernetes-with-Contrail#on-the-master).
```
[lab@master1-tf ~]$ kubectl get no -owide
NAME         STATUS   ROLES    AGE     VERSION              INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                KERNEL-VERSION                CONTAINER-RUNTIME
master1-tf   NotReady    master   3d19h   v1.19.6-eks-1-19-1   192.168.122.106   <none>        CentOS Linux 7 (Core)   3.10.0-1160.21.1.el7.x86_64   docker://19.3.11
```
### Install Contrail L1.2011 using TF-operator

Install the necessary OS packages

```
[lab@master1-tf ~]$ sudo yum -y install python3 git
[lab@master1-tf ~]$ sudo python3 -m pip install jinja2
```

Download TF-Operator repository
```
[lab@master1-tf ~]$ git clone https://github.com/tungstenfabric/tf-operator
[lab@master1-tf ~]$ git checkout R2011
```

Set Contrail variables and generate manifests
```
[lab@master1-tf ~]$ export CONTRAIL_DEPLOYER_CONTAINER_TAG="R2011.L1.249"
[lab@master1-tf ~]$ export DEPLOYER_CONTAINER_REGISTRY="hub.juniper.net/contrail-nightly"
[lab@master1-tf ~]$ export CONTRAIL_CONTAINER_TAG="R2011.L1.249"
[lab@master1-tf ~]$ export CONTAINER_REGISTRY="hub.juniper.net/contrail-nightly"
[lab@master1-tf ~]$ export IMAGE_PULL_SECRETS="contrail-registry"
[lab@master1-tf ~]$ ./tf-operator/contrib/render_manifests.sh
```

Install Contrail using TF-Operator
```
[lab@master1-tf ~]$  kubectl create ns tf
[lab@master1-tf ~]$ kubectl create secret docker-registry contrail-registry --docker-server=hub.juniper.net/contrail-nightly --docker-username={{ juniper_repo_username }} --docker-password={{ juniper_repo_password}} --docker-email={{ juniper_email }}t -n tf
[lab@master1-tf ~]$ kubectl apply -f ./tf-operator/deploy/crds/
[lab@master1-tf ~]$ kubectl wait crds --for=condition=Established --timeout=2m managers.tf.tungsten.io
[lab@master1-tf ~]$ kubectl apply -k ./tf-operator/deploy/kustomize/operator/templates/
[lab@master1-tf ~]$ kubectl apply -k ./tf-operator/deploy/kustomize/contrail/templates/
```

Check EKS-D cluster status
```
[lab@master1-tf ~]$ kubectl get no -owide
NAME         STATUS   ROLES    AGE     VERSION              INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                KERNEL-VERSION                CONTAINER-RUNTIME
master1-tf   Ready    master   3d21h   v1.19.6-eks-1-19-1   192.168.122.106   <none>        CentOS Linux 7 (Core)   3.10.0-1160.21.1.el7.x86_64   docker://19.3.11

[lab@master1-tf ~]$ kubectl get po -A -owide
NAMESPACE     NAME                                           READY   STATUS    RESTARTS   AGE     IP                NODE         NOMINATED NODE   READINESS GATES
default       ubuntu                                         1/1     Running   0          165m    10.244.255.250    master1-tf   <none>           <none>
kube-system   coredns-5c8c9c4469-lpzc4                       1/1     Running   0          3d21h   10.244.255.252    master1-tf   <none>           <none>
kube-system   coredns-5c8c9c4469-scf66                       1/1     Running   0          3d21h   10.244.255.251    master1-tf   <none>           <none>
kube-system   etcd-master1-tf                                1/1     Running   0          3d21h   192.168.122.106   master1-tf   <none>           <none>
kube-system   kube-apiserver-master1-tf                      1/1     Running   0          3d21h   192.168.122.106   master1-tf   <none>           <none>
kube-system   kube-controller-manager-master1-tf             1/1     Running   0          3d21h   192.168.122.106   master1-tf   <none>           <none>
kube-system   kube-proxy-zdmr2                               1/1     Running   0          3d21h   192.168.122.106   master1-tf   <none>           <none>
kube-system   kube-scheduler-master1-tf                      1/1     Running   0          3d21h   192.168.122.106   master1-tf   <none>           <none>
tf            analyticsalarm1-analyticsalarm-statefulset-0   4/4     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            analyticssnmp1-analyticssnmp-statefulset-0     4/4     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            cassandra1-cassandra-statefulset-0             3/3     Running   2          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            config1-config-statefulset-0                   14/14   Running   1          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            control1-control-statefulset-0                 5/5     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            kubemanager1-kubemanager-statefulset-0         1/1     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            rabbitmq1-rabbitmq-statefulset-0               1/1     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            tf-operator-fd4999c-5fswh                      1/1     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            vrouter1-vrouter-daemonset-xwm2l               3/3     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            webui1-webui-statefulset-0                     3/3     Running   1          3d1h    192.168.122.106   master1-tf   <none>           <none>
tf            zookeeper1-zookeeper-statefulset-0             1/1     Running   0          3d1h    192.168.122.106   master1-tf   <none>           <none>
```
