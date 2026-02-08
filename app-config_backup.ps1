#requires -Modules Az.Accounts, Az.AppConfiguration, Az.Storage

$ErrorActionPreference = "Stop"

Write-Output "=== App Configuration Backup Started (No Snapshots) ==="

#------------------------------------------------------------
# CONFIGURATION
#------------------------------------------------------------

$AppConfigs = @(
    @{
        Name          = "test-aue-appconfig"
        ResourceGroup = "rg-vnet-hub-spoke-prod"
    }
)

$Storage = @{
    AccountName   = "tststrgaccnthldr03"
    ResourceGroup = "TestStorageAccountTHlDr"
    ContainerName = "appconfig-backups"
}

$SubscriptionId = ""

#------------------------------------------------------------
# Timestamp (UTC)
#------------------------------------------------------------
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")

#------------------------------------------------------------
# Authenticate
#------------------------------------------------------------
Write-Output "Authenticating to Azure..."
Connect-AzAccount | Out-Null

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Output "Authenticated successfully"

#------------------------------------------------------------
# Storage context
#------------------------------------------------------------
$StorageAccount = Get-AzStorageAccount `
    -Name $Storage.AccountName `
    -ResourceGroupName $Storage.ResourceGroup

$Ctx = $StorageAccount.Context

Write-Output "Validated storage account"

#------------------------------------------------------------
# PROCESS APP CONFIG
#------------------------------------------------------------
foreach ($AppConfig in $AppConfigs) {

    $Name = $AppConfig.Name
    $RG   = $AppConfig.ResourceGroup

    Write-Output ""
    Write-Output "=== Processing App Configuration: $Name ==="

    $Store = Get-AzAppConfigurationStore -Name $Name -ResourceGroupName $RG

    #--------------------------------------------------------
    # Discover labels
    #--------------------------------------------------------
    Write-Output "Discovering labels..."

    $KeyValues = Get-AzAppConfigurationKeyValue -Endpoint $Store.Endpoint

    $Labels = @("nolabel")
    $Labels += $KeyValues.Label |
        Where-Object { $_ } |
        Sort-Object -Unique

    Write-Output "Labels discovered: $($Labels -join ', ')"

    #--------------------------------------------------------
    # Export per label
    #--------------------------------------------------------
    foreach ($Label in $Labels) {

        Write-Output "Exporting label [$Label]"

        if ($Label -eq "nolabel") {
            $Export = $KeyValues | Where-Object { -not $_.Label }
        }
        else {
            $Export = $KeyValues | Where-Object { $_.Label -eq $Label }
        }

        $ExportFile = Join-Path $env:TEMP "appconfig-$Name-$Label-$Timestamp.json"
        $BlobName   = "$Name/$Timestamp/$Label/appconfig.json"

        $Export |
            Select-Object Key, Value, Label, ContentType, Tags |
            ConvertTo-Json -Depth 10 |
            Out-File $ExportFile -Encoding utf8

        Set-AzStorageBlobContent `
            -File $ExportFile `
            -Container $Storage.ContainerName `
            -Blob $BlobName `
            -Context $Ctx `
            -Force | Out-Null

        Remove-Item $ExportFile -Force
        Write-Output "Uploaded: $BlobName"
    }
}

Write-Output ""
Write-Output "=== App Configuration Backup Completed Successfully ==="
