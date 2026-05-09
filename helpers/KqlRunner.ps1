# ============================================================================
# KqlRunner.ps1 - Execute KQL queries against Log Analytics workspace
# ============================================================================

function Invoke-KqlQuery {
    param(
        [string]$WorkspaceId,
        [string]$Query,
        [string]$Timespan = 'PT1H',
        [string]$Phase = 'KQL'
    )

    try {
        # Convert ISO 8601 duration (PT1H, PT2H, P1D etc.) to .NET TimeSpan
        $ts = switch -Regex ($Timespan) {
            '^PT(\d+)M$' { New-TimeSpan -Minutes ([int]$Matches[1]) }
            '^PT(\d+)H$' { New-TimeSpan -Hours ([int]$Matches[1]) }
            '^P(\d+)D$'  { New-TimeSpan -Days ([int]$Matches[1]) }
            default       { New-TimeSpan -Hours 1 }
        }
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -Timespan $ts -ErrorAction Stop
        
        if ($result.Results) {
            Write-PhaseLog -Phase $Phase -Level 'SUCCESS' -Message "KQL returned $($result.Results.Count) rows"
            return @{ Success = $true; Results = $result.Results; Count = $result.Results.Count }
        } else {
            Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "KQL returned 0 rows"
            return @{ Success = $true; Results = @(); Count = 0 }
        }
    }
    catch {
        Write-PhaseLog -Phase $Phase -Level 'ERROR' -Message "KQL query failed: $_"
        return @{ Success = $false; Results = @(); Count = 0; Error = $_.ToString() }
    }
}

function Invoke-KqlFromFile {
    param(
        [string]$WorkspaceId,
        [string]$KqlFilePath,
        [hashtable]$Parameters = @{},
        [string]$Timespan = 'PT1H',
        [string]$Phase = 'KQL'
    )

    if (-not (Test-Path $KqlFilePath)) {
        Write-PhaseLog -Phase $Phase -Level 'ERROR' -Message "KQL file not found: $KqlFilePath"
        return @{ Success = $false; Results = @(); Count = 0 }
    }

    $query = Get-Content $KqlFilePath -Raw

    # Replace parameters like {{SID}}, {{CLUSTER_NAME}}
    foreach ($key in $Parameters.Keys) {
        $query = $query -replace "\{\{$key\}\}", $Parameters[$key]
    }

    return Invoke-KqlQuery -WorkspaceId $WorkspaceId -Query $query -Timespan $Timespan -Phase $Phase
}

if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function *
}
