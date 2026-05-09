# ============================================================================
# ReportStorage.ps1 - Provision & Upload Reports to Azure Storage
# ============================================================================
# Creates a Storage Account (Table + Blob) in the customer-specified RG for
# persisting test reports independently of AMS lifecycle.
# ============================================================================

function Initialize-ReportStorage {
    <#
    .SYNOPSIS
        Ensures Storage Account, Blob Container, and Table exist for report persistence.
    .PARAMETER Config
        The full config hashtable (must contain 'report_storage' section).
    .RETURNS
        Hashtable with StorageAccountName, ResourceGroup, ContainerName, TableName, Context.
    #>
    param([hashtable]$Config)

    $reportCfg = $Config['report_storage']
    $subscriptionId = $Config['subscription_id']
    $location = $Config['location']

    # Determine RG - fallback to main resource_group if not specified
    $rg = if ($reportCfg -and $reportCfg['resource_group'] -and $reportCfg['resource_group'] -ne '') {
        $reportCfg['resource_group']
    } else {
        $Config['resource_group']
    }

    # Determine storage account name - auto-generate if empty
    $saName = if ($reportCfg -and $reportCfg['storage_account_name'] -and $reportCfg['storage_account_name'] -ne '') {
        $reportCfg['storage_account_name']
    } else {
        # Generate deterministic name from RG (lowercase, alphanumeric, max 24 chars)
        $seed = ($rg + $subscriptionId).GetHashCode().ToString().Replace('-','')
        $base = "haclusterrpt"
        "$base$($seed.Substring(0, [Math]::Min(12, $seed.Length)))".ToLower() -replace '[^a-z0-9]',''
    }
    # Enforce Azure storage naming: 3-24 chars, lowercase alphanumeric
    $saName = $saName.Substring(0, [Math]::Min(24, $saName.Length))

    $containerName = if ($reportCfg -and $reportCfg['container_name']) { $reportCfg['container_name'] } else { 'ha-test-reports' }
    $tableName = if ($reportCfg -and $reportCfg['table_name']) { $reportCfg['table_name'] } else { 'HaClusterTestRuns' }

    Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Ensuring report storage: RG=$rg, SA=$saName"

    # Ensure RG exists
    $existingRg = Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue
    if (-not $existingRg) {
        Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Creating resource group: $rg in $location"
        New-AzResourceGroup -Name $rg -Location $location | Out-Null
    }

    # Ensure Storage Account exists
    $sa = Get-AzStorageAccount -ResourceGroupName $rg -Name $saName -ErrorAction SilentlyContinue
    if (-not $sa) {
        Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Creating storage account: $saName"
        $sa = New-AzStorageAccount -ResourceGroupName $rg -Name $saName -Location $location `
            -SkuName 'Standard_LRS' -Kind 'StorageV2' -MinimumTlsVersion 'TLS1_2' `
            -AllowBlobPublicAccess $false
    }

    $ctx = $sa.Context

    # Ensure Blob Container exists
    $existingContainer = Get-AzStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $existingContainer) {
        Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Creating blob container: $containerName"
        New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off | Out-Null
    }

    # Ensure Table exists
    $existingTable = Get-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $existingTable) {
        Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Creating table: $tableName"
        New-AzStorageTable -Name $tableName -Context $ctx | Out-Null
    }

    Write-PhaseLog -Phase 'ReportStorage' -Level 'SUCCESS' -Message "Report storage ready: $saName/$containerName + $tableName"

    return @{
        StorageAccountName = $saName
        ResourceGroup      = $rg
        ContainerName      = $containerName
        TableName          = $tableName
        Context            = $ctx
    }
}

function Save-TestRunMetadata {
    <#
    .SYNOPSIS
        Saves a test run summary row to Azure Table Storage.
    .PARAMETER StorageInfo
        Output of Initialize-ReportStorage.
    .PARAMETER RunData
        Hashtable with run metadata: RunId, Timestamp, SID, ClusterName, OS, OverallStatus,
        PhasesRun, PassCount, FailCount, ReportBlobUrl, Duration.
    #>
    param(
        [hashtable]$StorageInfo,
        [hashtable]$RunData
    )

    $table = (Get-AzStorageTable -Name $StorageInfo.TableName -Context $StorageInfo.Context).CloudTable

    $partitionKey = $RunData['SID'] ?? 'UNKNOWN'
    $rowKey = $RunData['RunId'] ?? (Get-Date -Format 'yyyyMMdd_HHmmss')

    $properties = @{
        Timestamp      = $RunData['Timestamp'] ?? (Get-Date -Format 'o')
        ClusterName    = $RunData['ClusterName'] ?? ''
        OS             = $RunData['OS'] ?? ''
        OverallStatus  = $RunData['OverallStatus'] ?? ''
        PhasesRun      = [int]($RunData['PhasesRun'] ?? 0)
        PassCount      = [int]($RunData['PassCount'] ?? 0)
        FailCount      = [int]($RunData['FailCount'] ?? 0)
        ReportBlobUrl  = $RunData['ReportBlobUrl'] ?? ''
        DurationSec    = [int]($RunData['DurationSec'] ?? 0)
    }

    Add-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $rowKey -property $properties | Out-Null
    Write-PhaseLog -Phase 'ReportStorage' -Level 'SUCCESS' -Message "Run metadata saved: $partitionKey/$rowKey"
}

function Upload-TestReport {
    <#
    .SYNOPSIS
        Uploads the HTML report file to Blob Storage and returns the blob URL.
    .PARAMETER StorageInfo
        Output of Initialize-ReportStorage.
    .PARAMETER ReportFilePath
        Local path to the generated HTML report file.
    .RETURNS
        The blob URL (with SAS token for team access).
    #>
    param(
        [hashtable]$StorageInfo,
        [string]$ReportFilePath
    )

    $blobName = Split-Path $ReportFilePath -Leaf

    Write-PhaseLog -Phase 'ReportStorage' -Level 'INFO' -Message "Uploading report: $blobName"

    Set-AzStorageBlobContent -File $ReportFilePath -Container $StorageInfo.ContainerName `
        -Blob $blobName -Context $StorageInfo.Context -Force | Out-Null

    # Generate SAS token valid for 365 days (team access)
    $sasToken = New-AzStorageBlobSASToken -Container $StorageInfo.ContainerName `
        -Blob $blobName -Context $StorageInfo.Context `
        -Permission 'r' -ExpiryTime (Get-Date).AddDays(365)

    $blobUrl = "$($StorageInfo.Context.BlobEndPoint)$($StorageInfo.ContainerName)/$blobName$sasToken"

    Write-PhaseLog -Phase 'ReportStorage' -Level 'SUCCESS' -Message "Report uploaded: $blobUrl"
    return $blobUrl
}

function Get-TestRunHistory {
    <#
    .SYNOPSIS
        Retrieves all historical test runs from Table Storage (for dashboard display).
    .PARAMETER StorageInfo
        Output of Initialize-ReportStorage.
    .PARAMETER SID
        Optional - filter by SAP SID. If empty, returns all.
    .RETURNS
        Array of run metadata objects.
    #>
    param(
        [hashtable]$StorageInfo,
        [string]$SID = ''
    )

    $table = (Get-AzStorageTable -Name $StorageInfo.TableName -Context $StorageInfo.Context).CloudTable

    if ($SID -and $SID -ne '') {
        $runs = Get-AzTableRow -Table $table -PartitionKey $SID
    } else {
        $runs = Get-AzTableRow -Table $table
    }

    return $runs | Sort-Object Timestamp -Descending
}
