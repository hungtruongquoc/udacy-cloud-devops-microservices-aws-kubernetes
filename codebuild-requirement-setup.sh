#!/bin/bash
set -e

# Variables
STACK_NAME="codebuild-requirements-stack"
TEMPLATE_FILE="deployment/cloudformation/resources/codebuild-requirements.yaml"

# Deploy One-Time Resources
aws cloudformation create-stack \
  --stack-name "$STACK_NAME" \
  --template-body file://"$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM

echo "Waiting for stack creation to complete..."
aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME"

echo "CodeBuild required components created successfully."