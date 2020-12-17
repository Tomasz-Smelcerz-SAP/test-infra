#!/usr/bin/env bash

#Description: Kyma Integration plan on GKE. This scripts implements a pipeline that consists of many steps. The purpose is to install and test Kyma on real GKE cluster.
#
#
#Expected vars:
#
# - REPO_OWNER - Set up by prow, repository owner/organization
# - REPO_NAME - Set up by prow, repository name
# - BUILD_TYPE - Set up by prow, pr/master/release
# - DOCKER_PUSH_REPOSITORY - Docker repository hostname
# - DOCKER_PUSH_DIRECTORY - Docker "top-level" directory (with leading "/")
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - CLOUDSDK_CORE_PROJECT - GCP project for all GCP resources used during execution (Service Account, IP Address, DNS Zone, image registry etc.)
# - CLOUDSDK_COMPUTE_REGION - GCP compute region
# - CLOUDSDK_DNS_ZONE_NAME - GCP zone name (not its DNS name!)
# - GOOGLE_APPLICATION_CREDENTIALS - GCP Service Account key file path
# - MACHINE_TYPE (optional): GKE machine type
# - CLUSTER_VERSION (optional): GKE cluster version
# - KYMA_ARTIFACTS_BUCKET: GCP bucket
# - LOG_COLLECTOR_SLACK_TOKEN: Slack token for test-log-collector
#
#Permissions: In order to run this script you need to use a service account with permissions equivalent to the following GCP roles:
# - Compute Admin
# - Kubernetes Engine Admin
# - Kubernetes Engine Cluster Admin
# - DNS Administrator
# - Service Account User
# - Storage Admin
# - Compute Network Admin

set -o errexit

ENABLE_TEST_LOG_COLLECTOR=false
TEST_LOG_COLLECTOR_PROW_JOB_NAME="post-master-kyma-gke-integration"

discoverUnsetVar=false
for var in REPO_OWNER REPO_NAME DOCKER_PUSH_REPOSITORY KYMA_PROJECT_DIR CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_DNS_ZONE_NAME GOOGLE_APPLICATION_CREDENTIALS KYMA_ARTIFACTS_BUCKET GCR_PUSH_GOOGLE_APPLICATION_CREDENTIALS; do
    if [ -z "${!var}" ] ; then
        log::error "$var is not set"
        discoverUnsetVar=true
    fi
done
if [ "${discoverUnsetVar}" = true ] ; then
    exit 1
fi

#Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export KYMA_SOURCES_DIR="${KYMA_PROJECT_DIR}/kyma"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"

KYMA_LABEL_PREFIX="kyma-project.io"
KYMA_TEST_LABEL_PREFIX="${KYMA_LABEL_PREFIX}/test"
INTEGRATION_TEST_LABEL_QUERY="${KYMA_TEST_LABEL_PREFIX}.integration=true"

# shellcheck source=prow/scripts/lib/common.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/common.sh"
# shellcheck source=prow/scripts/lib/kyma-cli.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/kyma-cli.sh"
# shellcheck source=prow/scripts/lib/log.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/log.sh"
# shellcheck source=prow/scripts/library.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/library.sh"

trap gkeCleanup EXIT INT

if [[ "${BUILD_TYPE}" == "pr" ]]; then
    log::info "Execute Job Guard"
    # shellcheck disable=SC2031
    "${TEST_INFRA_SOURCES_DIR}/development/jobguard/scripts/run.sh"
fi

# Enforce lowercase
readonly REPO_OWNER=$(echo "${REPO_OWNER}" | tr '[:upper:]' '[:lower:]')
export REPO_OWNER
readonly REPO_NAME=$(echo "${REPO_NAME}" | tr '[:upper:]' '[:lower:]')
export REPO_NAME

RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c10)

if [[ "$BUILD_TYPE" == "pr" ]]; then
    # In case of PR, operate on PR number
    readonly COMMON_NAME_PREFIX="gkeint-pr"
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${PULL_NUMBER}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    KYMA_SOURCE="PR-${PULL_NUMBER}"
elif [[ "$BUILD_TYPE" == "release" ]]; then
    readonly COMMON_NAME_PREFIX="gkeint-rel"
    readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    readonly RELEASE_VERSION=$(cat "${SCRIPT_DIR}/../../RELEASE_VERSION")
    log::info "Reading release version from RELEASE_VERSION file, got: ${RELEASE_VERSION}"
    KYMA_SOURCE="${RELEASE_VERSION}"
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
else
    # Otherwise (master), operate on triggering commit id
    readonly COMMON_NAME_PREFIX="gkeint-commit"
    readonly COMMIT_ID="${PULL_BASE_SHA::8}"
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${COMMIT_ID}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    KYMA_SOURCE="${COMMIT_ID}"
    export KYMA_INSTALLER_IMAGE
fi


### Cluster name must be less than 40 characters!
export CLUSTER_NAME="${COMMON_NAME}"

export GCLOUD_NETWORK_NAME="${COMMON_NAME_PREFIX}-net"
export GCLOUD_SUBNET_NAME="${COMMON_NAME_PREFIX}-subnet"

### For provision-gke-cluster.sh
export GCLOUD_PROJECT_NAME="${CLOUDSDK_CORE_PROJECT}"
export GCLOUD_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE}"

#Local variables
DNS_SUBDOMAIN="${COMMON_NAME}"

#Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"

log::info "Authenticate"
date
common::init
INSTALL_DIR=$(mktemp -d) install::kyma_cli

DNS_DOMAIN="$(gcloud dns managed-zones describe "${CLOUDSDK_DNS_ZONE_NAME}" --format="value(dnsName)")"

log::info "Reserve IP Address for Ingressgateway"
GATEWAY_IP_ADDRESS_NAME="${COMMON_NAME}"
GATEWAY_IP_ADDRESS=$(IP_ADDRESS_NAME=${GATEWAY_IP_ADDRESS_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/reserve-ip-address.sh")
CLEANUP_GATEWAY_IP_ADDRESS="true"
log::info "Created IP Address for Ingressgateway: ${GATEWAY_IP_ADDRESS}"


log::info "Create DNS Record for Ingressgateway IP"
GATEWAY_DNS_FULL_NAME="*.${DNS_SUBDOMAIN}.${DNS_DOMAIN}"
CLEANUP_GATEWAY_DNS_RECORD="true"
IP_ADDRESS=${GATEWAY_IP_ADDRESS} DNS_FULL_NAME=${GATEWAY_DNS_FULL_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-dns-record.sh"


NETWORK_EXISTS=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/network-exists.sh")
if [ "$NETWORK_EXISTS" -gt 0 ]; then
    log::info "Create ${GCLOUD_NETWORK_NAME} network with ${GCLOUD_SUBNET_NAME} subnet"
    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-network-with-subnet.sh"
else
    log::warn "Network ${GCLOUD_NETWORK_NAME} exists"
fi


log::info "Provision cluster: \"${CLUSTER_NAME}\""
export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
if [ -z "$MACHINE_TYPE" ]; then
      export MACHINE_TYPE="${DEFAULT_MACHINE_TYPE}"
fi
if [ -z "${CLUSTER_VERSION}" ]; then
      export CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION}"
fi
CLEANUP_CLUSTER="true"
"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/provision-gke-cluster.sh"

log::info "Generate self-signed certificate"
DOMAIN="${DNS_SUBDOMAIN}.${DNS_DOMAIN%?}"
export DOMAIN
CERT_KEY=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/generate-self-signed-cert.sh")
TLS_CERT=$(echo "${CERT_KEY}" | head -1)
TLS_KEY=$(echo "${CERT_KEY}" | tail -1)

log::info "Create Kyma CLI overrides"

cat << EOF > "$PWD/kyma-installer-overrides.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: "installation-config-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
data:
  global.domainName: "${DOMAIN}"
  global.loadBalancerIP: "${GATEWAY_IP_ADDRESS}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "core-test-ui-acceptance-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
    component: core
data:
  test.acceptance.ui.logging.enabled: "true"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "application-registry-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
    component: application-connector
data:
  application-registry.deployment.args.detailedErrorResponse: "true"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "istio-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
    component: istio
data:
  kyma_istio_operator: |
    apiVersion: install.istio.io/v1alpha1
    kind: IstioOperator
    metadata:
      namespace: istio-system
    spec:
      components:
        ingressGateways:
          - name: istio-ingressgateway
            k8s:
              service:
                loadBalancerIP: ${GATEWAY_IP_ADDRESS}
                type: LoadBalancer
EOF
cat "$PWD/kyma-installer-overrides.yaml"

log::info "Installation triggered"

yes | kyma install \
  --ci \
  -s "${KYMA_SOURCE}" \
  -o "$PWD/kyma-installer-overrides.yaml" \
  --domain "${DOMAIN}" \
  --tls-cert="${TLS_CERT}" \
  --tls-key="${TLS_KEY}" \
  --timeout 60m

if [ -n "$(kubectl get  service -n kyma-system apiserver-proxy-ssl --ignore-not-found)" ]; then
    log::info "Create DNS Record for Apiserver proxy IP"
    APISERVER_IP_ADDRESS=$(kubectl get service -n kyma-system apiserver-proxy-ssl -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    APISERVER_DNS_FULL_NAME="apiserver.${DNS_SUBDOMAIN}.${DNS_DOMAIN}"
    CLEANUP_APISERVER_DNS_RECORD="true"
    IP_ADDRESS=${APISERVER_IP_ADDRESS} DNS_FULL_NAME=${APISERVER_DNS_FULL_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-dns-record.sh"
fi

# enable test-log-collector before tests; if prowjob fails before test phase we do not have any reason to enable it earlier
if [[ "${BUILD_TYPE}" == "master" && -n "${LOG_COLLECTOR_SLACK_TOKEN}" ]]; then
  ENABLE_TEST_LOG_COLLECTOR=true
fi

log::info "Test Kyma"
# shellcheck disable=SC2031
"${TEST_INFRA_SOURCES_DIR}"/prow/scripts/kyma-testing.sh "${INTEGRATION_TEST_LABEL_QUERY}"

log::success "Integration Test successful"

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"
