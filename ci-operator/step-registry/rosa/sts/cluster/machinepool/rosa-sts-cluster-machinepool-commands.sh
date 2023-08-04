#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Get cluster 
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "CLUSTER_ID is $CLUSTER_ID"

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Check if this is a HCP cluster
is_hcp_cluster="$(rosa describe cluster -c "$CLUSTER_ID" -o json  | jq -r ".hypershift.enabled")"
echo "hypershift.enabled is set to $is_hcp_cluster"

REGION="$(rosa describe cluster -c "$CLUSTER_ID" -o json  | jq -r '.region.id' )"

function listMachinepool() {
  rosa list machinepool --cluster "$CLUSTER_ID"
}

function createMachinepool() {
    echo "Read user inputs and create machinepool"
    # Hypershift machinepool creation goes per availability zone
    # Create Machinepool per zone, so looping to achieve user defined size
    # based on the number of replica script picks the zone
    if [[ "$INFRA_REPLICAS" -eq 1 ]]; then ZONES="a"; elif [[ "$INFRA_REPLICAS" -eq 2 ]]; then ZONES="a b"; elif [[ "$INFRA_REPLICAS" -eq 3 ]]; then ZONES="a b c"; fi

    for ZONE in ${ZONES}; 
    do
      rosa create machinepool \
                              --cluster "${CLUSTER_ID}" \
                              --name "$INFRA_NAME-${ZONE}" \
                              --instance-type "$INFRA_MACHINE_TYPE" \
                              --replicas 1 \
                              --availability-zone "${REGION}${ZONE}" \
                              --labels "$INFRA_NODE_LABELS" \
                              --taints "$INFRA_NODE_TAINTS"
    done    

    echo "All new Machinepools in cluster $CLUSTER_ID"
    listMachinepool
    return 0
}

echo "Existing Machinepools in cluster $CLUSTER_ID"
listMachinepool
if [[ "$INFRA_REPLICAS" != "" ]] && [[ "$is_hcp_cluster" == "true" ]]; then 
  createMachinepool
fi