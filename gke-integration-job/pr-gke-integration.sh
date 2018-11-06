#!/usr/bin/env bash

set -o errexit

############################################################
# REPO_OWNER, REPO_NAME and PULL_NUMBER are set by ProwJob #
############################################################

ROOT_PATH="/home/prow/go/src/github.com/kyma-project/kyma"

echo "
################################################################################
# Provisioning GKE cluster
################################################################################
"

CLUSTER_NAME=${REPO_OWNER}-${REPO_NAME}-${PULL_NUMBER} bash ${ROOT_PATH}/prow/scripts/provision-gke-cluster.sh
