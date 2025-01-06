#!/bin/bash

# Configuration
AWS_REGION=$(aws configure get region)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY="dev-application"  # Your ECR repository name
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
IMAGE_TAG="$TIMESTAMP"          # Unique timestamp-based tag

# Allow specifying Docker context directory as an argument, default to current directory
DOCKER_CONTEXT_DIR=${1:-.}

# Validate that Dockerfile exists in the specified directory
if [ ! -f "$DOCKER_CONTEXT_DIR/Dockerfile" ]; then
    echo "Error: Dockerfile not found in $DOCKER_CONTEXT_DIR"
    exit 1
fi

# Error handling
set -e

echo "Starting Docker build and push process..."

# Get AWS ECR login token and authenticate Docker
echo "Authenticating with Amazon ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build the Docker image
echo "Building Docker image..."
docker build -t $ECR_REPOSITORY:$IMAGE_TAG $DOCKER_CONTEXT_DIR

# Tag the image for ECR
echo "Tagging image for ECR..."
docker tag $ECR_REPOSITORY:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG
docker tag $ECR_REPOSITORY:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:latest

# Push the image to ECR with both tags
echo "Pushing image to ECR..."
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:latest
echo "Pushing image to ECR..."
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG

echo "Process completed successfully!"