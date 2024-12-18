#!/bin/bash

# Start timing
start_time=$(date +%s)

echo "Starting setup process at $(date)"
echo "-----------------------------------"

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

ecr_time=$(date +%s)
echo "ECR repository setup completed in $((ecr_time - start_time)) seconds"
echo "ECR Repository URI: $ECR_REPO_URI"
echo "-----------------------------------"

echo "Creating EKS networking stack..."
aws cloudformation create-stack \
  --stack-name eks-subnets \
  --template-body file://deployment/cloudformation/resources/networking.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VpcId,ParameterValue=vpc-7aa76207

echo "Waiting for networking stack to complete..."
aws cloudformation wait stack-create-complete --stack-name eks-subnets

# Get subnet IDs from the networking stack outputs
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

eks_time=$(date +%s)
echo "EKS cluster stack completed in $((eks_time - networking_time)) seconds"
echo "-----------------------------------"

echo "Updating kubeconfig..."
aws eks --region us-east-1 update-kubeconfig --name dev-eks-cluster

echo "Verifying cluster access..."
kubectl get nodes

end_time=$(date +%s)
echo "-----------------------------------"
echo "Setup completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"
echo "Breakdown:"
echo "  ECR repository: $((ecr_time - eks_time)) seconds"
echo "  Networking stack: $((networking_time - start_time)) seconds"
echo "  EKS cluster stack: $((eks_time - networking_time)) seconds"
echo "  Final configuration: $((end_time - eks_time)) seconds"