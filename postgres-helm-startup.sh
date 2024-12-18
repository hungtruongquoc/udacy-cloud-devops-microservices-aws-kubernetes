#!/bin/bash

echo "Starting PostgreSQL setup with Helm at $(date)"
echo "-----------------------------------"

# Start timing
start_time=$(date +%s)

echo "Installing EBS CSI Driver..."
# Add aws-ebs-csi-driver repo
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# Install EBS CSI Driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=ebs-csi-controller-sa || true

# Wait for EBS CSI Driver pods to be ready
echo "Waiting for EBS CSI Driver pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-ebs-csi-driver -n kube-system --timeout=300s

ebs_install_time=$(date +%s)
echo "EBS CSI Driver installation completed in $((ebs_install_time - start_time)) seconds"
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
  --set primary.livenessProbe.failureThreshold=6

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

# Wait a bit for port-forward to establish
sleep 5

# Seed the database
echo "Seeding the database..."
export DB_PASSWORD=$DB_PASSWORD
for file in db/*.sql; do
  echo "Running seed file: $file"
  PGPASSWORD="$DB_PASSWORD" psql --host 127.0.0.1 -U $DB_USER -d $DB_NAME -p 5433 < "$file"
done

end_time=$(date +%s)

# Cleanup port forwarding
kill $PORT_FORWARD_PID

echo "-----------------------------------"
echo "PostgreSQL setup and seeding completed at $(date)"
echo "Total setup time: $((end_time - start_time)) seconds"
echo "Installation time: $((install_time - start_time)) seconds"
echo "Seeding time: $((end_time - install_time)) seconds"
echo ""
echo "Connection Information:"
echo "  Host: 127.0.0.1"
echo "  Port: 5433"
echo "  Database: $DB_NAME"
echo "  Username: $DB_USER"
echo "  Password: $DB_PASSWORD"
echo ""
echo "To connect to the database:"
echo "PGPASSWORD=$DB_PASSWORD psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -p 5433"