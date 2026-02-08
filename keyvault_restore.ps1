#requires -Modules Az.Accounts, Az.KeyVault, Az.Storage

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$Config = @{
    StorageAccountName = "tststrgaccnthldr03"
    ContainerName      = "keyvault-backups"

    # Target vault where keys will be restored
    TargetKeyVaultName = "KV-landingzone-prod-8533"

    # Restore mode: SingleKey | AllKeysInFolder
    RestoreMode        = "AllKeysInFolder"

    # Blob folder path (vault/timestamp)
    BackupFolderPath   = "KV-landingzone-prod-8533/20260209-001931"

    # Used only if RestoreMode = SingleKey
    BackupFileName     = "key1.backup"
}

# ------------------------------------------------------------
# Authenticate (human identity)
# ------------------------------------------------------------
Write-Output "Authenticating to Azure..."
Connect-AzAccount | Out-Null

$context = Get-AzContext
Write-Output "Running as: $($context.Account.Id)"
Write-Output "Target Key Vault: $($Config.TargetKeyVaultName)"

# ------------------------------------------------------------
# Create storage context
# ------------------------------------------------------------
$storageCtx = New-AzStorageContext `
    -StorageAccountName $Config.StorageAccountName `
    -UseConnectedAccount

# ------------------------------------------------------------
# List backup blobs
# ------------------------------------------------------------
Write-Output "Locating backup blobs..."

$blobs = Get-AzStorageBlob `
    -Context $storageCtx `
    -Container $Config.ContainerName `
    | Where-Object {
        $_.Name -like "$($Config.BackupFolderPath)/*"
    }

if (-not $blobs) {
    throw "No backup blobs found at path $($Config.BackupFolderPath)"
}

# ------------------------------------------------------------
# Restore logic
# ------------------------------------------------------------
foreach ($blob in $blobs) {

    if ($Config.RestoreMode -eq "SingleKey" -and
        -not $blob.Name.EndsWith($Config.BackupFileName)) {
        continue
    }

    Write-Output "Restoring from blob: $($blob.Name)"

    $tempFile = Join-Path `
        $env:TEMP `
        ([System.IO.Path]::GetFileName($blob.Name))

    Get-AzStorageBlobContent `
        -Context $storageCtx `
        -Container $Config.ContainerName `
        -Blob $blob.Name `
        -Destination $tempFile `
        -Force | Out-Null

    Restore-AzKeyVaultKey `
        -VaultName $Config.TargetKeyVaultName `
        -InputFile $tempFile | Out-Null

    Remove-Item $tempFile -Force
}

# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------
Write-Output "=============================================="
Write-Output "Key restoration completed successfully"
Write-Output "Verify restored keys and versions"
Write-Output "=============================================="
