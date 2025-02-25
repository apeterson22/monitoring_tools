#!/bin/bash

NAMESPACE="$1" #  ex: monitoring Change this to your namespace
PVC_NAME="$2" # ex: "grafana-pvc"
DEPLOYMENT_NAME="$3" # ex: "grafana"
BACKUP_DIR="$4" # ex: "grafana_backup"

# Step 1: Identify the PV associated with Grafana PVC
echo "Finding Persistent Volume (PV) for PVC: $PVC_NAME..."
PV_NAME=$(kubectl get pvc $PVC_NAME -n $NAMESPACE -o jsonpath='{.spec.volumeName}')
if [ -z "$PV_NAME" ]; then
    echo "ERROR: Could not find the Persistent Volume for PVC: $PVC_NAME"
    exit 1
fi
echo "Found PV: $PV_NAME"

# Step 2: Backup the PV YAML before modifying
echo "Backing up PV YAML to pv-backup.yaml..."
kubectl get pv $PV_NAME -o yaml > pv-backup.yaml

# Step 3: Backup Grafana Data (Optional)
echo "Backing up Grafana data..."
mkdir -p $BACKUP_DIR
GRAFANA_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl cp $NAMESPACE/$GRAFANA_POD:/var/lib/grafana $BACKUP_DIR

# Step 4: Scale down Grafana to prevent interruptions
echo "Scaling down Grafana deployment..."
kubectl scale deployment $DEPLOYMENT_NAME --replicas=0 -n $NAMESPACE

# Step 5: Export PV YAML and modify reclaim policy
echo "Updating PV reclaim policy to 'Retain'..."
sed -i 's/persistentVolumeReclaimPolicy: Delete/persistentVolumeReclaimPolicy: Retain/g' pv-backup.yaml

# Step 6: Delete the PV from Kubernetes (this does not delete the actual storage)
echo "Deleting PV from Kubernetes..."
kubectl delete pv $PV_NAME

# Step 7: Reapply the PV with updated reclaim policy
echo "Reapplying PV with Retain policy..."
kubectl apply -f pv-backup.yaml

# Step 8: Delete the PVC safely
echo "Deleting old PVC..."
kubectl delete pvc $PVC_NAME -n $NAMESPACE

# Step 9: Recreate the PVC and bind to the retained PV
echo "Creating new PVC..."
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
      storage: 50Gi  # Ensure this matches the PV capacity
  volumeName: $PV_NAME
  storageClassName: ""  # Disable dynamic provisioning to use the existing PV
EOF

# Step 10: Verify PVC is Bound
echo "Checking if PVC is bound..."
kubectl get pvc $PVC_NAME -n $NAMESPACE

# Step 11: Scale Grafana back up
echo "Restarting Grafana deployment..."
kubectl scale deployment $DEPLOYMENT_NAME --replicas=1 -n $NAMESPACE

# Step 12: Verify Grafana is running and connected to the PVC
echo "Checking Grafana logs..."
kubectl logs -l app.kubernetes.io/name=grafana -n $NAMESPACE --tail=50

echo "PVC migration completed successfully!"
