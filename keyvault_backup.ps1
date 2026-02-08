#requires -Modules Az.Accounts, Az.KeyVault, Az.Storage

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Configuration (explicit, reviewable, non-interactive)
# ------------------------------------------------------------
$Config = @{
    KeyVaultList = @(
        "KV-landingzone-prod-8533",
        "KV-landingzone-prod-8534",
        "KV-landingzone-prod-8535"
    )

    StorageAccountName = "tststrgaccnthldr03"
    ContainerName      = "keyvault-backups"
}

# ------------------------------------------------------------
# Startup banner
# ------------------------------------------------------------
Write-Output "=============================================="
Write-Output "Starting Key Vault key backup script"
Write-Output "Run as logged-in Azure user"
Write-Output "=============================================="

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------
if (-not $Config.KeyVaultList -or $Config.KeyVaultList.Count -eq 0) {
    throw "KeyVaultList is empty in configuration."
}

if ([string]::IsNullOrWhiteSpace($Config.StorageAccountName)) {
    throw "StorageAccountName is not set in configuration."
}

if ([string]::IsNullOrWhiteSpace($Config.ContainerName)) {
    throw "ContainerName is not set in configuration."
}

Write-Output "Key Vaults to back up:"
$Config.KeyVaultList | ForEach-Object { Write-Output " - $_" }

# ------------------------------------------------------------
# Authenticate (human identity)
# ------------------------------------------------------------
Write-Output "Authenticating to Azure using current user..."
Connect-AzAccount | Out-Null

$context = Get-AzContext
Write-Output "Authenticated as: $($context.Account.Id)"
Write-Output "Tenant: $($context.Tenant.Id)"
Write-Output "Subscription: $($context.Subscription.Name)"

# ------------------------------------------------------------
# Create OAuth-based Storage Context (data plane)
# ------------------------------------------------------------
Write-Output "Creating storage context for account: $($Config.StorageAccountName)"

$storageCtx = New-AzStorageContext `
    -StorageAccountName $Config.StorageAccountName `
    -UseConnectedAccount

# ------------------------------------------------------------
# Ensure destination container exists
# ------------------------------------------------------------
if (-not (Get-AzStorageContainer `
            -Context $storageCtx `
            -Name $Config.ContainerName `
            -ErrorAction SilentlyContinue)) {

    Write-Output "Creating storage container: $($Config.ContainerName)"

    New-AzStorageContainer `
        -Context $storageCtx `
        -Name $Config.ContainerName `
        -Permission Off | Out-Null
}

# ------------------------------------------------------------
# Backup keys from each Key Vault
# ------------------------------------------------------------
$timestamp     = (Get-Date).ToString("yyyyMMdd-HHmmss")
$totalUploaded = 0

foreach ($vaultName in $Config.KeyVaultList) {

    Write-Output "----------------------------------------------"
    Write-Output "Processing Key Vault: $vaultName"

    try {
        $keys = Get-AzKeyVaultKey -VaultName $vaultName
    }
    catch {
        Write-Error "Failed to enumerate keys in Key Vault: $vaultName"
        continue
    }

    if (-not $keys) {
        Write-Output "No keys found in Key Vault: $vaultName"
        continue
    }

    foreach ($key in $keys) {

        Write-Output "Backing up key: $($key.Name)"

        $outFile = Join-Path `
            $env:TEMP `
            "$vaultName-$($key.Name)-$timestamp.keybackup"

        Backup-AzKeyVaultKey `
            -VaultName $vaultName `
            -Name $key.Name `
            -OutputFile $outFile | Out-Null

        if (-not (Test-Path $outFile)) {
            throw "Backup file not created for key $($key.Name) in vault $vaultName"
        }

        $blobName = "$vaultName/$timestamp/$($key.Name).backup"

        $metadata = @{
            VaultName  = $vaultName
            KeyName    = $key.Name
            BackupTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            Operator   = $context.Account.Id
        }

        Set-AzStorageBlobContent `
            -Context $storageCtx `
            -Container $Config.ContainerName `
            -File $outFile `
            -Blob $blobName `
            -Metadata $metadata `
            -Force | Out-Null

        Remove-Item $outFile -Force
        $totalUploaded++
    }
}

# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------
Write-Output "=============================================="
Write-Output "Key Vault key backup completed successfully"
Write-Output "Total keys backed up: $totalUploaded"
Write-Output "=============================================="
