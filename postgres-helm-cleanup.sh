#!/bin/bash

echo "Starting PostgreSQL cleanup at $(date)"
echo "-----------------------------------"

start_time=$(date +%s)

# Kill any existing port-forward processes
echo "Stopping port forwarding..."
ps aux | grep 'kubectl port-forward.*postgresql' | grep -v grep | awk '{print $2}' | xargs -r kill

# Uninstall PostgreSQL
echo "Uninstalling PostgreSQL..."
helm uninstall postgresql || true

# Wait for pods to be deleted
echo "Waiting for PostgreSQL pods to be deleted..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=postgresql --timeout=300s || true

# Delete PVCs
echo "Deleting PersistentVolumeClaims (PVCs)..."
kubectl delete pvc -l app.kubernetes.io/name=postgresql --force --grace-period=0 || true

# Wait for PVs to be released
echo "Waiting for PersistentVolumes (PVs) to be released..."
sleep 5
kubectl get pv | grep postgresql | awk '{print $1}' | xargs -r kubectl delete pv || true

end_time=$(date +%s)

echo "-----------------------------------"
echo "Cleanup completed at $(date)"
echo "Total cleanup time: $((end_time - start_time)) seconds"