#!/bin/bash

# Script to migrate a PersistentVolumeClaim (PVC) from "Delete" to "Retain"
# This script dynamically detects PVC, PV, and optionally associated Deployment, and applies changes.

# Default Namespace and Application Names for Common Services
DEFAULT_NAMESPACE="monitoring"
DEFAULT_PVC_NAMES=("grafana-pvc" "elasticsearch-pvc" "kibana-pvc" "logstash-pvc" "artifactory-pvc")
DEFAULT_DEPLOYMENTS=("grafana" "elasticsearch" "kibana" "logstash" "artifactory")

# Allow Namespace, PVC, and Storage Size to be set dynamically
NAMESPACE=${1:-$DEFAULT_NAMESPACE}
PVC_NAME=${2}
NEW_STORAGE_SIZE=${3:-"10Gi"}  # Default to 10Gi if not provided

# Auto-detect PVC if not provided
if [ -z "$PVC_NAME" ]; then
    echo "No PVC name provided. Searching for a default matching PVC..."
    for DEFAULT_PVC in "${DEFAULT_PVC_NAMES[@]}"; do
        if kubectl get pvc $DEFAULT_PVC -n $NAMESPACE &>/dev/null; then
            PVC_NAME=$DEFAULT_PVC
            echo "Found PVC: $PVC_NAME"
            break
        fi
    done
    if [ -z "$PVC_NAME" ]; then
        echo "ERROR: No matching PVC found in namespace $NAMESPACE. Exiting."
        exit 1
    fi
fi

# Identify the Persistent Volume (PV) associated with the PVC
echo "Finding Persistent Volume (PV) for PVC: $PVC_NAME..."
PV_NAME=$(kubectl get pvc $PVC_NAME -n $NAMESPACE -o jsonpath='{.spec.volumeName}')
if [ -z "$PV_NAME" ]; then
    echo "ERROR: Could not find the Persistent Volume for PVC: $PVC_NAME"
    exit 1
fi
echo "Found PV: $PV_NAME"

# Backup the PV YAML
echo "Backing up PV YAML to pv-backup.yaml..."
kubectl get pv $PV_NAME -o yaml > pv-backup.yaml

# Detect Deployment Name (Optional)
DEPLOYMENT_NAME=""
for DEFAULT_DEPLOYMENT in "${DEFAULT_DEPLOYMENTS[@]}"; do
    if kubectl get deployment $DEFAULT_DEPLOYMENT -n $NAMESPACE &>/dev/null; then
        DEPLOYMENT_NAME=$DEFAULT_DEPLOYMENT
        echo "Detected Deployment: $DEPLOYMENT_NAME"
        break
    fi
done

# Backup Application Data if Deployment Exists
if [ -n "$DEPLOYMENT_NAME" ]; then
    BACKUP_DIR="${DEPLOYMENT_NAME}_backup"
    echo "Backing up $DEPLOYMENT_NAME data..."
    mkdir -p $BACKUP_DIR
    APP_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$DEPLOYMENT_NAME -o jsonpath='{.items[0].metadata.name}')
    kubectl cp $NAMESPACE/$APP_POD:/var/lib/$DEPLOYMENT_NAME $BACKUP_DIR

    # Scale down the deployment to prevent interruptions
    echo "Scaling down $DEPLOYMENT_NAME deployment..."
    kubectl scale deployment $DEPLOYMENT_NAME --replicas=0 -n $NAMESPACE
fi

# Modify PV YAML to Retain
echo "Updating PV reclaim policy to 'Retain'..."
sed -i 's/persistentVolumeReclaimPolicy: Delete/persistentVolumeReclaimPolicy: Retain/g' pv-backup.yaml

# Delete PV from Kubernetes (storage remains intact)
echo "Deleting PV from Kubernetes..."
kubectl delete pv $PV_NAME

# Reapply PV with updated policy
echo "Reapplying PV with Retain policy..."
kubectl apply -f pv-backup.yaml

# Delete and Recreate PVC
echo "Deleting old PVC..."
kubectl delete pvc $PVC_NAME -n $NAMESPACE

echo "Creating new PVC with size $NEW_STORAGE_SIZE..."
cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $NEW_STORAGE_SIZE
  volumeName: $PV_NAME
  storageClassName: ""
EOF

# Scale the deployment back up if it exists
if [ -n "$DEPLOYMENT_NAME" ]; then
    echo "Restarting $DEPLOYMENT_NAME deployment..."
    kubectl scale deployment $DEPLOYMENT_NAME --replicas=1 -n $NAMESPACE

    # Check deployment logs to verify successful restart
    echo "Checking logs for $DEPLOYMENT_NAME..."
    kubectl logs -l app.kubernetes.io/name=$DEPLOYMENT_NAME -n $NAMESPACE --tail=50
fi

# Verify PVC is bound
echo "Checking PVC status..."
kubectl get pvc $PVC_NAME -n $NAMESPACE

echo "PVC migration completed successfully!"
