#!/bin/bash

echo "Starting teardown process..."

#echo "Cleaning up Kubernetes resources..."
# Delete services first to remove load balancers
#kubectl delete svc --all --all-namespaces
#echo "Waiting for services to be deleted..."
#sleep 30  # Give time for load balancers to be removed

# Delete other resources
#kubectl delete deployment --all --all-namespaces
#kubectl delete configmap --all --all-namespaces
#kubectl delete secret --all --all-namespaces
#kubectl delete pvc --all --all-namespaces
#kubectl delete pv --all --all-namespaces

echo "Deleting EKS cluster stack..."
aws cloudformation delete-stack --stack-name eks-cluster

echo "Waiting for EKS cluster stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name eks-cluster

echo "Deleting networking stack..."
aws cloudformation delete-stack --stack-name eks-subnets

echo "Waiting for networking stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name eks-subnets

echo "Cleanup complete!"

# Clean up kubeconfig
echo "Cleaning up kubeconfig..."
kubectl config unset current-context
kubectl config delete-context dev-eks-cluster
kubectl config delete-cluster dev-eks-cluster