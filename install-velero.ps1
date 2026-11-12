<#
.SYNOPSIS
Installs Velero on a Terraform-managed AKS cluster using Entra Workload Identity.
.DESCRIPTION
Run terraform apply first. Requires Terraform, Azure CLI (az login), kubectl,
Velero CLI 1.18.x, and Kubernetes cluster-admin access. The Terraform principal
must be allowed to create managed identities, custom roles and role assignments.

The Azure plugin is pinned to 1.14.4, compatible with Velero 1.18.x. Its
cloud-credentials Secret contains only subscription/resource-group configuration,
not an access key, client secret, certificate or token. Authentication uses the
federated managed identity injected by the AKS Workload Identity webhook.

The source writes to the shared container; the destination runs in restore-only
mode with a read-only backup location. CSI support and Kopia node agents are
enabled for Azure Disk snapshot data movement, including cross-region restores.
Use --snapshot-move-data when creating a backup; snapshots alone are regional.
GRS blob replication does not replicate managed-disk snapshots. File-system
backup (for example Azure Files) is not enabled: node agents do not mount host
pod-volume paths.

Backup Blob storage follows the destination cluster region. Changing its region
recreates the storage account; existing backups are not migrated automatically.
Before the first Kopia backup, configure the same custom repository password in
the velero-repo-credentials Secret on both clusters and retain it securely.
Do not change that password after repository creation. This installer does not
set or replace repository passwords.

Terraform provisions peered, non-overlapping AKS VNets, each with a Blob private
endpoint and its own privatelink.blob.core.windows.net DNS zone. The normal Blob
hostname resolves to the local private endpoint inside each VNet; public storage
access stays disabled. Peering is not required for either cluster's storage path.
Applying the custom network topology to existing default-network clusters
recreates them. Reinstall Velero on both clusters after terraform apply.

Backups are in a separate resource group, but terraform destroy still deletes
them. This script does not apply Terraform or create backup schedules.
.EXAMPLE
.\install-velero.ps1 -Cluster source
.EXAMPLE
.\install-velero.ps1 -Cluster destination
.EXAMPLE
.\install-velero.ps1 -Cluster source -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('source', 'destination')]
    [string]$Cluster = 'source',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

$requiredCommands = @('terraform', 'velero')
if (-not $DryRun) {
    $requiredCommands += @('az', 'kubectl')
}
foreach ($command in $requiredCommands) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found on PATH."
    }
}

$clientVersion = Invoke-Checked -Command velero -Arguments @('version', '--client-only') | Out-String
$versionMatch = [regex]::Match($clientVersion, 'Version:\s+(v1\.18\.\d+)\b')
if (-not $versionMatch.Success) {
    throw 'This script requires Velero CLI 1.18.x for the pinned Azure plugin 1.14.4.'
}

$settingsJson = Invoke-Checked -Command terraform -Arguments @("-chdir=$PSScriptRoot", 'output', '-json', 'velero') | Out-String
$settings = $settingsJson | ConvertFrom-Json
if (-not $settings -or -not $settings.PSObject.Properties['clusters']) {
    throw "Missing Terraform 'velero' output. Run terraform apply in '$PSScriptRoot' first."
}
$target = $settings.clusters.$Cluster
$context = "velero-$Cluster"
$credentialsFile = [System.IO.Path]::GetTempFileName()
$locationPatchFile = "$credentialsFile.location.json"
$kubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "velero-$([guid]::NewGuid().ToString('N')).yaml"

try {
    # The plugin requires a configuration file even with federated authentication.
    $configuration = @(
        "AZURE_SUBSCRIPTION_ID=$($settings.subscription_id)"
        "AZURE_RESOURCE_GROUP=$($target.node_resource_group)"
        'AZURE_CLOUD_NAME=AzurePublicCloud'
    ) -join "`n"
    [System.IO.File]::WriteAllText($credentialsFile, "$configuration`n", [System.Text.Encoding]::ASCII)

    $backupConfig = @(
        'useAAD=true'
        "storageAccountURI=$($settings.storage_account_uri)"
        "resourceGroup=$($settings.backup_resource_group)"
        "storageAccount=$($settings.storage_account)"
        "subscriptionId=$($settings.subscription_id)"
    ) -join ','
    $snapshotConfig = @(
        "resourceGroup=$($settings.backup_resource_group)"
        "subscriptionId=$($settings.subscription_id)"
        'incremental=true'
        'apiTimeout=5m'
    ) -join ','
    $installArguments = @(
        'install'
        '--apply'
        '--namespace', $settings.namespace
        '--provider', 'azure'
        '--image', "velero/velero:$($versionMatch.Groups[1].Value)"
        '--plugins', 'velero/velero-plugin-for-microsoft-azure:v1.14.4'
        '--features', 'EnableCSI'
        '--use-node-agent'
        '--node-agent-disable-host-path'
        '--uploader-type', 'kopia'
        '--bucket', $settings.container
        '--secret-file', $credentialsFile
        '--sa-annotations', "azure.workload.identity/client-id=$($target.client_id),azure.workload.identity/tenant-id=$($settings.tenant_id)"
        '--pod-labels', 'azure.workload.identity/use=true'
        '--backup-location-config', $backupConfig
        '--snapshot-location-config', $snapshotConfig
    )
    if ($target.access_mode -eq 'ReadOnly') {
        $installArguments += '--restore-only'
    }
    if ($DryRun) {
        $manifestJson = Invoke-Checked -Command velero -Arguments ($installArguments + @('--dry-run', '-o', 'json')) | Out-String
        $manifest = $manifestJson | ConvertFrom-Json
        $location = $manifest.items | Where-Object kind -eq 'BackupStorageLocation'
        $location.spec | Add-Member -NotePropertyName accessMode -NotePropertyValue $target.access_mode -Force
        $manifest | ConvertTo-Json -Depth 100
        return
    }

    Write-Host "Installing Velero on $($target.name) ($Cluster, $($target.access_mode))."
    # Isolate cluster selection: do not modify or rely on the user's current context.
    Invoke-Checked -Command az -Arguments @(
        'aks', 'get-credentials'
        '--subscription', $settings.subscription_id
        '--resource-group', $target.resource_group
        '--name', $target.name
        '--file', $kubeconfig
        '--context', $context
        '--overwrite-existing'
        '--only-show-errors'
    )
    $clusterArguments = @('--kubeconfig', $kubeconfig, '--kubecontext', $context, '--namespace', $settings.namespace)
    Invoke-Checked -Command velero -Arguments ($installArguments + $clusterArguments + @('--wait'))
    foreach ($workload in @('deployment/velero', 'daemonset/node-agent')) {
        Invoke-Checked -Command kubectl -Arguments @(
            '--kubeconfig', $kubeconfig
            '--context', $context
            '--namespace', $settings.namespace
            'rollout', 'status', $workload
            '--timeout=10m'
        )
    }
    $locationPatch = @{ spec = @{ accessMode = $target.access_mode } } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($locationPatchFile, $locationPatch, [System.Text.Encoding]::ASCII)
    Invoke-Checked -Command kubectl -Arguments @(
        '--kubeconfig', $kubeconfig
        '--context', $context
        '--namespace', $settings.namespace
        'patch', 'backupstoragelocation/default'
        '--type=merge'
        '--patch-file', $locationPatchFile
    )
    Write-Host 'Waiting for backup storage access (new Azure role assignments can take several minutes).'
    Invoke-Checked -Command kubectl -Arguments @(
        '--kubeconfig', $kubeconfig
        '--context', $context
        '--namespace', $settings.namespace
        'wait', 'backupstoragelocation/default'
        '--for=jsonpath={.status.phase}=Available'
        '--timeout=10m'
    )
    Invoke-Checked -Command velero -Arguments (@('backup-location', 'get') + $clusterArguments)
    Write-Host "Velero and Kopia node agents are ready on $($target.name), using Entra Workload Identity."
}
finally {
    Remove-Item -LiteralPath $credentialsFile -Force
    if (Test-Path -LiteralPath $locationPatchFile) {
        Remove-Item -LiteralPath $locationPatchFile -Force
    }
    if (Test-Path -LiteralPath $kubeconfig) {
        Remove-Item -LiteralPath $kubeconfig -Force
    }
}
