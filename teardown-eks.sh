#!/bin/bash

# Parameterize stack names
CLUSTER_STACK="eks-cluster"
NETWORK_STACK="eks-subnets"

# Start timing
start_time=$(date +%s)

echo "Starting teardown process at $(date)"
echo "-----------------------------------"

echo "Checking if cluster is active..."
if kubectl cluster-info &>/dev/null; then
    echo "Cluster is active. Proceeding with Kubernetes resource deletion..."
    # Delete services first to remove load balancers
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

echo "Cleaning up Kubernetes resources..."
# Delete services first to remove load balancers
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

k8s_cleanup_time=$(date +%s)
echo "Kubernetes cleanup completed in $((k8s_cleanup_time - start_time)) seconds"
echo "-----------------------------------"

echo "Deleting EKS cluster stack..."
aws cloudformation delete-stack --stack-name $CLUSTER_STACK

echo "Waiting for EKS cluster stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name $CLUSTER_STACK || {
    echo "Failed to delete EKS cluster stack"
    exit 1
}

eks_delete_time=$(date +%s)
echo "EKS cluster deletion completed in $((eks_delete_time - k8s_cleanup_time)) seconds"
echo "-----------------------------------"

echo "Deleting networking stack..."
aws cloudformation delete-stack --stack-name $NETWORK_STACK

echo "Waiting for networking stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name $NETWORK_STACK || {
    echo "Failed to delete networking stack"
    exit 1
}

network_delete_time=$(date +%s)
echo "Networking stack deletion completed in $((network_delete_time - eks_delete_time)) seconds"
echo "-----------------------------------"

# Clean up kubeconfig more gracefully
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

ecr_delete_time=$(date +%s)
echo "ECR repository deletion completed in $((ecr_delete_time - k8s_cleanup_time)) seconds"
echo "-----------------------------------"

end_time=$(date +%s)
echo "-----------------------------------"
echo "Teardown completed at $(date)"
echo "Total teardown time: $((end_time - start_time)) seconds"
echo "Breakdown:"
echo "  ECR repository deletion: $((ecr_delete_time - k8s_cleanup_time)) seconds"
echo "  Kubernetes cleanup: $((k8s_cleanup_time - start_time)) seconds"
echo "  EKS cluster deletion: $((eks_delete_time - k8s_cleanup_time)) seconds"
echo "  Networking deletion: $((network_delete_time - eks_delete_time)) seconds"
echo "  Final cleanup: $((end_time - network_delete_time)) seconds"