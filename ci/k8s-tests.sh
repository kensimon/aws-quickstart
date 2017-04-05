#!/bin/bash

# Copyright 2017 by the contributors
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# This runs integration tests for the local repository, deploying it to
# CloudFormation and testing various bits of functionality underneath.

set -o errexit
set -o nounset
set -o pipefail
set -o verbose

if ! grep -q Alpine /etc/issue 2>/dev/null; then
    echo "This script is must be run in a docker container (and will make changes to the filesystem, including /root/.ssh). Exiting."
    exit 1
fi

function try_n_times() {
    num_times=$1
    cmd=$2

    for i in $(seq 1 $num_times); do
        if [[ $i -le $num_times ]]; then
            eval "$cmd" && break || (test $i -lt $num_times && sleep 1 || return 1)
        fi
    done
}

# Overridable parameters
REGION="${REGION:-us-west-2}"
AZ="${AZ:-us-west-2c}"
S3_BUCKET="${S3_BUCKET:-"heptio-aws-quickstart-test"}"
S3_PREFIX="${S3_PREFIX:-"heptio/kubernetes"}"
SSH_KEY="${SSH_KEY:-/tmp/ssh/id_rsa}"
SSH_KEY_NAME="${SSH_KEY_NAME:-jenkins}"
STACK_NAME="${STACK_NAME:-}"

# Fall back on the git shasum for the stack name
if [[ -z "${STACK_NAME}" ]]; then
    STACK_NAME="qs-ci-$(git rev-parse --short HEAD)"
fi

# Set/ensure env vars needed by AWS, etc
export AWS_DEFAULT_REGION="${REGION}"

# Setup ssh.  Due to SSH being incredibly paranoid about filesystem permissions
# we just create our own ssh directory and set it from there.  (This also
# allows the docker volume mounts to be read-only.)
mkdir -p /root/.ssh
chmod 0700 /root/.ssh
cp "${SSH_KEY}" /root/.ssh/identity
export SSH_KEY=/root/.ssh/identity
chmod 0600 $SSH_KEY

aws --version
kubectl version --client

aws s3 sync --acl=public-read --delete ./templates "s3://${S3_BUCKET}/${S3_PREFIX}/${STACK_NAME}/templates/"
aws s3 sync --acl=public-read --delete ./scripts "s3://${S3_BUCKET}/${S3_PREFIX}/${STACK_NAME}/scripts/"

# TODO: maybe do a calico test and a weave test as separate runs
aws cloudformation create-stack \
  --disable-rollback \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-url "https://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}/${STACK_NAME}/templates/kubernetes-cluster-with-new-vpc.template" \
  --parameters \
  ParameterKey=AvailabilityZone,ParameterValue="${AZ}" \
  ParameterKey=KeyName,ParameterValue="${SSH_KEY_NAME}" \
  ParameterKey=QSS3BucketName,ParameterValue="${S3_BUCKET}" \
  ParameterKey=QSS3KeyPrefix,ParameterValue="${S3_PREFIX}/${STACK_NAME}" \
  ParameterKey=AdminIngressLocation,ParameterValue=0.0.0.0/0 \
  ParameterKey=NetworkingProvider,ParameterValue=calico \
  --capabilities=CAPABILITY_IAM

aws cloudformation wait stack-create-complete --stack-name "${STACK_NAME}"

# Pre-load the SSH host keys
BASTION_IP=$(aws cloudformation describe-stacks \
    --query 'Stacks[*].Outputs[?OutputKey == `BastionHostPublicIp`].OutputValue' \
    --output text --stack-name $STACK_NAME
)
MASTER_IP=$(aws cloudformation describe-stacks \
    --query 'Stacks[*].Outputs[?OutputKey == `MasterPrivateIp`].OutputValue' \
    --output text --stack-name $STACK_NAME
)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ubuntu@${BASTION_IP} nc %h %p" ubuntu@${MASTER_IP} exit 0

# TODO: this is a hack... GetKubeConfigCommand has a fake
# "SSH_KEY=path/to/blah.pem" output, we want to override that with our actual
# one.
KUBECONFIG_COMMAND=$(aws cloudformation describe-stacks \
    --query 'Stacks[*].Outputs[?OutputKey == `GetKubeConfigCommand`].OutputValue' \
    --output text --stack-name $STACK_NAME \
    | sed "s!path/to/${SSH_KEY_NAME}.pem!${SSH_KEY}!"
)

# Other than that, just run the command as the Output suggests
eval "${KUBECONFIG_COMMAND}"

# It should have copied a "kubeconfig" file to our current directory
export KUBECONFIG=./kubeconfig

########################
# K8S tests start here #
########################

function cleanup() {
    kubectl delete svc nginx || true
}
trap cleanup EXIT

# Sanity check
kubectl get nodes

# Check if any pods aren't in state "Running"
function check_all_pods_running() {
    NONRUNNING_PODS=$(kubectl get pods \
        --all-namespaces \
        -o template \
        --template='{{range .items}}{{if ne .status.phase "Running"}}{{.metadata.name}} {{.status.phase}}{{"\n"}}{{end}}{{end}}'
    )
    test -z "${NONRUNNING_PODS}"
    return 0
}
try_n_times 60 check_all_pods_running

# Deploy a service
kubectl run nginx --image=nginx --port=80
kubectl expose deployment nginx --type=LoadBalancer --port 80

GET_LB_CMD="kubectl get svc -o template --template='{{range .status.loadBalancer.ingress}}{{.hostname}}{{end}}' nginx"
try_n_times 30 "$GET_LB_CMD | grep -q '.'"
LB_ADDR=$(eval "${GET_LB_CMD}")

# Wait for DNS propagation, up to 10mins
try_n_times 600 "host ${LB_ADDR}"

# Fetch the service
curl -s -L -f http://${LB_ADDR}
