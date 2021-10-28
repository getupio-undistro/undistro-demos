#!/bin/bash

case "$1" in
    -h|--help)
        echo "Usage: $0 [phase]"
        echo ""
        echo "Default phases, in this order: "
        echo "  download                            Download all required tools into current directory"
        echo "  credentials                         Ask for missing credentials"
        echo "  create-manager-cluster              Create Manager Cluster, used to create \"real\" Clusters"
        echo "  create-manager-cluster-nodepool     Create Manager Cluster, used to create \"real\" Clusters"
        echo "  install-undistro                    Install all Undistro controllers into Manager Cluster"
        echo "  create-cluster                      Create \"real\" Cluster"
        echo "  wait-cluster                        Wait for \"real\" Cluster to become ready"
        echo ""
        echo "Extra phases:"
        echo "  upgrade                             Upgrade cluster version"
        echo "  autoscale                           Enable nodepool autoscale"
        echo "  destroy                             Delete all clusters and resources"
        exit
esac

#set -e

PHASES=(
    download
    credentials
    create_manager_cluster
    create_manager_cluster_nodepool
    install_undistro
    create_cluster
    wait_cluster
)

if [ $# -gt 0 ]; then
    PHASES=( $@ )
fi

: ${MANAGER_CLUSTER_NAME:=undistro-demo-manager}
: ${MANAGER_CLUSTER_NODEPOOL=default}
: ${KUBECONFIG:=$PWD/kubeconfig-$MANAGER_CLUSTER_NAME}
: ${CLUSTER_NAMESPACE:=aws-demo}
: ${CLUSTER_NAME:=eks-demo}
: ${CLUSTER_VERSION:=1.20.0}
: ${CLUSTER_VERSION_NEW:=1.21.0}
: ${UNDISTRO_VERSION:=0.36.17}
: ${CLUSTER_KUBECONFIG:=kubeconfig-eks-demo.yaml}
: ${PAUSE:=true}
: ${FORCE:=false}

export KUBECONFIG
export PATH=$PWD/:$PATH

function log()
{
    [ "${1:0:1}" == - ] && p=$1 && shift
    echo -e $p ">>> $(tput setaf 3)$@$(tput sgr0)"
}

function logb()
{
    [ "${1:0:1}" == - ] && p=$1 && shift
    echo -e $p ">>> $(tput bold)$(tput setaf 3)$@$(tput sgr0)"
}

function pause()
{
    [ $# -eq 0 ] || logb "$@"
    if $PAUSE; then
        read -p "$(tput bold)>>> $(tput setaf 1)Press [ENTER] to continue ...$(tput sgr0)"
    fi
}

function run()
{
    echo -e $p ">>> $(tput setaf 2)$(tput bold)\$ $@$(tput sgr0)"
    eval "$@"
}

function time_phase()
{
    local phase=${1#phase_}
    local start=$(date +%s)
    echo -e "$(tput bold)+++ $(tput setaf 8)Starting phase [$phase]: $(date --date=@$start)$(tput sgr0)"
    eval "$@"
    local end=$(date +%s)
    local s=$((end - start))
    echo -e "$(tput bold)--- $(tput setaf 8)Phase [$phase] took $((s / 60))m$((s % 60))s$(tput sgr0)"
}

function phase_download()
{
    ################################################################################
    logb "Downloading binaries"
    ################################################################################

    log "> undistro"
    if $FORCE || ! [ -x ./undistro ]; then
        run curl -sL https://github.com/getupio-undistro/undistro/releases/download/v$UNDISTRO_VERSION/undistro_${UNDISTRO_VERSION}_linux_amd64.tar.gz \
            \| tar xz undistro
        chmod +x undistro
    fi

    log "> eksctl"
    if $FORCE || ! [ -x ./eksctl ]; then
        run curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
            \| tar xz eksctl
        chmod +x eksctl
    fi

    log "> aws-iam-authenticator"
    if $FORCE || ! [ -x ./aws-iam-authenticator ]; then
        run curl -sLO https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
        chmod +x aws-iam-authenticator
    fi

    log "> kubectl"
    if $FORCE || ! [ -x ./kubectl ]; then
        run curl -sLO https://storage.googleapis.com/kubernetes-release/release/v1.20.6/bin/linux/amd64/kubectl
        chmod +x kubectl
    fi
}

function phase_credentials()
{
    ################################################################################
    logb "Reading AWS credentials"
    ################################################################################

    [ -n "$AWS_ACCESS_KEY_ID" ] && log Found AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID || read -p "AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID
    [ -n "$AWS_SECRET_ACCESS_KEY" ] && log 'Found AWS_SECRET_ACCESS_KEY=********' || { read -sp "AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY && echo; }
    [ -n "$AWS_REGION" ] && log Found AWS_REGION=$AWS_REGION || read -p "AWS_REGION: " AWS_REGION

    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION

    log "Current AWS Account:"
    aws sts get-caller-identity
}

function phase_create_manager_cluster()
{
    ################################################################################
    pause "Ready to create Manager Cluster: $MANAGER_CLUSTER_NAME"
    ################################################################################

    logb "Looking for Manager Cluster: $MANAGER_CLUSTER_NAME ..."

    if $FORCE || ! ./eksctl get cluster $MANAGER_CLUSTER_NAME &>/dev/null; then
        logb "\nCreating Manager Cluster: $MANAGER_CLUSTER_NAME"
        run ./eksctl create cluster \
            --name $MANAGER_CLUSTER_NAME \
            --version 1.20 \
            --region us-east-1 \
            --zones us-east-1a,us-east-1b \
            --with-oidc \
            --without-nodegroup
    else
        log "Found existing cluster $MANAGER_CLUSTER_NAME"
    fi
}

function phase_create_manager_cluster_nodepool()
{
    ################################################################################
    pause "Ready to create Manager Cluster Nodepool: $MANAGER_CLUSTER_NODEPOOL"
    logb "Looking for Manager Cluster Nodepool: $MANAGER_CLUSTER_NODEPOOL"
    ################################################################################

    if $FORCE || ! ./eksctl get nodegroup --cluster $MANAGER_CLUSTER_NAME --name $MANAGER_CLUSTER_NODEPOOL &>/dev/null; then
        run eksctl create nodegroup \
            --cluster $MANAGER_CLUSTER_NAME \
            --region $AWS_REGION \
            --name $MANAGER_CLUSTER_NODEPOOL \
            --node-type m5.xlarge \
            --nodes 1 \
            --nodes-min 1 \
            --nodes-max 1
    else
        log "Found existing nodepool $MANAGER_CLUSTER_NAME"
    fi

    logb "Downloading kubeconfig to KUBECONFIG=$KUBECONFIG"

    run eksctl utils write-kubeconfig \
        --cluster $MANAGER_CLUSTER_NAME \
        --region $AWS_REGION \
        --kubeconfig $KUBECONFIG
}

function phase_install_undistro()
{
    ## get crd
    if $FORCE || ! kubectl get namespace undistro-system &>/dev/null; then
        ################################################################################
        pause "Manager Cluster is ready. Let's install Undistro into it"
        log "Looking for namespace undistro-system"
        ################################################################################

        log "Generating credentials.yaml"
        cat >credentials.yaml <<EOF
global:
  undistroRepository: registry.undistro.io/library
  undistroVersion: v${UNDISTRO_VERSION}
undistro:
  ingress:
    hosts:
      - ${CLUSTER_NAME}-${CLUSTER_NAMESPACE}.undistro-demo.getupcloud.com
undistro-aws:
  enabled: true
  credentials:
    region: $AWS_REGION
    accessKeyID: $AWS_ACCESS_KEY_ID
    secretAccessKey: "$AWS_SECRET_ACCESS_KEY"
    # sessionToken: put your key here if you use 2FA
EOF


        logb "Installing undistro into Manager Cluster: $MANAGER_CLUSTER_NAME"
        run ./undistro install --config credentials.yaml
    else
        logb "Undistro is already installed into Manager Cluster $MANAGER_CLUSTER_NAME"
    fi
}

function phase_create_cluster()
{
    ################################################################################
    pause "Ready to create Undistro Cluster: $CLUSTER_NAME"
    ################################################################################

    if $FORCE || ! kubectl get cluster $CLUSTER_NAME &>/dev/null; then
        ################################################################################
        log "Generating cluster manifests: $CLUSTER_NAME.yaml"
        ################################################################################

        run undistro create cluster $CLUSTER_NAME \
            --namespace $CLUSTER_NAMESPACE \
            --k8s-version v$CLUSTER_VERSION\
            --infra aws \
            --flavor eks \
            --generate-file

        ################################################################################
        log "Creating cluster $CLUSTER_NAME from manifests: $CLUSTER_NAME.yaml"
        ################################################################################
        run kubectl apply -f $CLUSTER_NAME.yaml
    else
        log "Cluster $CLUSTER_NAME already exists"
        run kubectl get cluster $CLUSTER_NAME
    fi
}

function phase_wait_cluster()
{
    ################################################################################
    log "Undistro Cluster $CLUSTER_NAMESPACE/$CLUSTER_NAME is being created..."
    ################################################################################

    run undistro show-progress -n $CLUSTER_NAMESPACE $CLUSTER_NAME &
    while ! kubectl wait --timeout=-1s --for=condition=Ready -n $CLUSTER_NAMESPACE cluster/$CLUSTER_NAME &>/dev/null; do
        sleep 2
    done
    killall undistro 2>/dev/null

    ################################################################################
    log "Undistro Cluster $CLUSTER_NAMESPACE/$CLUSTER_NAME is created"
    ################################################################################

    log "Showing Undistro Cluster"
    run undistro get cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME

    log "Retrieving kubeconfig for Undistro Cluster $CLUSTER_NAME"
    run undistro get kubeconfig -n $CLUSTER_NAMESPACE $CLUSTER_NAME --admin > $CLUSTER_KUBECONFIG

    echo
    logb "You can now use your new cluster!"
    echo
    echo "export KUBECONFIG=$PWD/$CLUSTER_KUBECONFIG"
    echo "kubectl get nodes"
}

function phase_watch()
{
    run undistro show-progress -n $CLUSTER_NAMESPACE $CLUSTER_NAME
}

function phase_destroy()
{
    ################################################################################
    logb "Deleting all resources"
    ################################################################################

    run kubectl get cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME

    ################################################################################
    pause "Delete cluster above? THIS OPERATION CAN'T BE UNDONE!"
    ################################################################################

    run kubectl delete cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME

    run eksctl get cluster --name $MANAGER_CLUSTER_NAME --region $AWS_REGION

    ################################################################################
    pause "Delete Manager Cluster ? THIS OPERATION CAN'T BE UNDONE!"
    ################################################################################
    run eksctl delete cluster --wait --name $MANAGER_CLUSTER_NAME --region $AWS_REGION
}

function phase_upgrade()
{
    local patch="[{ 
        \"op\": \"add\",
        \"path\": \"/spec/kubernetesVersion\",
        \"value\": \"v$CLUSTER_VERSION_NEW\"
    }]"

    ################################################################################
    pause "Upgrade Cluster to version v$CLUSTER_VERSION_NEW"
    ################################################################################

    run kubectl patch --type=json -n $CLUSTER_NAMESPACE cluster/$CLUSTER_NAME -p "\"$patch\""
}

function phase_autoscale()
{
    local min=1 max=5
    local patch="[{
        \"op\": \"add\",
        \"path\": \"/spec/workers/0/autoscaling\",
        \"value\": {
            \"enabled\": true,
            \"minSize\": $min,
            \"maxSize\": $max
        }
    }]"

    ################################################################################
    pause "Enable node autoscaling on first Cluster nodepool min=$min, max=$max"
    ################################################################################

    run kubectl patch --type=json -n $CLUSTER_NAMESPACE cluster/$CLUSTER_NAME -p "\"$patch\""
}

for phase in ${PHASES[@]}; do
    time_phase phase_${phase//-/_}
done
