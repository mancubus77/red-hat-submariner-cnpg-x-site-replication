# CNPG Cross-Site Replication with Submariner

This setup deploys CloudNativePG (CNPG) with cross-cluster replication using Submariner for secure inter-cluster communication.

## Architecture

```
┌─────────────────────────────────────┐      ┌─────────────────────────────────────┐
│           Cluster-One                   │      │           Cluster-Two                   │
│         (local-cluster)              │      │                                      │
│                                      │      │                                      │
│  ┌─────────────────────────────────┐ │      │  ┌─────────────────────────────────┐ │
│  │      cnpg-database namespace     │ │      │  │      cnpg-database namespace     │ │
│  │                                  │ │      │  │                                  │ │
│  │  ┌─────────────────────────────┐ │ │      │  │  ┌─────────────────────────────┐ │ │
│  │  │    cnpg-primary (Primary)   │ │ │      │  │  │    cnpg-replica (Replica)   │ │ │
│  │  │    2 PostgreSQL instances   │ │ │      │  │  │    2 PostgreSQL instances   │ │ │
│  │  │                             │ │ │      │  │  │                             │ │ │
│  │  │  - cnpg-primary-1 (Primary) │ │ │      │  │  │  - cnpg-replica-1 (Standby) │ │ │
│  │  │  - cnpg-primary-2 (Standby) │ │ │◀────▶│  │  │  - cnpg-replica-2 (Standby) │ │ │
│  │  │                             │ │ │      │  │  │                             │ │ │
│  │  └─────────────────────────────┘ │ │      │  │  └─────────────────────────────┘ │ │
│  │                                  │ │      │  │                                  │ │
│  │  ServiceExport:                  │ │      │  │  externalClusters:               │ │
│  │    cnpg-primary-rw              │ │      │  │    host: cnpg-primary-rw         │ │
│  │    cnpg-primary-r               │ │      │  │    .cnpg-database.svc            │ │
│  │                                  │ │      │  │    .clusterset.local             │ │
│  └─────────────────────────────────┘ │      │  └─────────────────────────────────┘ │
│                                      │      │                                      │
│  ┌──────────────────────────────┐    │      │    ┌──────────────────────────────┐  │
│  │    Submariner Gateway        │◀──────────────▶│    Submariner Gateway        │  │
│  │    (IPsec Tunnel)            │    │      │    │    (IPsec Tunnel)            │  │
│  └──────────────────────────────┘    │      │    └──────────────────────────────┘  │
└─────────────────────────────────────┘      └─────────────────────────────────────┘
```

## Prerequisites

1. **Two OpenShift clusters** managed by ACM (Advanced Cluster Management)
2. **Submariner** installed and configured with:
   - Globalnet enabled
   - Broker deployed on hub cluster
   - ManagedClusterAddOn deployed on both clusters
3. **Submariner connectivity** verified between clusters

## Components

### Base Resources (applied to both clusters)
- `namespace.yaml` - Creates the `cnpg-database` namespace
- `subscription.yaml` - Installs the CNPG operator from OperatorHub
- `db-credentials-secret.yaml` - Database credentials for superuser and app user

### Cluster-One (Primary Site)
- `primary-cluster.yaml` - Primary PostgreSQL cluster with 2 instances
- `streaming-replica-secret.yaml` - Credentials for streaming replication
- `service-export.yaml` - Exports PostgreSQL services via Submariner

### Cluster-Two (Replica Site)
- `replica-cluster.yaml` - Replica PostgreSQL cluster with 2 instances
- `service-export.yaml` - Exports replica services (for failover scenarios)

## Deployment

### Step 1: Deploy on Cluster-One (Primary)

```bash
# Set kubeconfig to cluster-one
export KUBECONFIG=cluster-one/auth/kubeconfig

# Apply the manifests
kubectl apply -k cnpg-cross-site/cluster-one

# Wait for the operator to be ready
kubectl wait --for=condition=available deployment/cloudnative-pg \
  -n openshift-operators --timeout=300s

# Wait for the primary cluster to be ready
kubectl wait --for=condition=Ready cluster/cnpg-primary \
  -n cnpg-database --timeout=600s
```

### Step 2: Deploy on Cluster-Two (Replica)

```bash
# Set kubeconfig to cluster-two
export KUBECONFIG=cluster-two/auth/kubeconfig

# Apply the manifests
kubectl apply -k cnpg-cross-site/cluster-two

# Wait for the operator to be ready
kubectl wait --for=condition=available deployment/cloudnative-pg \
  -n openshift-operators --timeout=300s

# Wait for the replica cluster to be ready
kubectl wait --for=condition=Ready cluster/cnpg-replica \
  -n cnpg-database --timeout=600s
```

## Verification

### Check Submariner Connectivity

```bash
# On hub cluster, verify ServiceExport
kubectl get serviceexport -n cnpg-database

# Verify the service is imported on cluster-two
export KUBECONFIG=cluster-two/auth/kubeconfig
kubectl get serviceimport -n cnpg-database
```

### Verify Replication Status

```bash
# On cluster-one - check primary status
export KUBECONFIG=cluster-one/auth/kubeconfig
kubectl get cluster cnpg-primary -n cnpg-database -o yaml | grep -A 10 status:

# On cluster-two - check replica status
export KUBECONFIG=cluster-two/auth/kubeconfig
kubectl get cluster cnpg-replica -n cnpg-database -o yaml | grep -A 10 status:
```

### Test Data Replication

```bash
# Connect to primary on cluster-one
export KUBECONFIG=cluster-one/auth/kubeconfig
kubectl exec -it cnpg-primary-1 -n cnpg-database -- psql -U postgres -d appdb -c "CREATE TABLE test_replication (id serial PRIMARY KEY, data text, created_at timestamp DEFAULT now());"
kubectl exec -it cnpg-primary-1 -n cnpg-database -- psql -U postgres -d appdb -c "INSERT INTO test_replication (data) VALUES ('Hello from primary!');"

# Verify data on replica (cluster-two)
export KUBECONFIG=cluster-two/auth/kubeconfig
kubectl exec -it cnpg-replica-1 -n cnpg-database -- psql -U postgres -d appdb -c "SELECT * FROM test_replication;"
```

## Failover Procedure

To promote the replica cluster to primary:

```bash
# On cluster-two
export KUBECONFIG=cluster-two/auth/kubeconfig

# Edit the replica cluster to disable replica mode
kubectl patch cluster cnpg-replica -n cnpg-database --type=merge -p '{"spec":{"replica":{"enabled":false}}}'
```

## Troubleshooting

### Check Submariner Status

```bash
# On either cluster
subctl show all
```

### Check CNPG Operator Logs

```bash
kubectl logs -l app.kubernetes.io/name=cloudnative-pg -n openshift-operators -f
```

### Check PostgreSQL Pod Logs

```bash
# Cluster-One
kubectl logs cnpg-primary-1 -n cnpg-database

# Cluster-Two
kubectl logs cnpg-replica-1 -n cnpg-database
```

### Verify DNS Resolution via Submariner

```bash
# On cluster-two, verify the clusterset.local DNS resolves
kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup cnpg-primary-rw.cnpg-database.svc.clusterset.local
```

## Security Notes

1. **Credentials**: The secrets in this demo use example passwords. In production, use sealed-secrets or external secret management.
2. **Network**: All cross-cluster traffic is encrypted via Submariner's IPsec tunnel.
3. **TLS**: Consider enabling SSL for PostgreSQL connections for additional security.

## Customization

### Change Storage Class

Edit the `storageClass` in the cluster YAML files:

```yaml
storage:
  size: 10Gi
  storageClass: your-storage-class
```

### Adjust Resources

Modify the `resources` section in cluster YAML files based on your workload requirements.

### Enable Monitoring

Set `enablePodMonitor: true` in the monitoring section if you have Prometheus installed.


