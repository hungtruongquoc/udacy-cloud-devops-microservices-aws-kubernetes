#!/bin/bash

# Parameterize stack names
CLUSTER_STACK="eks-cluster"
NETWORK_STACK="eks-subnets"
CODEBUILD_STACK="codebuild-stack"
IAM_POLICIES_STACK="iam-policies-ebs-csi-driver"

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

# Delete CodeBuild stack
echo "Deleting CodeBuild stack..."
aws cloudformation delete-stack --stack-name $CODEBUILD_STACK

echo "Waiting for CodeBuild stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name $CODEBUILD_STACK; then
    echo "❌ Failed to delete CodeBuild stack"
    exit 1
fi
verify_deletion "CodeBuild stack" \
    "aws cloudformation describe-stacks --stack-name $CODEBUILD_STACK"

codebuild_delete_time=$(date +%s)
echo "CodeBuild stack deletion completed in $((codebuild_delete_time - start_time)) seconds"
echo "-----------------------------------"

# Delete IAM service accounts and policies
echo "Cleaning up IAM resources..."
eksctl delete iamserviceaccount \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --cluster dev-eks-cluster \
    --region us-east-1 || true

verify_deletion "IAM service account" \
    "kubectl get serviceaccount -n kube-system ebs-csi-controller-sa"

# Delete IAM policies stack
echo "Deleting IAM policies stack..."
aws cloudformation delete-stack --stack-name $IAM_POLICIES_STACK

echo "Waiting for IAM policies stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name $IAM_POLICIES_STACK; then
    echo "❌ Failed to delete IAM policies stack"
    exit 1
fi
verify_deletion "IAM policies stack" \
    "aws cloudformation describe-stacks --stack-name $IAM_POLICIES_STACK"

iam_delete_time=$(date +%s)
echo "IAM resources cleanup completed in $((iam_delete_time - codebuild_delete_time)) seconds"
echo "-----------------------------------"

# Delete OIDC provider
echo "Cleaning up OIDC provider..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get OIDC provider URL from cluster
OIDC_PROVIDER=$(aws eks describe-cluster \
    --name dev-eks-cluster \
    --query "cluster.identity.oidc.issuer" \
    --output text 2>/dev/null | sed 's|https://||')

if [ ! -z "$OIDC_PROVIDER" ]; then
    echo "Found OIDC provider: $OIDC_PROVIDER"
    OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

    # Check if the OIDC provider exists
    if aws iam list-open-id-connect-providers | grep -q "$OIDC_ARN"; then
        echo "Deleting OIDC provider: $OIDC_ARN"
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"

        # Verify deletion without using the verify_deletion function
        echo "Verifying OIDC provider deletion..."
        timeout=300  # 5 minutes timeout
        start_time=$(date +%s)

        while aws iam list-open-id-connect-providers | grep -q "$OIDC_ARN"; do
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))

            if [ $elapsed -gt $timeout ]; then
                echo "❌ Timeout waiting for OIDC provider deletion"
                break
            fi

            echo "Waiting for OIDC provider deletion... (${elapsed}s elapsed)"
            sleep 10
        done

        if ! aws iam list-open-id-connect-providers | grep -q "$OIDC_ARN"; then
            echo "✅ OIDC provider deleted successfully"
        fi
    else
        echo "OIDC provider not found or already deleted"
    fi
else
    echo "No OIDC provider found for cluster"
fi

k8s_cleanup_time=$(date +%s)
echo "Kubernetes cleanup completed in $((k8s_cleanup_time - iam_delete_time)) seconds"
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
echo "  CodeBuild stack deletion: $((codebuild_delete_time - start_time)) seconds"
echo "  IAM resources cleanup: $((iam_delete_time - codebuild_delete_time)) seconds"
echo "  Kubernetes cleanup: $((k8s_cleanup_time - iam_delete_time)) seconds"
echo "  EKS cluster deletion: $((eks_delete_time - k8s_cleanup_time)) seconds"
echo "  Networking deletion: $((network_delete_time - eks_delete_time)) seconds"
echo "  ECR cleanup: $((ecr_delete_time - network_delete_time)) seconds"
echo "  Final cleanup: $((end_time - ecr_delete_time)) seconds"