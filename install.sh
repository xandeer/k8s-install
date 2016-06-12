#!/bin/bash
###############################################################################
# File Name: install.sh
# Description:
# Author: d00291918
# Created Time: Wed 14 Oct 2015 09:29:51 PM EDT
###############################################################################
CURBIN="${BASH_SOURCE-$0}"
CURBIN="$(dirname "${CURBIN}")"
CURDIR="$(cd "${CURBIN}"; pwd)"

# default params {
opt_type="minion"
# }

# define output functions {
INFO_FLAG=1
info() {
  if [ ${INFO_FLAG} -ne 0 ]; then
    local msg=$1
    echo -e "Info:\t$msg" >&2
  fi
}

warn() {
  if [ ${INFO_FLAG} -ne 0 ]; then
    local msg=$1
    echo -e "Warning:\t$msg" >&2
  fi
}

error() {
  local msg=$1
  local exit_code=$2

  echo -e "Error:\t$msg" >&2

  if [ -n "$exit_code" ] ; then
    exit $exit_code
  fi
}
#}

display_help() {
  cat <<EOF
Usage: $0 [options]...

options:
  --type,-t <master|minion>            in master node, it will be installed the etcd, kube-apiserver, kube-controller-manager, kube-scheduler and flannel
                                       in minion(default) node, it will be installed the kubelet, kube-proxy and flannel
  --etcd-servers,-e <etcd servers>     list the etcd servers, like: http://etcd:4001
  --master,-m <master server>          the kubernetes cluster master server, like: http://master:8080
  --help,-h                            display help text

EOF
}

# parse the input params {
if [ ! -n "$*" ]; then
    display_help
    exit 1
fi
while [ -n "$*" ]; do
    arg=$1
    shift

    case "$arg" in
        --type|-t)
            [ -n "$1" ] || error "option --type requires an argument" 1
            opt_type=$1
            info "Node type set to $opt_type"
            shift
            ;;
        --etcd-servers|-e)
            [ -n "$1" ] || error "Option --etcd-servers requires an argument" 1
            opt_etcd_servers=$1
            info "Etcd servers set to $opt_etcd_servers"
            shift
            ;;
        --master|-m)
            [ -n "$1" ] || error "Option --master requires an argument" 1
            opt_master=$1
            info "Kubernetes cluster's master set to $opt_master"
            shift
            ;;
        --help|-h)
            display_help
            exit 1
            ;;
        *)
            display_help
            exit 1
            ;;
    esac
done
# }

# check the node type {
valid_node_type="master|minion"
echo $valid_node_type | grep "$opt_type" > /dev/null
[ 0 -eq $? ] || error "$opt_type is a invalid node type!\n\tPlease choice a node type in $valid_node_type." 2
# }

# check the empty of etcd servers and master option {
function is_opt_empty() {
    if [ ! -n "$1" ]; then
        return 0
    fi
    return 1
}

is_opt_empty "$opt_etcd_servers"
[ 0 -eq "$?" ] && error "options --etcd-servers can't be empty!" 2

is_opt_empty "$opt_master"
[ 0 -eq "$?" ] && error "options --master can't be empty!" 2
# }

# modify the configs {
function conf_common() {
    sed -i "/KUBE_ETCD_SERVERS/c KUBE_ETCD_SERVERS=\"--etcd-servers=$opt_etcd_servers\"" $CURDIR/conf/common/kubernetes/config
    sed -i "/KUBE_MASTER/c KUBE_MASTER=\"--master=$opt_master\"" $CURDIR/conf/common/kubernetes/config
    sed -i "/FLANNEL_ETCD=/c FLANNEL_ETCD=\"$opt_etcd_servers\"" $CURDIR/conf/common/sysconfig/flanneld
}

function conf_master() {
    sed -i "/ETCD_LISTEN_CLIENT_URLS/c ETCD_LISTEN_CLIENT_URLS=\"--listen-client-urls $opt_etcd_servers\"" $CURDIR/conf/master/etcd/etcd.conf
    sed -i "/ETCD_ADVERTISE_CLIENT_URLS/c ETCD_ADVERTISE_CLIENT_URLS=\"--advertise-client-urls $opt_etcd_servers\"" $CURDIR/conf/master/etcd/etcd.conf
    sed -i "/KUBE_MASTER/c KUBE_MASTER=\"--master=$opt_master\"" $CURDIR/conf/master/kubernetes/apiserver
    sed -i "/KUBE_ETCD_SERVERS/c KUBE_ETCD_SERVERS=\"--etcd-servers=$opt_etcd_servers\"" $CURDIR/conf/master/kubernetes/apiserver
}

function conf_minion() {
    sed -i "/KUBELET_HOSTNAME/c KUBELET_HOSTNAME=\"--hostname-override=$HOSTNAME\"" $CURDIR/conf/minion/kubernetes/kubelet
    sed -i "/KUBELET_API_SERVER/c KUBELET_API_SERVER=\"--api-servers=$opt_master\"" $CURDIR/conf/minion/kubernetes/kubelet
}
# }

# copy files to node destination {
function copy_common() {
    cp -a $CURDIR/bin/common/* /usr/bin
    cp -a $CURDIR/conf/common/* /etc
    cp -a $CURDIR/service/common/* /usr/lib/systemd/system
    cp -a $CURDIR/libexec/common/* /usr/libexec
}

function copy_master() {
    cp -a $CURDIR/bin/master/* /usr/bin
    cp -a $CURDIR/conf/master/* /etc
    cp -a $CURDIR/service/master/* /usr/lib/systemd/system
}

function copy_minion() {
    cp -a $CURDIR/bin/minion/* /usr/bin
    cp -a $CURDIR/conf/minion/* /etc
    cp -a $CURDIR/service/minion/* /usr/lib/systemd/system
}
# }

# install docker {
function install_docker() {
    command -v docker > /dev/null 2>&1 && return
    if [ -n "$PROXY" ]; then
        echo "proxy=$PROXY" >> /etc/yum.conf
    fi
    yum update -y
    curl -sSL https://get.docker.com/ | sh
}
# }

# start cluster services  {
function start_master() {
    master_services="etcd kube-apiserver kube-controller-manager kube-scheduler flanneld"
    systemctl daemon-reload
    systemctl start etcd
    # load the flannel settings, the config is under the /etc/sysconfig/flanneld "FLANNEL_ETCD_KEY"
    curl $opt_etcd_servers/v2/keys/flannel/config -XPUT --data-urlencode value@$CURDIR/var/flannel-config.json
    systemctl enable $master_services
    systemctl restart $master_services
    systemctl status $master_services
}

function start_minion() {
    install_docker
    systemctl stop docker
    ip link del docker0
    mkdir /var/lib/kubelet
    minion_services="flanneld kube-proxy docker kubelet"
    systemctl daemon-reload
    systemctl enable $minion_services
    systemctl restart $minion_services
    systemctl status $minion_services
}
# }

# read config file {
function install_conf() {
    if [ -f "$CURDIR/install.conf" ]; then
        source $CURDIR/install.conf

        if [ -n "$PROXY" ]; then
            echo "search huawei.com" >> /etc/resolv.conf
            export https_proxy=$PROXY
            mkdir -p /usr/lib/systemd/system/docker.service.d
            echo -e "[Service]\nEnvironment=\"HTTP_PROXY=$PROXY\" \"NO_PROXY=$NO_PROXY\"" > /usr/lib/systemd/system/docker.service.d/proxy.conf
        fi

        if [ -n "$REGISTRY" ]; then
            echo "INSECURE_REGISTRY=\"--insecure-registry $REGISTRY\"" >> /etc/sysconfig/docker
        fi
    fi
}
# }

# add user kube and etcd {
function user_add() {
    useradd -c "Kubernetes user" -d / -M -s /sbin/nologin kube
    useradd -c "etcd user" -d /var/lib/etcd -m -s /sbin/nologin etcd
}
# }

# main {
user_add

install_conf

conf_common
copy_common

conf_$opt_type
copy_$opt_type

start_$opt_type
# }
