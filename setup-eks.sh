#!/bin/bash

# Start timing
start_time=$(date +%s)

echo "Starting setup process at $(date)"
echo "-----------------------------------"

verify_component() {
    local component=$1
    local check_command=$2
    local error_message=$3

    echo "Verifying $component..."
    if eval "$check_command"; then
        echo "✅ $component verification successful"
        return 0
    else
        echo "❌ $component verification failed: $error_message"
        return 1
    fi
}

# Create ECR repository
echo "Creating ECR repository..."
aws ecr create-repository \
    --repository-name dev-application \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region us-east-1 || true

# Get the repository URI for later use
ECR_REPO_URI=$(aws ecr describe-repositories \
    --repository-names dev-application \
    --query 'repositories[0].repositoryUri' \
    --output text)

verify_component "ECR Repository" \
    "aws ecr describe-repositories --repository-names dev-application" \
    "ECR repository creation failed"

ecr_time=$(date +%s)
echo "ECR repository setup completed in $((ecr_time - start_time)) seconds"
echo "ECR Repository URI: $ECR_REPO_URI"
echo "-----------------------------------"

# Create CodeBuild stack
echo "Creating CodeBuild stack..."
aws cloudformation create-stack \
  --stack-name codebuild-stack \
  --template-body file://deployment/cloudformation/resources/codebuild.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=GitHubRepo,ParameterValue=https://github.com/hungtruongquoc/udacy-cloud-devops-microservices-aws-kubernetes.git \
    ParameterKey=GitHubBranch,ParameterValue=main \
    ParameterKey=ECRRepositoryURI,ParameterValue=$ECR_REPO_URI \
    ParameterKey=ArtifactsBucket,ParameterValue=2024-udacity-devops-htruong-artifacts-bucket \
    ParameterKey=CodeBuildRoleArn,ParameterValue=codebuild-requirements-stack-CodeBuildRole-wOF9xKYaqUU1 \
    ParameterKey=GitHubAccessTokenSecretName,ParameterValue=GitHubAccessToken

verify_component "CodeBuild Stack" \
    "aws cloudformation wait stack-create-complete --stack-name codebuild-stack" \
    "CodeBuild stack creation failed"

codebuild_time=$(date +%s)
echo "CodeBuild setup completed in $((codebuild_time - ecr_time)) seconds"
echo "-----------------------------------"

# Create networking stack
echo "Creating EKS networking stack..."
aws cloudformation create-stack \
  --stack-name eks-subnets \
  --template-body file://deployment/cloudformation/resources/networking.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VpcId,ParameterValue=vpc-7aa76207

verify_component "Networking Stack" \
    "aws cloudformation wait stack-create-complete --stack-name eks-subnets" \
    "Networking stack creation failed"

# Get subnet IDs
PRIVATE_SUBNET_1=$(aws cloudformation describe-stacks \
  --stack-name eks-subnets \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet1Id`].OutputValue' \
  --output text)

PRIVATE_SUBNET_2=$(aws cloudformation describe-stacks \
  --stack-name eks-subnets \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnet2Id`].OutputValue' \
  --output text)

networking_time=$(date +%s)
echo "Networking stack completed in $((networking_time - codebuild_time)) seconds"
echo "-----------------------------------"

# Create EKS cluster
echo "Creating EKS cluster stack..."
aws cloudformation create-stack \
  --stack-name eks-cluster \
  --template-body file://deployment/cloudformation/resources/eks.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VpcId,ParameterValue=vpc-7aa76207 \
    ParameterKey=PrivateSubnet1,ParameterValue=$PRIVATE_SUBNET_1 \
    ParameterKey=PrivateSubnet2,ParameterValue=$PRIVATE_SUBNET_2

verify_component "EKS Cluster Stack" \
    "aws cloudformation wait stack-create-complete --stack-name eks-cluster" \
    "EKS cluster stack creation failed"

eks_time=$(date +%s)
echo "EKS cluster stack completed in $((eks_time - networking_time)) seconds"
echo "-----------------------------------"

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name dev-eks-cluster --region us-east-1

# Setup OIDC provider
echo "Setting up OIDC provider..."
eksctl utils associate-iam-oidc-provider \
    --cluster dev-eks-cluster \
    --approve \
    --region us-east-1

oidc_time=$(date +%s)
echo "OIDC provider setup completed in $((oidc_time - eks_time)) seconds"
echo "-----------------------------------"

# Install EBS CSI Driver using EKS add-on
echo "Installing EBS CSI Driver add-on..."

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

# Create new service account
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

# Wait for add-on to be active
verify_component "EBS CSI Driver Add-on" \
    "aws eks wait addon-active --cluster-name dev-eks-cluster --addon-name aws-ebs-csi-driver --region us-east-1" \
    "EBS CSI Driver add-on installation failed"

ebs_csi_time=$(date +%s)
echo "EBS CSI Driver setup completed in $((ebs_csi_time - oidc_time)) seconds"
echo "-----------------------------------"

# Verify cluster access and node status
echo "Verifying cluster access and node status..."
verify_component "Cluster Nodes" \
    "kubectl wait --for=condition=Ready nodes --all --timeout=300s" \
    "No ready nodes found in the cluster"

end_time=$(date +%s)
echo "-----------------------------------"
echo "Setup completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"
echo "Breakdown:"
echo "  ECR repository: $((ecr_time - start_time)) seconds"
echo "  CodeBuild stack: $((codebuild_time - ecr_time)) seconds"
echo "  Networking stack: $((networking_time - codebuild_time)) seconds"
echo "  EKS cluster stack: $((eks_time - networking_time)) seconds"
echo "  OIDC provider: $((oidc_time - eks_time)) seconds"
echo "  EBS CSI Driver: $((ebs_csi_time - oidc_time)) seconds"
echo "  Final configuration: $((end_time - ebs_csi_time)) seconds"