#!/usr/bin/env bash
# test application running in multiple versions of kubernetes ]

# exit on unset vars
set -u

function add_hosts {
        ENDPOINTSLIST=(127.0.0.1    localhost ml-api-adapter.local central-ledger.local account-lookup-service.local 
                   account-lookup-service-admin.local quoting-service.local central-settlement-service.local 
                   transaction-request-service.local central-settlement.local bulk-api-adapter.local 
                   moja-simulator.local sim-payerfsp.local sim-payeefsp.local sim-testfsp1.local sim-testfsp2.local 
                   sim-testfsp3.local sim-testfsp4.local mojaloop-simulators.local finance-portal.local
                   operator-settlement.local settlement-management.local toolkit.local testing-toolkit-specapi.local
                   admin-api-svc.local transfer-api-svc.local ) 

        export ENDPOINTS=`echo ${ENDPOINTSLIST[*]}`

        perl -p -i.bak -e 's/127\.0\.0\.1.*localhost.*$/$ENV{ENDPOINTS} /' /etc/hosts

}

function add_helm_repos { 
  ## add the helm repos required to install and run ML and the v14 PoC
        printf "==> add the helm repos required to install and run ML and the v14 PoC\n" 
        su - $k8s_user -c "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx  > /dev/null 2>&1 "
        su - $k8s_user -c "helm repo update > /dev/null 2>&1 "
}

function install_v14poc_charts {
  printf "\n========================================================================================\n"
  printf "installing mojaloop v14 PoC \n"
  printf "========================================================================================\n"
        printf "==> install backend services <$BACKEND_NAME> helm chart. Wait upto $timeout_secs secs for ready state\n "
        start_timer=$(date +%s)
        su - $k8s_user -c "KUBECONFIG=/tmp/k3s.yaml helm upgrade --install --wait --timeout $timeout_secs $BACKEND_NAME \
                           $CHARTS_WORKING_DIR/mojaloop/example-backend"
        
        end_timer=$(date +%s)
        elapsed_secs=$(echo "$end_timer - $start_timer" | bc )
        if [[ `helm status $BACKEND_NAME | grep "^STATUS:" | awk '{ print $2 }' ` = "deployed" ]] ; then 
                printf "    helm release <$BACKEND_NAME> deployed sucessfully after <$elapsed_secs> secs \n\n"
        else 
                echo "    Error: $BACKEND_NAME helm chart  deployment failed "
                printf "  Command : \n"
                printf "  su - $k8s_user -c \"helm upgrade --install --wait --timeout $timeout_secs "
                printf "$CHARTS_WORKING_DIR/mojaloop/example-backend\" \n "
                exit 1
        fi 

        printf "==> install v14 PoC services <$RELEASE_NAME> helm chart. Wait upto $timeout_secs secs for ready state\n"
        start_timer=$(date +%s)
        su - $k8s_user -c "KUBECONFIG=/tmp/k3s.yaml helm upgrade --install --wait --timeout $timeout_secs $RELEASE_NAME \
                           $CHARTS_WORKING_DIR/mojaloop/mojaloop" >> /dev/null 2>&1 
        end_timer=$(date +%s)
        elapsed_secs=$(echo "$end_timer - $start_timer" | bc )
        if [[ `KUBECONFIG=/tmp/k3s.yaml helm status $RELEASE_NAME | grep "^STATUS:" | awk '{ print $2 }' ` = "deployed" ]] ; then 
                printf "    helm release <$RELEASE_NAME> deployed sucessfully after <$elapsed_secs> secs \n\n "
        else 
                printf "    Error: $RELEASE_NAME helm chart  deployment failed \n"
                printf "    Command: su - $k8s_user -c \"helm upgrade --install --wait --timeout "
                printf "$timeout_secs $RELEASE_NAME $CHARTS_WORKING_DIR/mojaloop/mojaloop\" \n "
                exit 1
        fi 
}

function post_install_health_checks {
        TIMEOUT=20 #seconds
        printf  "==> checking health endpoints to verify deployment\n" 
        for ep in ${HEALTH_ENDPOINTS_LIST[@]}; do
                printf  "Endpoint: $ep   "
                        i=0
                        while [ ${i} -le ${TIMEOUT} ] ; do
                                if [[  `curl -s http://$ep.local/health | \
                                        perl -nle '$count++ while /OK+/g; END {print $count}' ` -lt 2 ]] ; then
                                        i=$(( i + 10 ))
                                        sleep 10 
                                else 
                                        printf "[ok] \n"
                                        break
                                fi    
                        done 
                        if [ $i -gt $TIMEOUT ] ; then  
                                printf "[failed]\n"            
                                printf "Error: curl -s http://$ep.local/health  endpoint healthcheck failed\n"
                                exit 1  
                        fi        
        done

}

function set_versions_to_test {
        # if the versions to test not specified -> use the default version.
        if [ -z ${versions+x} ] ; then
                printf " -v flag not specified => defaulting to CURRENT_K8S_VERSIONS %s \n" $DEFAULT_VERSION
                versions=$DEFAULT_VERSION
        fi

        # test we get valid k8S versions selected
        if [[ "$versions" == "all" ]]  ; then
                versions_list=${CURRENT_K8S_VERSIONS[*]}
                printf  "testing k8s versions: %s " ${versions_list[*]} 
        elif [[ " ${CURRENT_K8S_VERSIONS[*]} " =~ "$versions" ]]; then
                printf  " testing k8s version : %s\n" $versions
                versions_list=($versions)
        else 
                printf "Error: invalid or not supported k8s version specified \n"
                printf "please specify a valid k8s version \n\n"
                showUsage
        fi
}

function install_k8s {
        
        printf "==> Uninstalling any existing k8s installations\n"
        /usr/local/bin/k3s-uninstall.sh > /dev/null 2>&1   
        printf "==> Installing k8s version: %s\n" $1  
        curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="600" \
                                INSTALL_K3S_CHANNEL=$1 \
                                INSTALL_K3S_EXEC=" --no-deploy traefik " sh  > /dev/null 2>&1


        cp /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml
        chown $k8s_user /tmp/k3s.yaml
        chmod 600 /tmp/k3s.yaml   
        export KUBECONFIG=/tmp/k3s.yaml  
        sleep 30  
        if [[ `su - $k8s_user -c "kubectl get nodes " > /dev/null 2>&1 ` -ne 0 ]] ; then 
                printf "    Error: k8s server install failed\n"
        fi           

        nginx_flags="--set controller.watchIngressWithoutClass=true"
        if [[ $i == "v1.22" ]] ; then
                nginx_version="4.0.6"        
        else 
                nginx_version="3.33.0"
                nginx_flags=" "          
        fi
        printf "==> installing nginx-ingress version: %s\n" $nginx_version  

        start_timer=$(date +%s)
        su - $k8s_user -c "KUBECONFIG=/tmp/k3s.yaml helm upgrade --install --wait --timeout 600s ingress-nginx \
                                ingress-nginx/ingress-nginx --version=$nginx_version $nginx_flags " >> /dev/null 2>&1
        end_timer=$(date +%s)
        elapsed_secs=$(echo "$end_timer - $start_timer" | bc )

        # Test lines
        su - $k8s_user -c "KUBECONFIG=/tmp/k3s.yaml kubectl get pods --all-namespaces"
        if [[ `KUBECONFIG=/tmp/k3s.yaml helm status ingress-nginx | grep "^STATUS:" | awk '{ print $2 }' ` = "deployed" ]] ; then 
                printf "    helm install of ingress-nginx sucessful after <$elapsed_secs> secs \n\n"
        else 
                printf "    Error: ingress-nginx helm chart  deployment failed "
                exit 1
        fi 

}

function run_k8s_version_tests {
        printf "========================================================================================\n"
        printf "Running Mojaloop Version Tests \n"
        printf "========================================================================================\n"
        for i in ${versions_list[@]}; do
                echo "CURRENT_K8S_VERSIONS{$i}"
                install_k8s $i
                # assuming this is ok so far => now install the v14.0 ML helm charts
                # should check that the repo exists at this point and clone it if not existing.
                install_v14poc_charts
                post_install_health_checks
        done
}

function verify_user {
# ensure that the user for k8s exists
        if id -u "$k8s_user" >/dev/null; then
                return
        else
                printf "    Error: The user %s does not exist\n" $k8s_user
                exit 1 
        fi
}


################################################################################
# Function: showUsage
################################################################################
# Description:		Display usage message
# Arguments:		none
# Return values:	none
#
function showUsage {
	if [ $# -ne 0 ] ; then
		echo "Incorrect number of arguments passed to function $0"
		exit 1
	else
echo  "USAGE: $0 [-m mode] [-v version(s)] [-u user] [-t secs] [-u user] [-r] [-h|H]
Example 1 : version-test.sh -m noinstall # helm install charts on current k8s & ingress 
Example 2 : version-test.sh -m install -v all  # tests charts against k8s versions 1.20,1.21 and 1.22

Options:
-m mode ............ install|noinstall (default : noinstall of k8s and nginx )
-t timeout_secs .... seconds to wait for helm chart install (default:800)
-v k8s versions .... all|v1.20|v1.21|v1.22 (default :  v1.22)
-u user ............ non root user to run helm and k8s commands (default : vagrant)
-r ................. refresh the PoC helm charts (default: refresh if mode is install ; otherwise not)
-h|H ............... display this message
"
	fi
}

################################################################################
# MAIN
################################################################################

##
# Environment Config
##
SCRIPTNAME=$0
# Program paths
BASE_DIR=$( cd $(dirname "$0")/../.. ; pwd )
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CHARTS_WORKING_DIR=${CHARTS_WORKING_DIR:-"/vagrant/charts"}
BACKEND_NAME="be" 
RELEASE_NAME="ml"
DEFAULT_TIMEOUT_SECS="800s"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
DEFAULT_VERSION="v1.22" # default version to test
DEFAULT_K8S_USER="vagrant"

HEALTH_ENDPOINTS_LIST=("admin-api-svc" "transfer-api-svc")
CURRENT_K8S_VERSIONS=("v1.20" "v1.21"  "v1.22")
versions_list=(" ")
nginx_version=""

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi

# Check arguments
# if [ $# -lt 1 ] ; then
# 	showUsage
# 	echo "Not enough arguments -m mode must be specified "
# 	exit 1
# fi

# Process command line options as required
while getopts "m:t:u:v:rhH" OPTION ; do
   case "${OPTION}" in
        m)	mode="${OPTARG}"
        ;;
        t)      timeout_secs="${OPTARG}"
        ;;
        v)	versions="${OPTARG}"
        ;;
        u)      k8s_user="${OPTARG}"
        ;;
        r)      refresh_update_helm="true"
        ;;
        h|H)	showUsage
                exit 0
        ;;
        *)	echo  "unknown option"
                showUsage
                exit 1
        ;;
    esac
done

printf "\n\n*** Mojaloop -  Kubernetes Version Testing Tool ***\n\n"

# set the user to run k8s commands
if [ -z ${k8s_user+x} ] ; then
        k8s_user=$DEFAULT_K8S_USER
fi

printf " running kubernetes and helm commands with user : %s\n" $k8s_user
verify_user 

# retval=`su - $k8s_user -c "kubectl get nodes "`
# echo $retval

# if timeout not set , use the default 
# set the user to run k8s commands
if [ -z ${timeout_secs+x} ] ; then
        timeout_secs=$DEFAULT_TIMEOUT_SECS
else 
        # ensure theer is an s in timeout_secs
        x=`echo $timeout_secs | tr -d "s"`
        x+="s"
        timeout_secs=$x
        printf " helm timeout set to : %s \n" $timeout_secs
fi

# if the mode not specified -> default to not installing k8s server.
# this allows testing to happen on previously deployed k8s server
if [ -z ${mode+x} ] ; then
        #printf " -m flag not specified \n"
	mode="noinstall"
fi

# if mode = install we install the k3s server and appropriate nginx 
if [[ "$mode" == "install" ]]  ; then
	printf " -m install specified => k8s and nginx version(s) will be installed\n"
        add_hosts
        add_helm_repos
        set_versions_to_test

        # for each k8s version -> install server -> install charts -> check
        run_k8s_version_tests

elif [[ "$mode" == "noinstall" ]]  ; then
        # just install the charts against already installed k8s
	printf " k8s and nginx ingress will not be installed\n"
        printf " ignoring and/or clearing any setting for -v flag\n "
        if [[ ! -z ${refresh_update_helm+x} ]] ; then 
            add_helm_repos
        fi 
        versions=$DEFAULT_VERSION 
        install_v14poc_charts
        post_install_health_checks
fi