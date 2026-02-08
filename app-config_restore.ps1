$ErrorActionPreference = "Stop"

Write-Output "=== App Configuration Restore Started ==="

#------------------------------------------------------------
# Configuration (explicit – no guessing)
#------------------------------------------------------------
$Config = @{
    AppConfigName  = "my-appconfig-prod"
    ResourceGroup  = "rg-appconfig-prod"

    StorageAccountName = "tststrgaccnthldr03"
    ContainerName      = "appconfig-backups"

    # EXACT backup timestamp folder to restore from
    BackupTimestamp = "20260209-001931"

    # Restore mode: Full | LabelsOnly
    RestoreMode = "Full"

    # Used only if RestoreMode = LabelsOnly
    LabelsToRestore = @("prod", "nolabel")
}

#------------------------------------------------------------
# Authenticate (Managed Identity)
#------------------------------------------------------------
Connect-AzAccount -Identity | Out-Null
az login --identity | Out-Null

Write-Output "Authenticated using Managed Identity"

#------------------------------------------------------------
# Validate App Configuration exists
#------------------------------------------------------------
Get-AzAppConfigurationStore `
    -Name $Config.AppConfigName `
    -ResourceGroupName $Config.ResourceGroup | Out-Null

#------------------------------------------------------------
# Storage context
#------------------------------------------------------------
$ctx = New-AzStorageContext `
    -StorageAccountName $Config.StorageAccountName `
    -UseConnectedAccount

$tempDir = $env:TEMP

#------------------------------------------------------------
# Locate backup blobs
#------------------------------------------------------------
Write-Output "Locating backup files..."

$blobs = Get-AzStorageBlob `
    -Container $Config.ContainerName `
    -Context $ctx `
    | Where-Object {
        $_.Name -like "$($Config.AppConfigName)/$($Config.BackupTimestamp)/*/appconfig.json"
    }

if (-not $blobs) {
    throw "No backup files found for timestamp $($Config.BackupTimestamp)"
}

#------------------------------------------------------------
# Restore loop
#------------------------------------------------------------
foreach ($blob in $blobs) {

    # Extract label from path
    $label = ($blob.Name -split "/")[-2]

    if ($Config.RestoreMode -eq "LabelsOnly" -and
        $label -notin $Config.LabelsToRestore) {
        Write-Output "Skipping label [$label]"
        continue
    }

    Write-Output "Restoring label [$label]"

    $localFile = Join-Path $tempDir "restore-$label.json"

    Get-AzStorageBlobContent `
        -Container $Config.ContainerName `
        -Blob $blob.Name `
        -Destination $localFile `
        -Context $ctx `
        -Force | Out-Null

    az appconfig kv import `
        --name $Config.AppConfigName `
        --source file `
        --path $localFile `
        --format json `
        --auth-mode login `
        --yes

    Remove-Item $localFile -Force
}

Write-Output "=== App Configuration Restore Completed Successfully ==="
