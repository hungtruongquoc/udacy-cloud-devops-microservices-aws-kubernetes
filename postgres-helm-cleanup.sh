#!/bin/bash

# Exit on error
set -e

echo "Starting PostgreSQL cleanup..."

# Function to check if a resource exists
resource_exists() {
    local namespace=$1
    local resource_type=$2
    local resource_name=$3

    kubectl get -n "$namespace" "$resource_type" "$resource_name" >/dev/null 2>&1
    return $?
}

# Function to force cleanup stuck PVCs
force_cleanup_pvc() {
    local namespace=$1
    local pvc_name=$2

    echo "Attempting to force cleanup PVC: $pvc_name"
    kubectl patch pvc $pvc_name -n $namespace -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl delete pvc $pvc_name -n $namespace --force --grace-period=0 2>/dev/null || true
}

# Function to check cleanup status
check_cleanup_status() {
    echo "Checking remaining resources..."

    # Check for pods
    local pods=$(kubectl get pods -n postgresql 2>/dev/null | grep -v "No resources found" || true)
    if [ ! -z "$pods" ]; then
        echo "Remaining pods:"
        echo "$pods"
    fi

    # Check for PVCs
    local pvcs=$(kubectl get pvc -n postgresql 2>/dev/null | grep -v "No resources found" || true)
    if [ ! -z "$pvcs" ]; then
        echo "Remaining PVCs:"
        echo "$pvcs"
    fi

    # Check for PVs
    local pvs=$(kubectl get pv 2>/dev/null | grep postgresql || true)
    if [ ! -z "$pvs" ]; then
        echo "Remaining PVs:"
        echo "$pvs"
    fi
}

# Check if namespace exists
if ! kubectl get namespace postgresql >/dev/null 2>&1; then
    echo "PostgreSQL namespace not found. Nothing to clean up."
    exit 0
fi

# Check if Helm release exists
if helm list -n postgresql | grep -q "postgresql"; then
    echo "Removing PostgreSQL Helm release..."
    helm uninstall postgresql -n postgresql

    # Wait for pods to terminate
    echo "Waiting for PostgreSQL pods to terminate..."
    kubectl wait --for=delete pod -l app.kubernetes.io/instance=postgresql -n postgresql --timeout=60s || true
fi

# Handle stuck PVCs
echo "Checking for stuck PVCs..."
pvc_list=$(kubectl get pvc -n postgresql -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for pvc in $pvc_list; do
    echo "Cleaning up PVC: $pvc"
    force_cleanup_pvc "postgresql" "$pvc"
done

# Delete the namespace
echo "Deleting PostgreSQL namespace..."
kubectl delete namespace postgresql --timeout=60s || {
    echo "Namespace deletion timed out. Attempting force deletion..."
    kubectl delete namespace postgresql --force --grace-period=0
}

# Remove Helm repo
echo "Removing Bitnami Helm repository..."
helm repo remove bitnami

# Cleanup local files
echo "Cleaning up local files..."
rm -f postgres-values.yaml
rm -f .pg_credentials

# Final verification
echo "Performing final verification..."
if kubectl get namespace postgresql >/dev/null 2>&1; then
    echo "Warning: PostgreSQL namespace still exists. You may need to manually verify and clean up resources."
    check_cleanup_status
else
    echo "PostgreSQL cleanup completed successfully!"
fi

echo "Note: If any resources remain, you may need to manually remove them using the following commands:"
echo "kubectl delete pvc --all -n postgresql --force --grace-period=0"
echo "kubectl delete namespace postgresql --force --grace-period=0"