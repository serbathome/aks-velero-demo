# Cross-region AKS migration with Velero and Kopia

A one-time migration demo for Linux Kubernetes workloads, including StatefulSets
and their persistent data. Velero backs up Kubernetes resources; CSI snapshot data
movement uses Kopia to upload Azure Disk contents to Blob storage and restore them
into new disks in another Azure region.

## Infrastructure

Terraform creates:

- Source AKS in **Sweden Central** (`Standard_D4as_v5`) and destination AKS in
  **East US 2** (`Standard_D4as_v6`), with Linux nodes and Azure CNI Overlay.
- Non-overlapping, peered VNets, each with a Blob private endpoint and its own
  private DNS zone.
- Shared backup storage in East US 2, with public access and account-key
  authentication disabled. GRS is configured, but Kopia data movement, not GRS,
  makes the disk data portable across regions.
- Managed identities, Workload Identity federation, and backup permissions.

Requires Terraform, Azure CLI, kubectl, Velero CLI **1.18.x**, PowerShell 7, and
`psql` for testing. The Azure principal needs permission to create the resources,
custom roles, and role assignments. Region/SKU eligibility depends on the subscription.

Create your own terraform.tfvars file or define variables values first.

From the project directory in PowerShell:

```powershell
az login
terraform init
terraform plan
terraform apply
```

Changing cluster/storage regions replaces resources; existing backups are not
copied automatically. `terraform destroy` also deletes the backup storage.

## Install Velero

[install-velero.ps1](./install-velero.ps1) reads Terraform outputs and installs or
updates Velero on each cluster with Azure plugin **1.14.4**, CSI support, and Kopia
node agents. Authentication uses Workload Identity, not storage keys. The source
uses read-write backup storage; the destination runs restore-only with a read-only
backup location.

```powershell
.\install-velero.ps1 -Cluster source
.\install-velero.ps1 -Cluster destination

# Add explicit contexts for the commands below; the installer uses temporary kubeconfigs.
$settings = terraform output -json velero | ConvertFrom-Json
foreach ($cluster in @('source', 'destination')) {
    $target = $settings.clusters.$cluster
    az aks get-credentials --subscription $settings.subscription_id --resource-group $target.resource_group --name $target.name --context "velero-$cluster" --overwrite-existing
}
```

Before the first Kopia backup, configure the same custom repository password in
the `velero-repo-credentials` Secret (`repository-password` key) in namespace
`velero` on both clusters. Retain it securely and do not change it after repository
creation. The installer does not manage this password.

## Deploy PostgreSQL and create test data

[deployments/postgresql.yaml](./deployments/postgresql.yaml) creates a namespace,
PostgreSQL 17 StatefulSet, 10 GiB Azure Disk PVC using `managed-csi`, CSI snapshot
class, and services. Username and database are both `demo`; the generated password
is stored on the PVC and restored with the database.

Deploy **only on the source**:

```powershell
kubectl --context velero-source apply -f .\deployments\postgresql.yaml
kubectl --context velero-source -n postgres-demo rollout status statefulset/postgresql
kubectl --context velero-source -n postgres-demo exec postgresql-0 -c postgres -- cat /var/lib/postgresql/data/.postgres-password
kubectl --context velero-source -n postgres-demo port-forward service/postgresql 15432:5432
```

Keep port-forward running. In another terminal, connect using the retrieved password:

```shell
psql -h 127.0.0.1 -p 15432 -U demo -d demo -W
```

```sql
CREATE TABLE migration_test (id integer PRIMARY KEY, message text);
INSERT INTO migration_test VALUES (1, 'Data backed up in Sweden and restored in East US 2');
SELECT * FROM migration_test;
```

The manifest also requests a public LoadBalancer on port 5432, open to all IPv4
clients without TLS: demo use only. Subnet NSGs may block it; port-forward avoids
needing public database access.

## Back up and restore across regions

Pause client writes before backup. This captures a point-in-time disk image,
including PostgreSQL data, WAL, and its password file; PostgreSQL performs crash
recovery on startup. Do not use live file-system copying of PostgreSQL data.

```powershell
velero --kubecontext velero-source backup create postgresql-migration `
  --include-namespaces postgres-demo `
  --snapshot-move-data `
  --default-volumes-to-fs-backup=false `
  --wait

velero --kubecontext velero-source backup describe postgresql-migration --details
kubectl --context velero-source -n velero get datauploads -l velero.io/backup-name=postgresql-migration
```

Require the backup and **all DataUploads** to show `Completed`. Without
`--snapshot-move-data`, regional disk snapshots alone do not provide this
cross-region migration.

Do not pre-deploy PostgreSQL on the destination. Wait until the backup appears in
its shared backup location, then restore:

```powershell
velero --kubecontext velero-destination backup get
velero --kubecontext velero-destination restore create postgresql-migration --from-backup postgresql-migration --wait
velero --kubecontext velero-destination restore describe postgresql-migration --details
kubectl --context velero-destination -n velero get datadownloads -l velero.io/restore-name=postgresql-migration
kubectl --context velero-destination -n postgres-demo get pods,pvc,services
```

Require all DataDownloads to show `Completed` and PostgreSQL to become ready.
Stop the source port-forward and start one against the destination:

```powershell
kubectl --context velero-destination -n postgres-demo rollout status statefulset/postgresql
kubectl --context velero-destination -n postgres-demo port-forward service/postgresql 15432:5432
```

Reconnect with the same `psql` command and password, then run
`SELECT * FROM migration_test;` to verify the restored data before deleting the
source or backup. The destination uses its own disks and IPs; AKS infrastructure
is not restored. For other applications, restore their namespaces and required
application-level cluster resources, not `kube-system` or `velero` wholesale.
