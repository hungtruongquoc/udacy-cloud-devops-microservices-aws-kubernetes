#!/bin/bash

# Parameterize stack names
CLUSTER_STACK="eks-cluster"
NETWORK_STACK="eks-subnets"

# Start timing
start_time=$(date +%s)

echo "Starting teardown process at $(date)"
echo "-----------------------------------"

verify_deletion() {
    local resource=$1
    local check_command=$2
    local max_attempts=30
    local attempt=1

    echo "Verifying deletion of $resource..."
    while eval "$check_command" &>/dev/null; do
        if [ $attempt -ge $max_attempts ]; then
            echo "❌ Failed to verify deletion of $resource after $max_attempts attempts"
            return 1
        fi
        echo "Waiting for $resource to be deleted... (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done
    echo "✅ $resource deleted successfully"
    return 0
}

cleanup_ebs_csi_policy() {
    local ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    local POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSEBSCSIDriverPolicy"

    echo "Starting EBS CSI policy cleanup..."

    # Wait for any potential service account deletions to complete
    echo "Waiting for service account stack deletion..."
    aws cloudformation wait stack-delete-complete \
        --stack-name eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa || true

    # List all policy versions and delete non-default versions
    echo "Cleaning up policy versions..."
    local VERSIONS=$(aws iam list-policy-versions \
        --policy-arn $POLICY_ARN \
        --query 'Versions[?!IsDefaultVersion].VersionId' \
        --output text)

    for version in $VERSIONS; do
        echo "Deleting policy version: $version"
        aws iam delete-policy-version \
            --policy-arn $POLICY_ARN \
            --version-id $version || true
    done

    # Force deletion with retries
    echo "Attempting to delete policy..."
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if aws iam delete-policy --policy-arn $POLICY_ARN 2>/dev/null; then
            echo "✅ Successfully deleted EBS CSI Driver policy"
            return 0
        else
            echo "Attempt $attempt of $max_attempts failed. Waiting before retry..."
            sleep 10
            ((attempt++))
        fi
    done

    echo "❌ Failed to delete EBS CSI Driver policy after $max_attempts attempts"
    return 1
}

echo "Checking if cluster is active..."
if kubectl cluster-info &>/dev/null; then
    echo "Cluster is active. Proceeding with Kubernetes resource deletion..."

    # Delete storage class first
    echo "Removing storage class..."
    kubectl delete sc gp2 || true

    # Delete all Helm releases
    echo "Removing Helm releases..."
    helm list --all-namespaces | tail -n +2 | awk '{print $1}' | xargs -I {} helm uninstall {} || true

    # Delete services first to remove load balancers
    echo "Deleting services..."
    kubectl delete svc --all --all-namespaces || true
    kubectl wait --for=delete svc --all --all-namespaces --timeout=300s || true

    # Delete other resources in parallel
    echo "Deleting deployments, configmaps, secrets, PVCs, and PVs..."
    kubectl delete deployment --all --all-namespaces &
    kubectl delete configmap --all --all-namespaces &
    kubectl delete secret --all --all-namespaces &
    kubectl delete pvc --all --all-namespaces &
    kubectl delete pv --all --all-namespaces &
    wait
else
    echo "Cluster is not accessible or doesn't exist. Proceeding with infrastructure cleanup..."
fi

# Delete IAM service accounts and policies
echo "Cleaning up IAM resources..."
eksctl delete iamserviceaccount \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --cluster dev-eks-cluster \
    --region us-east-1 || true

verify_deletion "IAM service account" \
    "kubectl get serviceaccount -n kube-system ebs-csi-controller-sa"

# Delete EBS CSI Driver policy
echo "Cleaning up EBS CSI Driver policy..."
cleanup_ebs_csi_policy

# Delete OIDC provider
echo "Cleaning up OIDC provider..."
OIDC_PROVIDER=$(aws eks describe-cluster --name dev-eks-cluster --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///' || echo "")
if [ ! -z "$OIDC_PROVIDER" ]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$OIDC_PROVIDER" || true
    verify_deletion "OIDC provider" \
        "aws iam list-open-id-connect-providers | grep $OIDC_PROVIDER"
fi

k8s_cleanup_time=$(date +%s)
echo "Kubernetes cleanup completed in $((k8s_cleanup_time - start_time)) seconds"
echo "-----------------------------------"

echo "Deleting EKS cluster stack..."
aws cloudformation delete-stack --stack-name $CLUSTER_STACK

echo "Waiting for EKS cluster stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name $CLUSTER_STACK; then
    echo "❌ Failed to delete EKS cluster stack"
    exit 1
fi
verify_deletion "EKS cluster stack" \
    "aws cloudformation describe-stacks --stack-name $CLUSTER_STACK"

eks_delete_time=$(date +%s)
echo "EKS cluster deletion completed in $((eks_delete_time - k8s_cleanup_time)) seconds"
echo "-----------------------------------"

echo "Deleting networking stack..."
aws cloudformation delete-stack --stack-name $NETWORK_STACK

echo "Waiting for networking stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name $NETWORK_STACK; then
    echo "❌ Failed to delete networking stack"
    exit 1
fi
verify_deletion "Networking stack" \
    "aws cloudformation describe-stacks --stack-name $NETWORK_STACK"

network_delete_time=$(date +%s)
echo "Networking stack deletion completed in $((network_delete_time - eks_delete_time)) seconds"
echo "-----------------------------------"

# Clean up kubeconfig
echo "Cleaning up kubeconfig..."
if kubectl config current-context &>/dev/null; then
    kubectl config unset current-context
fi

if kubectl config get-contexts dev-eks-cluster &>/dev/null; then
    kubectl config delete-context dev-eks-cluster
fi

if kubectl config get-clusters | grep dev-eks-cluster &>/dev/null; then
    kubectl config delete-cluster dev-eks-cluster
fi

echo "Deleting ECR repository..."
# Delete all images in the repository first
aws ecr list-images \
    --repository-name dev-application \
    --query 'imageIds[*]' \
    --output json | \
    jq -r '.[] | [.imageDigest] | @tsv' | \
    while IFS=$'\t' read -r imageDigest; do
        aws ecr batch-delete-image \
            --repository-name dev-application \
            --image-ids imageDigest=$imageDigest
    done || true

# Delete the repository
aws ecr delete-repository \
    --repository-name dev-application \
    --force || true

verify_deletion "ECR repository" \
    "aws ecr describe-repositories --repository-names dev-application"

ecr_delete_time=$(date +%s)
echo "ECR repository deletion completed in $((ecr_delete_time - network_delete_time)) seconds"
echo "-----------------------------------"

end_time=$(date +%s)
echo "-----------------------------------"
echo "Teardown completed at $(date)"
echo "Total teardown time: $((end_time - start_time)) seconds"
echo "Breakdown:"
echo "  Kubernetes cleanup: $((k8s_cleanup_time - start_time)) seconds"
echo "  EKS cluster deletion: $((eks_delete_time - k8s_cleanup_time)) seconds"
echo "  Networking deletion: $((network_delete_time - eks_delete_time)) seconds"
echo "  ECR cleanup: $((ecr_delete_time - network_delete_time)) seconds"
echo "  Final cleanup: $((end_time - ecr_delete_time)) seconds"