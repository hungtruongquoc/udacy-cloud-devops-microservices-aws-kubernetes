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

# Clean up EBS CSI Driver components
echo "Cleaning up EBS CSI Driver..."
helm uninstall aws-ebs-csi-driver -n kube-system || true

# Wait for EBS CSI Driver pods to be deleted
echo "Waiting for EBS CSI Driver pods to be deleted..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=aws-ebs-csi-driver -n kube-system --timeout=300s || true
kubectl wait --for=delete pod -l app=ebs-csi-controller -n kube-system --timeout=300s || true

# Delete the service account
echo "Cleaning up service account..."
SA_NAME="ebs-csi-controller-sa"
kubectl delete serviceaccount -n kube-system $SA_NAME || true

# Delete any orphaned resources
echo "Checking for orphaned resources..."
kubectl delete pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n kube-system -l app=ebs-csi-controller --force --grace-period=0 2>/dev/null || true

end_time=$(date +%s)

echo "-----------------------------------"
echo "Cleanup completed at $(date)"
echo "Total cleanup time: $((end_time - start_time)) seconds"