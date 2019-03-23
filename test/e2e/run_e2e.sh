#!/bin/bash
set -euo pipefail
set -x

E2E_TEST_TYPE="${E2E_TEST_TYPE:-"conformance"}"
E2E_SKIP_CLUSTER_UPDATE="${E2E_SKIP_CLUSTER_UPDATE:-"false"}"
# PREFIX used to contruct the cluster local_id which needs to be unique between
# the different pipeline steps
E2E_TEST_TYPE_PREFIX="${E2E_TEST_TYPE_PREFIX:-"c"}"

case "$E2E_TEST_TYPE" in
    conformance)
        E2E_TEST_TYPE_PREFIX="c"
        ;;
    statefulset)
        E2E_TEST_TYPE_PREFIX="s"
        ;;
    zalando)
        E2E_TEST_TYPE_PREFIX="z"
        ;;
    *)
        echo "Invalid value for \$E2E_TEST_TYPE must be one of 'conformance', 'statefulset', 'zalando'"
        exit 1
        ;;
esac

# fetch internal configuration values
kubectl --namespace default get configmap teapot-kubernetes-e2e-config -o jsonpath='{.data.internal_config\.sh}' > internal_config.sh
# shellcheck disable=SC1091
source internal_config.sh

# variables set for making it possible to run script locally
CDP_BUILD_VERSION="${CDP_BUILD_VERSION:-"local-1"}"
CDP_TARGET_REPOSITORY="${CDP_TARGET_REPOSITORY:-"github.com/zalando-incubator/kubernetes-on-aws"}"
CDP_TARGET_COMMIT_ID="${CDP_TARGET_COMMIT_ID:-"dev"}"
CDP_HEAD_COMMIT_ID="${CDP_HEAD_COMMIT_ID:-"$(git describe --tags --always)"}"

# TODO: we need the date in LOCAL_ID because of CDP retriggering
LOCAL_ID="${LOCAL_ID:-"kube-e2e-$CDP_BUILD_VERSION-${E2E_TEST_TYPE_PREFIX}$(date +'%H%M%S')"}"
API_SERVER_URL="https://${LOCAL_ID}.${HOSTED_ZONE}"
INFRASTRUCTURE_ACCOUNT="aws:${AWS_ACCOUNT}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-"etcd-server.etcd.${HOSTED_ZONE}:2379"}"
CLUSTER_ID="${INFRASTRUCTURE_ACCOUNT}:${REGION}:${LOCAL_ID}"
WORKER_SHARED_SECRET="${WORKER_SHARED_SECRET:-"$(pwgen 30 -n1)"}"

export LOCAL_ID="$LOCAL_ID"
export API_SERVER_URL="$API_SERVER_URL"
export INFRASTRUCTURE_ACCOUNT="$INFRASTRUCTURE_ACCOUNT"
export ETCD_ENDPOINTS="$ETCD_ENDPOINTS"
export CLUSTER_ID="$CLUSTER_ID"
export WORKER_SHARED_SECRET="$WORKER_SHARED_SECRET"

# if E2E_SKIP_CLUSTER_UPDATE is true, don't create a cluster from base first
if [ "$E2E_SKIP_CLUSTER_UPDATE" != "true" ]; then
    BASE_CFG_PATH="base_config"

    # get head cluster config channel
    if [ -d "$BASE_CFG_PATH" ]; then
        rm -rf "$BASE_CFG_PATH"
    fi
    git clone "https://$CDP_TARGET_REPOSITORY" "$BASE_CFG_PATH"
    git -C "$BASE_CFG_PATH" reset --hard "${CDP_TARGET_COMMIT_ID}"

    # generate cluster.yaml
    # call the cluster_config.sh from base git checkout if possible
    if [ -f "$BASE_CFG_PATH/test/e2e/cluster_config.sh" ]; then
        "./$BASE_CFG_PATH/test/e2e/cluster_config.sh" \
        "${CDP_TARGET_COMMIT_ID}" "requested" > base_cluster.yaml
    else
        "./cluster_config.sh" "${CDP_TARGET_COMMIT_ID}" \
        "requested" > base_cluster.yaml
    fi

    # Create cluster
    clm provision \
        --token="${WORKER_SHARED_SECRET}" \
        --directory="$(pwd)/$BASE_CFG_PATH" \
        --assumed-role=cluster-lifecycle-manager-entrypoint \
        --debug \
        --registry=base_cluster.yaml
fi

# generate updated clusters.yaml
"./cluster_config.sh" "${CDP_HEAD_COMMIT_ID}" "ready" > head_cluster.yaml
# Update cluster
clm provision \
    --token="${WORKER_SHARED_SECRET}" \
    --directory="$(pwd)/../.." \
    --assumed-role=cluster-lifecycle-manager-entrypoint \
    --debug \
    --registry=head_cluster.yaml

# create kubeconfig
cat >kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${API_SERVER_URL}
  name: e2e-cluster
contexts:
- context:
    cluster: e2e-cluster
    namespace: default
    user: e2e-bot
  name: e2e-cluster
current-context: e2e-cluster
preferences: {}
users:
- name: e2e-bot
  user:
    token: ${WORKER_SHARED_SECRET}
EOF

KUBECONFIG="$(pwd)/kubeconfig"
export KUBECONFIG="$KUBECONFIG"

# wait for resouces to be ready
# TODO: make a feature of CLM --wait-for-kube-system
"./wait-for-update.py" --timeout 1200


conformance_tests() {
    ginkgo -nodes=25 -flakeAttempts=2 \
        -focus="\[Conformance\]" \
        -skip="\[Serial\]" \
        "e2e.test" -- -delete-namespace-on-failure=false
}

statefulset_tests() {
    # StatefulSetBasic tests
    # Test running a redis StatefulSet with PVCs
    ginkgo -nodes=25 -flakeAttempts=2 \
        -focus="(\[StatefulSetBasic\]|\[Feature:StatefulSet\]\s\[Slow\].*CockroachDB)" \
        -skip="\[Conformance\]" \
        "e2e.test" -- -delete-namespace-on-failure=false
}

zalando_tests() {
    ginkgo -nodes=25 -flakeAttempts=2 \
        -focus="\[Zalando\]" \
        -skip="\[Egress\]" \
        "e2e.test" -- -delete-namespace-on-failure=false
}

# run tests
case "$E2E_TEST_TYPE" in
    conformance)
        conformance_tests
        ;;
    statefulset)
        statefulset_tests
        ;;
    zalando)
        zalando_tests
        ;;
esac

# delete cluster
clm decommission \
    --remove-volumes \
    --token="${WORKER_SHARED_SECRET}" \
    --directory="$(pwd)/../.." \
    --assumed-role=cluster-lifecycle-manager-entrypoint \
    --debug \
    --registry=head_cluster.yaml
