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

# After ECR setup and before EKS cluster creation
echo "Creating CodeBuild stack..."
aws cloudformation create-stack \
  --stack-name codebuild-stack \
  --template-body file://deployment/cloudformation/resources/codebuild.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=GitHubRepo,ParameterValue=https://github.com/YOUR_USERNAME/YOUR_REPO.git \
    ParameterKey=GitHubBranch,ParameterValue=main \
    ParameterKey=ECRRepositoryURI,ParameterValue=$ECR_REPO_URI

echo "Waiting for CodeBuild stack to complete..."
aws cloudformation wait stack-create-complete --stack-name codebuild-stack

verify_component "CodeBuild Stack" \
    "aws cloudformation describe-stacks --stack-name codebuild-stack --query 'Stacks[0].StackStatus' --output text | grep -q 'COMPLETE'" \
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

echo "Waiting for networking stack to complete..."
aws cloudformation wait stack-create-complete --stack-name eks-subnets

verify_component "Networking Stack" \
    "aws cloudformation describe-stacks --stack-name eks-subnets --query 'Stacks[0].StackStatus' --output text | grep -q 'COMPLETE'" \
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
echo "Networking stack completed in $((networking_time - ecr_time)) seconds"
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

echo "Waiting for EKS cluster stack to complete..."
aws cloudformation wait stack-create-complete --stack-name eks-cluster

verify_component "EKS Cluster Stack" \
    "aws cloudformation describe-stacks --stack-name eks-cluster --query 'Stacks[0].StackStatus' --output text | grep -q 'COMPLETE'" \
    "EKS cluster stack creation failed"

eks_time=$(date +%s)
echo "EKS cluster stack completed in $((eks_time - networking_time)) seconds"
echo "-----------------------------------"

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks --region us-east-1 update-kubeconfig --name dev-eks-cluster

# Setup OIDC provider
echo "Setting up OIDC provider..."
eksctl utils associate-iam-oidc-provider \
    --cluster dev-eks-cluster \
    --approve \
    --region us-east-1

verify_component "OIDC Provider" \
    "OIDC_ID=\$(aws eks describe-cluster --name dev-eks-cluster --query 'cluster.identity.oidc.issuer' --output text | cut -d '/' -f 5) && aws iam list-open-id-connect-providers | grep -q \$OIDC_ID" \
    "OIDC provider setup failed"

# Create EBS CSI Driver policy
# Create EBS CSI Driver policy using CloudFormation
echo "Creating EBS CSI Driver policy..."
aws cloudformation create-stack \
  --stack-name iam-policies \
  --template-body deployment/cloudformation/resources/iam-policy-ebs-csi-driver.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev

echo "Waiting for IAM policies stack to complete..."
aws cloudformation wait stack-create-complete --stack-name iam-policies

verify_component "EBS CSI Driver Policy" \
    "aws cloudformation describe-stacks --stack-name iam-policies --query 'Stacks[0].StackStatus' --output text | grep -q 'COMPLETE'" \
    "EBS CSI Driver policy creation failed"

# Get the policy ARN for service account creation
EBS_POLICY_ARN=$(aws cloudformation describe-stacks \
  --stack-name iam-policies \
  --query 'Stacks[0].Outputs[?OutputKey==`EBSCSIDriverPolicyArn`].OutputValue' \
  --output text)

# Create service account for EBS CSI Driver
echo "Creating service account for EBS CSI Driver..."
eksctl create iamserviceaccount \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --cluster dev-eks-cluster \
    --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSEBSCSIDriverPolicy \
    --approve \
    --region us-east-1

verify_component "Service Account" \
    "kubectl get serviceaccount ebs-csi-controller-sa -n kube-system" \
    "Service account creation failed"

# Setup storage class for EBS volumes
echo "Creating storage class for EBS volumes..."
kubectl delete sc gp2 --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: gp2
provisioner: ebs.csi.aws.com
parameters:
  type: gp2
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
EOF

verify_component "Storage Class" \
    "kubectl get sc gp2 -o jsonpath='{.provisioner}' | grep -q 'ebs.csi.aws.com'" \
    "Storage class creation failed or has incorrect provisioner"

# Test PVC creation
echo "Testing PVC creation..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp2
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for PVC to be created
echo "Waiting for PVC to be created..."
sleep 10
verify_component "PVC Creation" \
    "kubectl get pvc test-pvc" \
    "PVC creation failed"

# Clean up test PVC
kubectl delete pvc test-pvc --ignore-not-found

# Verify cluster access and node status
echo "Verifying cluster access and node status..."
verify_component "Cluster Nodes" \
    "kubectl get nodes | grep -q 'Ready'" \
    "No ready nodes found in the cluster"

end_time=$(date +%s)
echo "-----------------------------------"
echo "Setup completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"
echo "Breakdown:"
echo "  ECR repository: $((ecr_time - start_time)) seconds"
echo "  Networking stack: $((networking_time - ecr_time)) seconds"
echo "  EKS cluster stack: $((eks_time - networking_time)) seconds"
echo "  Final configuration: $((end_time - eks_time)) seconds"