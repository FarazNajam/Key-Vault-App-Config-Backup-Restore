#requires -Modules Az.Accounts, Az.AppConfiguration, Az.Storage
$ErrorActionPreference = "Stop"

param (
    [Parameter(Mandatory)]
    [string]$AppConfigName,

    [Parameter(Mandatory)]
    [string]$AppConfigResourceGroup,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$StorageResourceGroup,

    [Parameter(Mandatory)]
    [string]$ContainerName,

    # Optional but recommended in multi-sub environments
    [string]$SubscriptionId
)

Write-Output "=== App Configuration Snapshot Backup Started ==="

#------------------------------------------------------------
# Timestamp (UTC)
#------------------------------------------------------------
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")

#------------------------------------------------------------
# Authenticate (interactive user)
#------------------------------------------------------------
Write-Output "Authenticating to Azure..."
Connect-AzAccount | Out-Null

if ($SubscriptionId) {
    Write-Output "Setting subscription context: $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    az account set --subscription $SubscriptionId
}

az login --only-show-errors | Out-Null
Write-Output "Authenticated using logged-in user"

#------------------------------------------------------------
# Validate resources
#------------------------------------------------------------
Get-AzAppConfigurationStore `
    -Name $AppConfigName `
    -ResourceGroupName $AppConfigResourceGroup | Out-Null

Get-AzStorageAccount `
    -Name $StorageAccountName `
    -ResourceGroupName $StorageResourceGroup | Out-Null

$ctx = New-AzStorageContext `
    -StorageAccountName $StorageAccountName `
    -UseConnectedAccount

Write-Output "Validated App Configuration and Storage Account"

#------------------------------------------------------------
# Temp directory
#------------------------------------------------------------
$tempDir = $env:TEMP

#------------------------------------------------------------
# STAGE 1 – Discover labels
#------------------------------------------------------------
Write-Output "Stage 1: Discovering labels"

$labelsRaw = az appconfig kv list `
    --name $AppConfigName `
    --auth-mode login `
    --query "[].label" `
    -o json | ConvertFrom-Json

$labels = @("nolabel")
$labels += ($labelsRaw | Where-Object { $_ } | Sort-Object -Unique)

Write-Output "Labels discovered: $($labels -join ', ')"

#------------------------------------------------------------
# STAGE 2 – Create snapshots
#------------------------------------------------------------
$snapshots = @()

foreach ($label in $labels) {

    $snapshotName = "backup-$label-$timestamp"
    $filtersFile  = Join-Path $tempDir "filters-$label.json"

    Write-Output "Creating snapshot [$snapshotName]"

    if ($label -eq "nolabel") {
@'
{
  "key": "*"
}
'@ | Out-File $filtersFile -Encoding utf8
    }
    else {
@"
{
  "key": "*",
  "label": "$label"
}
"@ | Out-File $filtersFile -Encoding utf8
    }

    az appconfig snapshot create `
        --name $AppConfigName `
        --snapshot $snapshotName `
        --filters @$filtersFile `
        --auth-mode login | Out-Null

    $snapshots += [PSCustomObject]@{
        Label = $label
        Name  = $snapshotName
    }
}

Write-Output "Stage 2 complete: Snapshot creation requested"

#------------------------------------------------------------
# STAGE 3 – Wait for snapshot readiness
#------------------------------------------------------------
Write-Output "Stage 3: Waiting for snapshot readiness"

foreach ($snap in $snapshots) {

    $ready   = $false
    $attempt = 0

    while (-not $ready -and $attempt -lt 10) {
        Start-Sleep -Seconds 5
        $attempt++

        Write-Output "Checking snapshot [$($snap.Name)] (attempt $attempt)"

        $exists = az appconfig snapshot show `
            --name $AppConfigName `
            --snapshot $snap.Name `
            --auth-mode login `
            --query "name" `
            -o tsv 2>$null

        if ($exists) { $ready = $true }
    }

    if (-not $ready) {
        throw "Snapshot not ready after retries: $($snap.Name)"
    }

    Write-Output "Snapshot ready: $($snap.Name)"
}

#------------------------------------------------------------
# STAGE 4 – Export snapshots & upload to storage
#------------------------------------------------------------
foreach ($snap in $snapshots) {

    $exportFile = Join-Path $tempDir "appconfig-$($snap.Name).json"
    $blobName   = "$AppConfigName/$timestamp/$($snap.Label)/appconfig.json"

    Write-Output "Exporting snapshot [$($snap.Name)]"

    $exported = $false
    $attempt  = 0

    while (-not $exported -and $attempt -lt 6) {
        $attempt++
        Write-Output "Export attempt $attempt"

        if (Test-Path $exportFile) {
            Remove-Item $exportFile -Force
        }

        az appconfig kv export `
            --name $AppConfigName `
            --snapshot $snap.Name `
            --destination file `
            --path $exportFile `
            --format json `
            --auth-mode login `
            --yes | Out-Null

        if (Test-Path $exportFile) {
            $exported = $true
        }
        else {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $exported) {
        throw "Export failed after retries for snapshot $($snap.Name)"
    }

    Set-AzStorageBlobContent `
        -File $exportFile `
        -Container $ContainerName `
        -Blob $blobName `
        -Context $ctx `
        -Force | Out-Null

    Remove-Item $exportFile -Force
    Write-Output "Uploaded: $blobName"
}

Write-Output "=== App Configuration Snapshot Backup Completed Successfully ==="
