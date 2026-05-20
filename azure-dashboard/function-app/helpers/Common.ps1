# ============================================================================
# Common.ps1 - Shared helper functions for HA Cluster E2E Test Automation
# ============================================================================

#Requires -Modules Az.Accounts

$script:LogEntries = [System.Collections.ArrayList]::new()
$script:PhaseResults = [System.Collections.ArrayList]::new()

# --- YAML Helpers ---
function ConvertTo-YamlValue {
    param([string]$Raw)
    $Raw = $Raw.Trim()
    if ($Raw -match '^"([^"]*)"') { return $Matches[1] }
    if ($Raw -match "^'([^']*)'")  { return $Matches[1] }
    # Strip inline comments
    $Raw = ($Raw -replace '\s*#.*$', '').Trim().Trim('"').Trim("'")
    if ($Raw -eq 'true')  { return $true }
    if ($Raw -eq 'false') { return $false }
    return $Raw
}

# --- Configuration ---
function Read-TestConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $config = @{}
    $currentSection  = $null   # current top-level section name
    $inList          = $false  # inside a YAML list (nodes)
    $currentListItem = $null   # hashtable for current list entry

    foreach ($line in Get-Content $ConfigPath) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        $trimmed = $line.TrimStart()
        $indent  = $line.Length - $trimmed.Length

        # ── Top-level (indent == 0) ──
        if ($indent -eq 0 -and $trimmed -match '^(\w[\w_]*)\s*:\s*(.*)$') {
            $key    = $Matches[1]
            $rawVal = $Matches[2].Trim()

            # Remove wrapping quotes / inline comments for emptiness check
            $cleanVal = ($rawVal -replace '\s*#.*$', '').Trim().Trim('"').Trim("'")

            if ($cleanVal -eq '') {
                # Section header — value-less key starts a dict or list
                if ($key -eq 'nodes') {
                    $config[$key] = [System.Collections.ArrayList]::new()
                    $inList = $true
                } else {
                    $config[$key] = @{}
                    $inList = $false
                }
                $currentSection  = $key
                $currentListItem = $null
            } else {
                # Plain scalar
                $config[$key] = ConvertTo-YamlValue $rawVal
                $currentSection  = $null
                $inList          = $false
                $currentListItem = $null
            }
            continue
        }

        # ── Indented content (inside a section) ──
        if ($indent -gt 0 -and $currentSection) {

            # List-item start:  "  - key: val"
            if ($inList -and $trimmed -match '^-\s+(\w[\w_]*)\s*:\s*(.*)$') {
                $currentListItem = @{}
                $currentListItem[$Matches[1]] = ConvertTo-YamlValue $Matches[2]
                [void]$config[$currentSection].Add($currentListItem)
                continue
            }

            # "    key: val"  — list continuation OR nested dict entry
            if ($trimmed -match '^(\w[\w_]*)\s*:\s*(.*)$') {
                $k = $Matches[1]
                $v = ConvertTo-YamlValue $Matches[2]

                if ($inList -and $currentListItem) {
                    $currentListItem[$k] = $v          # list-item field
                } elseif (-not $inList -and $config[$currentSection] -is [hashtable]) {
                    $config[$currentSection][$k] = $v  # nested dict field
                }
                continue
            }
        }
    }

    return $config
}

# --- Logging ---
function Write-PhaseLog {
    param(
        [string]$Phase,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO',
        [string]$Message
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = @{
        Timestamp = $timestamp
        Phase     = $Phase
        Level     = $Level
        Message   = $Message
    }
    [void]$script:LogEntries.Add($entry)

    # Live flush to dashboard table if orchestrator has set up the flush function
    if ($global:DashboardFlushEnabled) {
        try { Sync-PhaseLogs-ToDashboard } catch { }
    }

    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
    }
    Write-Host "[$timestamp] [$Phase] " -NoNewline
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Set-PhaseResult {
    param(
        [string]$Phase,
        [ValidateSet('Passed','Failed','Skipped','Running')]
        [string]$Status,
        [string]$Message = '',
        [int]$DurationSeconds = 0
    )

    $result = @{
        Phase           = $Phase
        Status          = $Status
        Message         = $Message
        DurationSeconds = $DurationSeconds
        Timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # Update existing or add new
    $existing = $script:PhaseResults | Where-Object { $_.Phase -eq $Phase }
    if ($existing) {
        $idx = $script:PhaseResults.IndexOf($existing)
        $script:PhaseResults[$idx] = $result
    } else {
        [void]$script:PhaseResults.Add($result)
    }
}

function Get-PhaseResults { return $script:PhaseResults }
function Get-LogEntries { return $script:LogEntries }

# --- LA Workspace Discovery ---
# Fetches the Log Analytics workspace customer ID (GUID) from the AMS Monitor
function Get-MonitorWorkspaceId {
    param(
        [string]$ResourceGroupName,
        [string]$MonitorName,
        [string]$PhaseName = 'Common'
    )

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Discovering LA workspace from AMS Monitor '$MonitorName'..."
    $monitor = Get-AzWorkloadsMonitor -ResourceGroupName $ResourceGroupName -Name $MonitorName -ErrorAction Stop
    $workspaceArmId = $monitor.LogAnalyticsWorkspaceArmId
    if (-not $workspaceArmId) {
        throw "AMS Monitor '$MonitorName' has no LogAnalyticsWorkspaceArmId"
    }

    if ($workspaceArmId -match '/resourcegroups/([^/]+)/providers/microsoft.operationalinsights/workspaces/([^/]+)') {
        $wsRg = $Matches[1]
        $wsName = $Matches[2]
        $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $wsRg -Name $wsName -ErrorAction Stop
        $customerId = $ws.CustomerId.ToString()
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "LA workspace: $wsName (ID: $customerId)"
        return $customerId
    } else {
        throw "Could not parse workspace ARM ID: $workspaceArmId"
    }
}

# --- Azure Context ---
function Confirm-AzureContext {
    param([string]$SubscriptionId)

    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-PhaseLog -Phase 'Setup' -Level 'INFO' -Message 'Not logged in to Azure. Running Connect-AzAccount...'
        Connect-AzAccount
        $ctx = Get-AzContext
    }

    if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
        Write-PhaseLog -Phase 'Setup' -Level 'INFO' -Message "Switching to subscription $SubscriptionId"
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    Write-PhaseLog -Phase 'Setup' -Level 'SUCCESS' -Message "Azure context: $($ctx.Account.Id) / $($ctx.Subscription.Name)"
}

# --- VM Execution ---
function Invoke-VMCommand {
    param(
        [hashtable]$Config,
        [hashtable]$Node,
        [string]$ScriptContent,
        [string]$Phase
    )

    # --- Resolve VM identity from vm_resource_id or legacy fields ---
    $vmResourceId = $Node['vm_resource_id']
    $crossSub = $false

    if ($vmResourceId -and $vmResourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)') {
        $vmSubId = $Matches[1]
        $vmRg    = $Matches[2]
        $vmName  = $Matches[3]
        # Determine if VM is in a different subscription than the test subscription
        $crossSub = ($vmSubId -ne $Config['subscription_id'])
        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Resolved VM from resource ID: $vmName (RG=$vmRg, Sub=$vmSubId, CrossSub=$crossSub)"
    } else {
        $vmName = $Node['vm_name'] ?? $Node['hostname']
        $vmRg   = $Node['vm_resource_group'] ?? $Config['resource_group']
    }

    $method = $Config['execution_method']

    if ($method -eq 'vm_run_command' -or $method -eq 'both') {
        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Executing via VM Run Command on $vmName..."
        
        # Check for existing managed run commands (informational only - do NOT delete them)
        try {
            $existingCmds = Get-AzVMRunCommand -ResourceGroupName $vmRg -VMName $vmName -ErrorAction SilentlyContinue
            $activeCmds = $existingCmds | Where-Object { $_.ProvisioningState -in @('Creating', 'Updating', 'Deleting') }
            if ($activeCmds -and $activeCmds.Count -gt 0) {
                $cmdNames = ($activeCmds | ForEach-Object { "$($_.Name)($($_.ProvisioningState))" }) -join ', '
                Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "VM $vmName has $($activeCmds.Count) active managed run commands: $cmdNames. Will retry if blocked."
            }
        } catch {
            Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Could not check existing run commands: $_"
        }
        
        # Switch Azure context if VM is in a different subscription
        $originalContext = $null
        if ($crossSub) {
            try {
                $originalContext = Get-AzContext
                Set-AzContext -Subscription $vmSubId -ErrorAction Stop | Out-Null
                Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Switched context to VM subscription: $vmSubId"
            } catch {
                Write-PhaseLog -Phase $Phase -Level 'ERROR' -Message "Failed to switch to VM subscription $vmSubId`: $_"
                return @{ Success = $false; Output = ''; Error = "Cannot switch to VM subscription: $_"; Method = 'vm_run_command' }
            }
        }

        # Retry loop for 409 Conflict (other run commands in progress)
        $maxRetries = 10
        $retryDelay = 45  # seconds (total wait: up to ~7.5 min)
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                $result = Invoke-AzVMRunCommand -ResourceGroupName $vmRg -VMName $vmName `
                    -CommandId 'RunShellScript' -ScriptString $ScriptContent `
                    -ErrorAction Stop
                
                # Extract output - handle BOTH Az.Compute SDK formats:
                # Old: ComponentStatus/StdOut/succeeded + ComponentStatus/StdErr/succeeded
                # New (7.x): ProvisioningState/succeeded (single value with all output)
                $stdout = ''
                $stderr = ''
                $allOutput = ''
                
                if ($result.Value) {
                    foreach ($v in $result.Value) {
                        if ($v.Code -like '*StdOut*') { 
                            $stdout = $v.Message 
                        }
                        elseif ($v.Code -like '*StdErr*') { 
                            $stderr = $v.Message 
                        }
                        else {
                            # New SDK format - output is in any succeeded value
                            if ($v.Message) { $allOutput += $v.Message }
                        }
                    }
                }
                
                # If StdOut was empty but we got output from new format, use that
                if (-not $stdout -and $allOutput) {
                    $stdout = $allOutput
                    Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Using output from new SDK format ($($allOutput.Length) chars)"
                }
                
                # Also check $result.Output (some SDK versions use this)
                if (-not $stdout -and $result.Output) {
                    $stdout = $result.Output
                }
                
                # Log output for diagnostics
                if ($stdout) {
                    $outPreview = if ($stdout.Length -gt 500) { $stdout.Substring($stdout.Length - 500) } else { $stdout }
                    Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "VM output from $vmName`: $outPreview"
                } else {
                    Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "VM output from $vmName was empty after all extraction attempts"
                    $rawInfo = ($result.Value | ForEach-Object { "Code=$($_.Code),MsgLen=$($_.Message.Length)" }) -join '; '
                    Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Raw result: $rawInfo"
                    # Last resort: treat entire result as text
                    $stdout = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
                    if ($stdout) {
                        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Extracted from all values: $stdout"
                    }
                }
                
                if ($stderr) {
                    $errPreview = if ($stderr.Length -gt 300) { $stderr.Substring(0, 300) } else { $stderr }
                    Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "StdErr from $vmName`: $errPreview"
                }
                # Restore original context before returning
                if ($crossSub -and $originalContext) {
                    Set-AzContext -Subscription $originalContext.Subscription.Id -ErrorAction SilentlyContinue | Out-Null
                }
                return @{ Success = $true; Output = $stdout; Error = $stderr; Method = 'vm_run_command' }
            }
            catch {
                $errMsg = $_.ToString()
                if ($errMsg -match '409|Conflict|in progress' -and $attempt -lt $maxRetries) {
                    Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "VM $vmName has a run command in progress. Waiting ${retryDelay}s before retry $attempt/$maxRetries..."
                    Start-Sleep -Seconds $retryDelay
                    continue
                }
                Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "VM Run Command failed on $vmName`: $errMsg"
                # Restore original context before returning
                if ($crossSub -and $originalContext) {
                    Set-AzContext -Subscription $originalContext.Subscription.Id -ErrorAction SilentlyContinue | Out-Null
                }
                if ($method -ne 'both') {
                    return @{ Success = $false; Output = ''; Error = $errMsg; Method = 'vm_run_command' }
                }
                break
            }
        }
    }

    if ($method -eq 'bastion' -or $method -eq 'both') {
        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Executing via Bastion SSH on $vmName..."
        $bastion = $Config['bastion']
        if (-not $bastion -or -not $bastion['name']) {
            Write-PhaseLog -Phase $Phase -Level 'ERROR' -Message "Bastion details not configured."
            return @{ Success = $false; Output = ''; Error = 'Bastion not configured'; Method = 'bastion' }
        }

        try {
            $bastionRg = if ($bastion['resource_group']) { $bastion['resource_group'] } 
                         else { $Config['cluster_vnet']['resource_group'] }
            
            # Use az network bastion ssh
            $keyPath = $bastion['private_key_path']
            $username = $bastion['ssh_username']
            $vmId = (Get-AzVM -ResourceGroupName $vmRg -Name $vmName).Id

            $output = az network bastion ssh --name $bastion['name'] `
                --resource-group $bastionRg --target-resource-id $vmId `
                --auth-type ssh-key --username $username --ssh-key $keyPath `
                --command $ScriptContent 2>&1

            return @{ Success = ($LASTEXITCODE -eq 0); Output = ($output -join "`n"); Error = ''; Method = 'bastion' }
        }
        catch {
            Write-PhaseLog -Phase $Phase -Level 'ERROR' -Message "Bastion SSH failed on $vmName`: $_"
            return @{ Success = $false; Output = ''; Error = $_.ToString(); Method = 'bastion' }
        }
    }

    return @{ Success = $false; Output = ''; Error = "No valid execution method configured"; Method = 'none' }
}

# --- Network Connectivity ---
function Test-SubnetConnectivity {
    param(
        [hashtable]$Config,
        [string]$Phase
    )

    # Check if AMS subnet can reach cluster node IPs (via NSG/route check)
    $amsVnetRg = if ($Config['vnet']['resource_group']) { $Config['vnet']['resource_group'] } else { $Config['resource_group'] }
    $clusterVnetRg = $Config['cluster_vnet']['resource_group']
    $amsVnetName = $Config['vnet']['name']
    $clusterVnetName = $Config['cluster_vnet']['name']

    if (-not $clusterVnetName -or -not $clusterVnetRg) {
        Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "Cluster VNet details not provided. Assuming same VNet or pre-peered."
        return $true
    }

    if ($amsVnetName -eq $clusterVnetName -and $amsVnetRg -eq $clusterVnetRg) {
        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "AMS and cluster are in the same VNet. No peering needed."
        return $true
    }

    # Check if peering already exists
    $peerings = Get-AzVirtualNetworkPeering -VirtualNetworkName $amsVnetName -ResourceGroupName $amsVnetRg -ErrorAction SilentlyContinue
    $existingPeering = $peerings | Where-Object { $_.RemoteVirtualNetwork.Id -match $clusterVnetName }
    
    if ($existingPeering -and $existingPeering.PeeringState -eq 'Connected') {
        Write-PhaseLog -Phase $Phase -Level 'SUCCESS' -Message "VNet peering already exists and is connected."
        return $true
    }

    return $false
}

function New-VNetPeering {
    param(
        [hashtable]$Config,
        [string]$Phase
    )

    $amsVnetRg = if ($Config['vnet']['resource_group']) { $Config['vnet']['resource_group'] } else { $Config['resource_group'] }
    $clusterVnetRg = $Config['cluster_vnet']['resource_group']
    $amsVnetName = $Config['vnet']['name']
    $clusterVnetName = $Config['cluster_vnet']['name']

    Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Creating VNet peering: $amsVnetName <-> $clusterVnetName"

    $amsVnet = Get-AzVirtualNetwork -Name $amsVnetName -ResourceGroupName $amsVnetRg
    $clusterVnet = Get-AzVirtualNetwork -Name $clusterVnetName -ResourceGroupName $clusterVnetRg

    # AMS -> Cluster
    Add-AzVirtualNetworkPeering -Name "ams-to-cluster" `
        -VirtualNetwork $amsVnet -RemoteVirtualNetworkId $clusterVnet.Id `
        -AllowForwardedTraffic | Out-Null

    # Cluster -> AMS
    Add-AzVirtualNetworkPeering -Name "cluster-to-ams" `
        -VirtualNetwork $clusterVnet -RemoteVirtualNetworkId $amsVnet.Id `
        -AllowForwardedTraffic | Out-Null

    Write-PhaseLog -Phase $Phase -Level 'SUCCESS' -Message "VNet peering created successfully."
}

# --- User Consent ---
function Request-UserConsent {
    param([string]$Action, [string]$Phase)

    # Auto-approve when running non-interactively (Azure Functions)
    if ($env:AZURE_FUNCTIONS_ENVIRONMENT -or $env:FUNCTIONS_WORKER_RUNTIME -or
        [Environment]::UserInteractive -eq $false) {
        Write-PhaseLog -Phase $Phase -Level 'INFO' -Message "Auto-approved (non-interactive): $Action"
        return $true
    }

    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "  CONSENT REQUIRED" -ForegroundColor Yellow
    Write-Host "  Action: $Action" -ForegroundColor White
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    $response = Read-Host "  Proceed? (Y/N)"
    Write-Host ""

    if ($response -notin @('Y','y','Yes','yes')) {
        Write-PhaseLog -Phase $Phase -Level 'WARN' -Message "User declined: $Action"
        return $false
    }
    return $true
}

# --- Export (only when loaded as a module) ---
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function *
}
