#requires -Modules Az.Accounts, Az.AppConfiguration, Az.Storage

$ErrorActionPreference = "Stop"

Write-Output "=== App Configuration Restore Started ==="

#------------------------------------------------------------
# CONFIGURATION
#------------------------------------------------------------

$Config = @{
    # Storage location of backups
    StorageAccountName = "tststrgaccnthldr03"
    ContainerName      = "appconfig-backups"

    # Target App Configuration
    TargetAppConfigName = "test-aue-appconfig"
    TargetResourceGroup = "rg-vnet-hub-spoke-prod"

    # Restore mode: SingleLabel | AllLabelsInFolder
    RestoreMode = "SingleLabel"

    # Backup folder path: <appconfig>/<timestamp>
    BackupFolderPath = "test-aue-appconfig/20260208-230150"

    # Used only if RestoreMode = SingleLabel
    LabelToRestore = "prod"
}

$SubscriptionId = ""

#------------------------------------------------------------
# Authenticate
#------------------------------------------------------------
Write-Output "Authenticating to Azure..."
Connect-AzAccount | Out-Null

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$context = Get-AzContext
Write-Output "Running as: $($context.Account.Id)"
Write-Output "Target App Configuration: $($Config.TargetAppConfigName)"

#------------------------------------------------------------
# Storage context
#------------------------------------------------------------
$storageAccount = Get-AzStorageAccount `
    -Name $Config.StorageAccountName `
    -ResourceGroupName (Get-AzStorageAccount |
        Where-Object { $_.StorageAccountName -eq $Config.StorageAccountName }
        ).ResourceGroupName

$storageCtx = $storageAccount.Context

#------------------------------------------------------------
# Validate App Configuration exists
#------------------------------------------------------------
Write-Output "Validating target App Configuration..."

$store = Get-AzAppConfigurationStore `
    -Name $Config.TargetAppConfigName `
    -ResourceGroupName $Config.TargetResourceGroup `
    -ErrorAction Stop

$endpoint = $store.Endpoint

#------------------------------------------------------------
# Locate backup blobs
#------------------------------------------------------------
Write-Output "Locating backup blobs..."

$blobs = Get-AzStorageBlob `
    -Context $storageCtx `
    -Container $Config.ContainerName `
    | Where-Object {
        $_.Name -like "$($Config.BackupFolderPath)/*/appconfig.json"
    }

if (-not $blobs) {
    throw "No backup blobs found at path $($Config.BackupFolderPath)"
}

#------------------------------------------------------------
# Restore logic
#------------------------------------------------------------
foreach ($blob in $blobs) {

    $label = ($blob.Name -split "/")[-2]

    if ($Config.RestoreMode -eq "SingleLabel" -and
        $label -ne $Config.LabelToRestore) {
        continue
    }

    Write-Output "Restoring label [$label] from blob [$($blob.Name)]"

    $tempFile = Join-Path `
        $env:TEMP `
        ([System.IO.Path]::GetRandomFileName() + ".json")

    # Download backup
    Get-AzStorageBlobContent `
        -Context $storageCtx `
        -Container $Config.ContainerName `
        -Blob $blob.Name `
        -Destination $tempFile `
        -Force | Out-Null

    $items = Get-Content $tempFile -Raw | ConvertFrom-Json

    foreach ($item in $items) {

        $params = @{
            Endpoint = $endpoint
            Key      = $item.Key
            Value    = $item.Value
        }

        if ($item.Label) {
            $params.Label = $item.Label
        }

        if ($item.ContentType) {
            $params.ContentType = $item.ContentType
        }

        if ($item.Tags) {
            $params.Tags = $item.Tags
        }

        Set-AzAppConfigurationKeyValue @params | Out-Null
    }

    Remove-Item $tempFile -Force
}

#------------------------------------------------------------
# Completion
#------------------------------------------------------------
Write-Output "=============================================="
Write-Output "App Configuration restoration completed"
Write-Output "Verify restored keys and labels"
Write-Output "=============================================="
