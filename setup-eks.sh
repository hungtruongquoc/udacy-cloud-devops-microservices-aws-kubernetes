#!/bin/bash

echo "Creating EKS networking stack..."
aws cloudformation create-stack \
  --stack-name eks-subnets \
  --template-body file://infrastructure/cloudformation/nested/subnets.yaml \
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

echo "Creating EKS cluster stack..."
aws cloudformation create-stack \
  --stack-name eks-cluster \
  --template-body file://infrastructure/cloudformation/nested/eks.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VpcId,ParameterValue=vpc-7aa76207 \
    ParameterKey=PrivateSubnet1,ParameterValue=$PRIVATE_SUBNET_1 \
    ParameterKey=PrivateSubnet2,ParameterValue=$PRIVATE_SUBNET_2

echo "Waiting for EKS cluster stack to complete..."
aws cloudformation wait stack-create-complete --stack-name eks-cluster

echo "Updating kubeconfig..."
aws eks --region us-east-1 update-kubeconfig --name dev-eks-cluster

echo "Verifying cluster access..."
kubectl get nodes

echo "Setup complete!"