#!/bin/bash

# Exit on error
set -e

# Set up script directory path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/deployment/kubernetes/postgresql-helm-config.yaml"

# Function to execute SQL file
execute_sql_file() {
    local file=$1
    echo "Executing SQL file: $file..."
    kubectl cp "db/$file" postgresql/postgresql-0:/tmp/$file
    kubectl exec -n postgresql postgresql-0 -- /bin/bash -c \
        "PGPASSWORD=admin123! psql -U app_user -d app_database -f /tmp/$file"
}

echo "Starting PostgreSQL installation using Helm..."

# Add the Bitnami repository
echo "Adding Bitnami Helm repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace for PostgreSQL
echo "Creating PostgreSQL namespace..."
kubectl create namespace postgresql --dry-run=client -o yaml | kubectl apply -f -

# Install PostgreSQL using Helm
echo "Installing PostgreSQL..."
helm install postgresql bitnami/postgresql \
  --namespace postgresql \
  --values "$VALUES_FILE"

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=postgresql --timeout=300s -n postgresql

echo "PostgreSQL installation completed!"

# Additional wait for PostgreSQL to be fully ready
echo "Waiting for PostgreSQL to be fully ready..."
sleep 30

# Check if db directory exists
if [ ! -d "db" ]; then
    echo "Error: db directory not found!"
    exit 1
fi

# Execute SQL files in order
echo "Executing SQL files..."
SQL_FILES=("1_create_tables.sql" "2_seed_users.sql" "3_seed_tokens.sql")

for file in "${SQL_FILES[@]}"; do
    if [ -f "db/$file" ]; then
        execute_sql_file $file
    else
        echo "Warning: $file not found in db directory"
    fi
done

echo "--------------------------------"
echo "Connection Information:"
echo "To connect to your database, run:"
echo "kubectl port-forward --namespace postgresql svc/postgresql 5432:5432 &"
echo "Then connect using:"
echo "Username: app_user"
echo "Password: admin123!"
echo "Database: app_database"
echo "--------------------------------"

echo "Installation complete!"