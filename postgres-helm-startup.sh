#!/bin/bash

echo "Starting PostgreSQL setup with Helm at $(date)"
echo "-----------------------------------"

# Start timing
start_time=$(date +%s)

# First verify OIDC and EBS CSI Driver setup
echo "Verifying prerequisites..."

# Check OIDC provider
echo "Checking OIDC provider..."
OIDC_PROVIDER=$(aws eks describe-cluster --name dev-eks-cluster \
    --query 'cluster.identity.oidc.issuer' \
    --output text | sed 's|https://||')
if ! aws iam list-open-id-connect-providers | grep -q $(echo $OIDC_PROVIDER | awk -F/ '{print $NF}'); then
    echo "❌ OIDC provider not found. Please run the EKS setup script first."
    exit 1
fi

# Verify the IAM role exists and is properly configured
echo "Verifying IAM role and service account..."
# Get the role ARN from eksctl
ROLE_ARN=$(eksctl get iamserviceaccount \
    --cluster dev-eks-cluster \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    -o json | jq -r '.[].status.roleARN')

if [ -z "$ROLE_ARN" ]; then
    echo "❌ EBS CSI Driver IAM role not found. Please run the EKS setup script first."
    exit 1
fi

SA_NAME="ebs-csi-controller-sa"

# Delete old service account if it exists
kubectl delete serviceaccount -n kube-system $SA_NAME 2>/dev/null || true

# Create service account and associate with existing role
kubectl create serviceaccount -n kube-system $SA_NAME
kubectl annotate serviceaccount -n kube-system $SA_NAME \
    eks.amazonaws.com/role-arn=$ROLE_ARN --overwrite

# Explicitly enable automount for service account tokens
echo "Enabling automount of service account tokens..."
kubectl patch serviceaccount $SA_NAME -n kube-system \
    -p '{"automountServiceAccountToken": true}'

# Verify and install EBS CSI Driver
echo "Verifying EBS CSI Driver..."
if ! helm list -n kube-system | grep -q "aws-ebs-csi-driver"; then
    echo "Installing EBS CSI Driver..."
    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
    helm repo update

    helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
        --namespace kube-system \
        --set controller.serviceAccount.create=false \
        --set controller.serviceAccount.name=$SA_NAME

    # Wait for EBS CSI Driver pods to be ready
    echo "Waiting for EBS CSI Driver pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-ebs-csi-driver -n kube-system --timeout=300s
else
    echo "EBS CSI Driver already installed"
fi

# Verify storage class
echo "Verifying gp2 storage class..."
if ! kubectl get sc gp2 &>/dev/null; then
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

ebs_install_time=$(date +%s)
echo "EBS setup completed in $((ebs_install_time - start_time)) seconds"
echo "-----------------------------------"

# Cleanup any existing installation
echo "Cleaning up any existing PostgreSQL installation..."
helm uninstall postgresql || true
kubectl delete pvc data-postgresql-0 --force --grace-period=0 || true
sleep 10  # Wait for cleanup

# Get the AZ of the first node
NODE_AZ=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}')
echo "Using availability zone: $NODE_AZ"

# Add Bitnami repo if not already added
if ! helm repo list | grep -q "bitnami"; then
    echo "Adding Bitnami Helm repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
fi

# Update repos
echo "Updating Helm repositories..."
helm repo update

# Set up PostgreSQL configuration
DB_NAME="mydatabase"
DB_USER="myuser"
DB_PASSWORD="mypassword"

echo "Installing PostgreSQL with Helm..."
helm install postgresql bitnami/postgresql \
  --set auth.username=$DB_USER \
  --set auth.password=$DB_PASSWORD \
  --set auth.database=$DB_NAME \
  --set primary.persistence.size=1Gi \
  --set primary.persistence.storageClass=gp2 \
  --set volumePermissions.enabled=true \
  --set primary.nodeSelector."topology\.kubernetes\.io/zone"=$NODE_AZ \
  --set primary.readinessProbe.initialDelaySeconds=60 \
  --set primary.readinessProbe.periodSeconds=10 \
  --set primary.readinessProbe.timeoutSeconds=5 \
  --set primary.readinessProbe.failureThreshold=6 \
  --set primary.livenessProbe.initialDelaySeconds=60 \
  --set primary.livenessProbe.periodSeconds=10 \
  --set primary.livenessProbe.timeoutSeconds=5 \
  --set primary.livenessProbe.failureThreshold=6 \
  --set primary.resources.requests.cpu=100m \
  --set primary.resources.requests.memory=128Mi \
  --set primary.resources.limits.cpu=150m \
  --set primary.resources.limits.memory=192Mi \
  --set primary.persistence.enabled=true \
  --set primary.persistence.mountPath=/bitnami/postgresql \
  --timeout 600s \
  --wait

# Enhanced error checking
if [ $? -ne 0 ]; then
    echo "Error: PostgreSQL installation failed"
    echo "Checking pod events..."
    kubectl describe pod -l app.kubernetes.io/name=postgresql
    echo "Checking PVC events..."
    kubectl describe pvc data-postgresql-0
    echo "Checking storage class..."
    kubectl describe sc gp2
    echo "Checking EBS CSI Driver pods..."
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
    kubectl describe pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
    exit 1
fi

echo "Checking pod status..."
kubectl get pods -l app.kubernetes.io/name=postgresql -o wide

echo "Checking PVC status..."
kubectl get pvc

echo "Waiting for PostgreSQL pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=300s

install_time=$(date +%s)

echo "Setting up port forwarding..."
kubectl port-forward --namespace default svc/postgresql 5433:5432 &
PORT_FORWARD_PID=$!

# Wait for port-forward to establish
sleep 5

# Test database connection
echo "Testing database connection..."
PGPASSWORD="$DB_PASSWORD" psql --host 127.0.0.1 -U $DB_USER -d $DB_NAME -p 5433 -c "\l" &>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Database connection successful"
else
    echo "❌ Database connection failed"
    exit 1
fi

# Seed the database if db directory exists
if [ -d "db" ] && [ "$(ls -A db/*.sql 2>/dev/null)" ]; then
    echo "Seeding the database..."
    export DB_PASSWORD=$DB_PASSWORD
    for file in db/*.sql; do
        echo "Running seed file: $file"
        PGPASSWORD="$DB_PASSWORD" psql --host 127.0.0.1 -U $DB_USER -d $DB_NAME -p 5433 < "$file"
    done
else
    echo "No seed files found in db directory"
fi

end_time=$(date +%s)

# Cleanup port forwarding
# Kill port forwarding after seeding
kill $PORT_FORWARD_PID || true

end_time=$(date +%s)
echo "-----------------------------------"
echo "PostgreSQL setup and seeding completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"
echo "Installation time: $((install_time - start_time)) seconds"
echo "Seeding time: $((end_time - install_time)) seconds"
echo ""
echo "PostgreSQL is running successfully in your cluster!"
echo ""
echo "To connect to the database:"
echo "1. Start port forwarding:"
echo "   kubectl port-forward --namespace default svc/postgresql 5433:5432"
echo ""
echo "2. In another terminal window, connect using:"
echo "   PGPASSWORD=$DB_PASSWORD psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -p 5433"
echo ""
echo "Note: Port forwarding must be active to connect from your local machine."