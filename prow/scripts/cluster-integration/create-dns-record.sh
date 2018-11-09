#!/usr/bin/env bash

#In order to run this script you need to use a service account with DNS Administrator role

#IP_ADDRESS="8.8.8.8" PROJECT="kyma-project" DNS_ZONE="build-kyma" DNS_NAME="ts-test.build.kyma-project.io" ./create-dns-record.sh

#TODO: Rename PROJECT to GCP_PROJECT, DNS_NAME to FULL_DNS_NAME, DNS_ZONE to DNS_ZONE_NAME

set -o errexit

discoverUnsetVar=false

for var in IP_ADDRESS PROJECT DNS_ZONE DNS_NAME; do
    if [ -z "${!var}" ] ; then
        echo "ERROR: $var is not set"
        discoverUnsetVar=true
    fi
done
if [ "${discoverUnsetVar}" = true ] ; then
    exit 1
fi


if [ -z "$IP_ADDRESS" ]; then
    echo "\$IP_ADDRESS is empty"
    exit 1
fi

if [ -z "$PROJECT" ]; then
    echo "\$PROJECT is empty"
    exit 1
fi

if [ -z "$DNS_ZONE" ]; then
    echo "\$DNS_ZONE is empty"
    exit 1
fi

if [ -z "$DNS_NAME" ]; then
    echo "\$DNS_NAME is empty"
    exit 1
fi

gcloud dns --project="${PROJECT}" record-sets transaction start --zone="${DNS_ZONE}"

gcloud dns --project="${PROJECT}" record-sets transaction add "${IP_ADDRESS}" --name="${DNS_NAME}" --ttl=300 --type=A --zone="${DNS_ZONE}"

gcloud dns --project="${PROJECT}" record-sets transaction execute --zone="${DNS_ZONE}"

SECONDS=0
END_TIME=$((SECONDS+600)) #600 seconds == 10 minutes

while [ ${SECONDS} -lt ${END_TIME} ];do
    echo "Trying to resolve ${DNS_NAME}"
    sleep 10

    RESOLVED_IP_ADDRESS=$(dig +short "${DNS_NAME}")

    if [ "${RESOLVED_IP_ADDRESS}" = "${IP_ADDRESS}" ]; then
        echo "Successfully resolved ${DNS_NAME} to ${RESOLVED_IP_ADDRESS}"
        exit 0
    fi

done

echo "Cannot resolve ${DNS_NAME} to expected IP_ADDRESS: ${IP_ADDRESS}."
exit 1
