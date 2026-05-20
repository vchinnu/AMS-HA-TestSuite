# ============================================================================
# Phase2-SetupAMS.ps1 - Create AMS infrastructure (RG, VNet, Subnet, Monitor)
# ============================================================================
# Steps:
#   1. Create Resource Group (if not exists)
#   2. Create or use existing VNet
#   3. Create subnet with /28 CIDR, delegate to Microsoft.Web/serverFarms
#   4. Check connectivity to cluster VMs — create VNet peering if needed
#   5. Create AMS Monitor (New-AzWorkloadsMonitor)
# ============================================================================


$PhaseName = 'Phase2-SetupAMS'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')

function Invoke-Phase2 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Setting up AMS infrastructure...'

    $subscriptionId = $Config['subscription_id']
    $rgName = $Config['resource_group']
    $location = $Config['location']
    $vnetConfig = $Config['vnet']
    $subnetConfig = $Config['subnet']
    $monitorName = $Config['ams_monitor_name']
    $managedRg = if ($Config['managed_resource_group']) { $Config['managed_resource_group'] } else { "MRG_$monitorName" }

    # --- Step 1: Resource Group ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking resource group: $rgName"
    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating resource group: $rgName in $location"
        New-AzResourceGroup -Name $rgName -Location $location | Out-Null
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Resource group created: $rgName"
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Resource group already exists: $rgName"
    }

    # --- Step 2: VNet ---
    $vnetRg = if ($vnetConfig['resource_group']) { $vnetConfig['resource_group'] } else { $rgName }
    $vnetName = $vnetConfig['name']

    $vnet = $null
    $vnetError = $null
    try {
        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction Stop
    } catch {
        $vnetError = $_.Exception.Message
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "VNet lookup error: $vnetError"
    }

    if (-not $vnet -and $vnetConfig['create_new'] -eq $true) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating VNet: $vnetName ($($vnetConfig['address_space']))"
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg `
            -Location $location -AddressPrefix $vnetConfig['address_space']
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "VNet created: $vnetName"
    } elseif (-not $vnet) {
        $detail = if ($vnetError) { "Error: $vnetError" } else { "VNet not found and create_new=false" }
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "VNet '$vnetName' in RG '$vnetRg': $detail"
        # Log current subscription context for diagnostics
        $ctx = Get-AzContext
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Current context: Sub=$($ctx.Subscription.Id) ($($ctx.Subscription.Name)), Account=$($ctx.Account.Id)"
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "VNet not found: $detail" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
        return
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Using existing VNet: $vnetName"
    }

    # --- Step 3: Subnet with delegation ---
    $subnetName = $subnetConfig['name']
    $subnetCidr = $subnetConfig['cidr']
    
    $existingSubnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    if (-not $existingSubnet) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating subnet: $subnetName ($subnetCidr) with Microsoft.Web/serverFarms delegation"
        
        $delegation = New-AzDelegation -Name "ams-delegation" -ServiceName "Microsoft.Web/serverFarms"
        Add-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet `
            -AddressPrefix $subnetCidr -Delegation $delegation | Out-Null
        $vnet | Set-AzVirtualNetwork | Out-Null
        
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Subnet created with delegation: $subnetName"
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Subnet already exists: $subnetName"
        # Verify delegation
        if (-not ($existingSubnet.Delegations | Where-Object { $_.ServiceName -eq 'Microsoft.Web/serverFarms' })) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Subnet exists but missing Microsoft.Web/serverFarms delegation!"
        }
    }

    # Refresh VNet to get subnet ID
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    $subnetId = $subnet.Id

    # --- Step 4: Connectivity check + VNet peering ---
    $isConnected = Test-SubnetConnectivity -Config $Config -Phase $PhaseName
    if (-not $isConnected) {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "AMS subnet cannot reach cluster VMs. VNet peering required."
        
        $consentGranted = Request-UserConsent -Action "Create VNet peering between AMS VNet ($vnetName) and cluster VNet ($($Config['cluster_vnet']['name']))" -Phase $PhaseName
        if ($consentGranted) {
            try {
                New-VNetPeering -Config $Config -Phase $PhaseName
            }
            catch {
                Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "VNet peering failed: $_"
                Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "VNet peering failed" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
                return
            }
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "User declined VNet peering. Continuing without — provider creation may fail."
        }
    }

    # --- Step 5: Create AMS Monitor ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking AMS monitor: $monitorName"
    $existingMonitor = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $monitorName -ErrorAction SilentlyContinue
    
    if (-not $existingMonitor) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating AMS monitor: $monitorName"
        
        $consentGranted = Request-UserConsent -Action "Create AMS Monitor '$monitorName' in RG '$rgName'" -Phase $PhaseName
        if (-not $consentGranted) {
            Set-PhaseResult -Phase $PhaseName -Status 'Skipped' -Message 'User declined AMS Monitor creation'
            return
        }

        try {
            New-AzWorkloadsMonitor -Name $monitorName -ResourceGroupName $rgName `
                -SubscriptionId $subscriptionId -Location $location -AppLocation $location `
                -ManagedResourceGroupName $managedRg -MonitorSubnet $subnetId `
                -RoutingPreference 'RouteAll' | Out-Null
            
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "AMS Monitor created: $monitorName"
        }
        catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "AMS Monitor creation failed: $_"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Monitor creation failed: $_" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "AMS Monitor already exists: $monitorName (state: $($existingMonitor.ProvisioningState))"
    }

    # Wait for monitor provisioning
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Waiting for monitor provisioning..."
    $maxWait = 300  # 5 min
    $elapsed = 0
    while ($elapsed -lt $maxWait) {
        $monitor = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $monitorName
        if ($monitor.ProvisioningState -eq 'Succeeded') {
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "AMS Monitor provisioned successfully"
            break
        } elseif ($monitor.ProvisioningState -eq 'Failed') {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "AMS Monitor provisioning failed"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Monitor provisioning failed" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }
        Start-Sleep -Seconds 15
        $elapsed += 15
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "AMS infrastructure ready (RG + VNet + Subnet + Monitor)" -DurationSeconds $duration
}

# Execute only when script is run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.' -and $Config) {
    Invoke-Phase2 -Config $Config
}
