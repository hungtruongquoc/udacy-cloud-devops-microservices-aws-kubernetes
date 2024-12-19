#!/bin/bash

echo "Starting EKS Resource Verification at $(date)"
echo "-----------------------------------"

# Check EKS Cluster
echo "Checking EKS Cluster..."
if aws eks describe-cluster --name dev-eks-cluster &>/dev/null; then
    echo "✅ EKS cluster 'dev-eks-cluster' exists and is accessible"
    CLUSTER_STATUS=$(aws eks describe-cluster --name dev-eks-cluster --query 'cluster.status' --output text)
    echo "   Status: $CLUSTER_STATUS"
else
    echo "❌ EKS cluster not found or not accessible"
    exit 1
fi

# Check OIDC Provider
echo "Checking OIDC Provider..."
OIDC_ID=$(aws eks describe-cluster --name dev-eks-cluster \
    --query "cluster.identity.oidc.issuer" \
    --output text | cut -d '/' -f 5)
if aws iam list-open-id-connect-providers | grep -q $OIDC_ID; then
    echo "✅ OIDC provider exists"
    echo "   Provider ID: $OIDC_ID"
else
    echo "❌ OIDC provider not found"
    exit 1
fi

# Check EBS CSI Driver Policy
echo "Checking EBS CSI Driver Policy..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSEBSCSIDriverPolicy &>/dev/null; then
    echo "✅ EBS CSI Driver policy exists"
else
    echo "❌ EBS CSI Driver policy not found"
    exit 1
fi

# Check IAM Service Account
echo "Checking IAM Service Account..."
if kubectl get serviceaccount ebs-csi-controller-sa -n kube-system &>/dev/null; then
    echo "✅ EBS CSI Controller service account exists"
    echo "   Annotations:"
    kubectl get serviceaccount ebs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations}' | jq .
else
    echo "❌ EBS CSI Controller service account not found"
    exit 1
fi

# Check Nodes
echo "Checking Worker Nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
    echo "✅ Found $NODE_COUNT worker nodes"
    kubectl get nodes -o wide
else
    echo "❌ No worker nodes found"
    exit 1
fi

# Check default storage class
echo "Checking Storage Class..."
if kubectl get sc gp2 &>/dev/null; then
    echo "✅ gp2 storage class exists"
    kubectl get sc gp2 -o yaml
else
    echo "❌ gp2 storage class not found"
    # Create storage class if missing
    echo "Creating gp2 storage class..."
    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
provisioner: ebs.csi.aws.com
parameters:
  type: gp2
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
EOF
fi

# Check if EBS CSI Driver is installed and running
echo "Checking EBS CSI Driver pods..."
if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver &>/dev/null; then
    echo "✅ EBS CSI Driver pods exist"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
else
    echo "❌ EBS CSI Driver pods not found"
    exit 1
fi

echo "-----------------------------------"
echo "Verification completed at $(date)"