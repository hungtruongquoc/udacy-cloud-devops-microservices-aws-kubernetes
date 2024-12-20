#!/bin/bash

set -e  # Exit on error

# Start timing
start_time=$(date +%s)

echo "Starting EBS CSI Driver setup process at $(date)"
echo "-----------------------------------"

# Update kubeconfig first
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name dev-eks-cluster --region us-east-1

# Delete existing addon if it exists
echo "Checking for existing EBS CSI Driver addon..."
if aws eks describe-addon --cluster-name dev-eks-cluster --addon-name aws-ebs-csi-driver --region us-east-1 2>/dev/null; then
    echo "Deleting existing add-on..."
    aws eks delete-addon \
        --cluster-name dev-eks-cluster \
        --addon-name aws-ebs-csi-driver \
        --region us-east-1

    echo "Waiting for add-on deletion to complete..."
    aws eks wait addon-deleted \
        --cluster-name dev-eks-cluster \
        --addon-name aws-ebs-csi-driver \
        --region us-east-1 || true
fi

# Clean up existing service accounts
echo "Cleaning up existing service accounts..."
kubectl delete serviceaccount -n kube-system ebs-csi-controller-sa --force --grace-period=0 || true

# Delete the CloudFormation stack manually
echo "Cleaning up CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa || true

echo "Waiting for CloudFormation stack deletion..."
aws cloudformation wait stack-delete-complete \
    --stack-name eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa || true

# Wait for cleanup
echo "Waiting for resources to clean up..."
sleep 30

# Create new IAM role and service account
echo "Creating new service account..."
eksctl create iamserviceaccount \
    --cluster dev-eks-cluster \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --region us-east-1 \
    --override-existing-serviceaccounts \
    --approve

# Wait for service account creation
echo "Waiting for service account creation..."
sleep 30

# Verify service account
echo "Verifying service account..."
kubectl get serviceaccount ebs-csi-controller-sa -n kube-system -o yaml

# Get the role ARN
EBS_CSI_ROLE_ARN=$(kubectl get serviceaccount ebs-csi-controller-sa -n kube-system \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')

if [ -z "$EBS_CSI_ROLE_ARN" ]; then
    echo "Failed to get role ARN"
    exit 1
fi

echo "Retrieved Role ARN: $EBS_CSI_ROLE_ARN"

# Install EBS CSI Driver add-on
echo "Installing EBS CSI Driver..."
aws eks create-addon \
    --cluster-name dev-eks-cluster \
    --addon-name aws-ebs-csi-driver \
    --addon-version v1.37.0-eksbuild.1 \
    --service-account-role-arn "$EBS_CSI_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --region us-east-1

echo "Waiting for add-on to become active..."
aws eks wait addon-active \
    --cluster-name dev-eks-cluster \
    --addon-name aws-ebs-csi-driver \
    --region us-east-1

# Final verification
echo "Final verification..."
aws eks describe-addon \
    --cluster-name dev-eks-cluster \
    --addon-name aws-ebs-csi-driver \
    --region us-east-1

# Check for running pods
echo "Checking for EBS CSI Driver pods..."
kubectl get pods -n kube-system | grep ebs-csi

end_time=$(date +%s)
echo "-----------------------------------"
echo "Setup completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"