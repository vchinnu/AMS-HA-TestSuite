# ============================================================================
# Phase2-SetupAMS.ps1 - Create AMS infrastructure (RG, VNet, Subnet, Monitor)
# ============================================================================
# Architecture:
#   - VNet + Subnet are ALWAYS created in the AMS subscription (where monitor lives)
#   - vnet_resource_id = source VM VNet (peering target, NOT where subnet goes)
#   - VNet peering connects AMS VNet <-> source VM VNet for connectivity
#   - Subnet uses minimum /28 CIDR with auto-calculated non-overlapping range
# Steps:
#   1. Create Resource Group (if not exists) in AMS subscription
#   2. Create VNet in AMS subscription with non-overlapping address space
#   3. Create delegated subnet (/28) in AMS VNet
#   4. Establish VNet peering between AMS VNet and source VM VNet
#   5. Create AMS Monitor with AMS subnet
# ============================================================================


$PhaseName = 'Phase2-SetupAMS'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')

function Get-NonOverlappingCidr {
    param(
        [string[]]$ExistingAddressSpaces,
        [int]$PrefixLength = 28
    )
    # Find a /28 (or specified prefix) that doesn't overlap with any existing address spaces
    # Candidates: cycle through 10.250.x.0/28, 172.16.250.x/28, 192.168.250.x/28
    $blockSize = [math]::Pow(2, 32 - $PrefixLength)

    # Parse existing ranges into start/end integers
    $existingRanges = @()
    foreach ($space in $ExistingAddressSpaces) {
        if ($space -match '^([^/]+)/(\d+)$') {
            $ip = [System.Net.IPAddress]::Parse($Matches[1])
            $prefix = [int]$Matches[2]
            $bytes = $ip.GetAddressBytes(); [Array]::Reverse($bytes)
            $start = [BitConverter]::ToUInt32($bytes, 0)
            $end = $start + [math]::Pow(2, 32 - $prefix) - 1
            $existingRanges += @{ Start = $start; End = $end }
        }
    }

    # Try candidates in 10.250.0.0/24 range first, then 172.16.250.0/24, then 192.168.250.0/24
    $candidateBases = @('10.250.0.0', '10.251.0.0', '10.252.0.0', '172.16.250.0', '172.16.251.0', '192.168.250.0', '192.168.251.0')
    
    foreach ($base in $candidateBases) {
        $baseIp = [System.Net.IPAddress]::Parse($base)
        $baseBytes = $baseIp.GetAddressBytes(); [Array]::Reverse($baseBytes)
        $baseInt = [BitConverter]::ToUInt32($baseBytes, 0)

        # Try 16 blocks within each /24 base (for /28 = 16 IPs each)
        for ($i = 0; $i -lt 16; $i++) {
            $candidateStart = $baseInt + ($i * $blockSize)
            $candidateEnd = $candidateStart + $blockSize - 1

            $overlaps = $false
            foreach ($range in $existingRanges) {
                if ($candidateStart -le $range.End -and $candidateEnd -ge $range.Start) {
                    $overlaps = $true; break
                }
            }
            if (-not $overlaps) {
                $resultBytes = [BitConverter]::GetBytes([uint32]$candidateStart); [Array]::Reverse($resultBytes)
                $resultIp = [System.Net.IPAddress]::new($resultBytes)
                return "$($resultIp.ToString())/$PrefixLength"
            }
        }
    }
    return $null
}

function Invoke-Phase2 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Setting up AMS infrastructure...'

    $subscriptionId = $Config['subscription_id']   # AMS subscription
    $rgName = $Config['resource_group']             # AMS resource group
    $location = $Config['location']
    $subnetConfig = $Config['subnet']
    $monitorName = $Config['ams_monitor_name']
    $sourceVnetResourceId = $Config['vnet_resource_id']  # Source VM VNet (peering target)

    # --- Parse source VNet details early (needed for reuse check) ---
    $sourceVnetSubId = $null
    $sourceVnetRg = $null
    $sourceVnetName = $null
    if ($sourceVnetResourceId -and $sourceVnetResourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Network/virtualNetworks/([^/]+)') {
        $sourceVnetSubId = $Matches[1]
        $sourceVnetRg = $Matches[2]
        $sourceVnetName = $Matches[3]
    }

    # --- Reuse existing monitor if healthy; only create new if missing/failed ---
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
    $existingMonitor = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $monitorName -ErrorAction SilentlyContinue
    if ($existingMonitor -and $existingMonitor.ProvisioningState -eq 'Succeeded') {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Existing AMS Monitor found: $monitorName (Succeeded). Reusing existing infrastructure."

        # Verify VNet and peering are intact — search ALL VNets in the RG for one peered to source
        $allVnets = Get-AzVirtualNetwork -ResourceGroupName $rgName -ErrorAction SilentlyContinue
        $existingVnet = $null
        $existingPeering = $null
        foreach ($vnet in $allVnets) {
            $peerings = Get-AzVirtualNetworkPeering -VirtualNetworkName $vnet.Name -ResourceGroupName $rgName -ErrorAction SilentlyContinue
            $matchingPeering = $peerings | Where-Object { $_.RemoteVirtualNetwork.Id -match [regex]::Escape($sourceVnetName) -and $_.PeeringState -eq 'Connected' }
            if ($matchingPeering) {
                $existingVnet = $vnet
                $existingPeering = $matchingPeering
                break
            }
        }

        if ($existingVnet -and $existingPeering) {
            $amsVnetName = $existingVnet.Name
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Existing VNet ($amsVnetName) and peering to $sourceVnetName are healthy. Skipping infrastructure creation."
            $Config['ams_monitor_name'] = $monitorName
            $subnet = $existingVnet.Subnets | Select-Object -First 1
            $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
            Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "Reused existing AMS Monitor ($monitorName) with working VNet peering" -DurationSeconds $duration
            return
        } elseif ($allVnets) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "VNet(s) found in RG but none have Connected peering to $sourceVnetName. Will attempt to fix peering."
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Monitor exists but no VNets found in RG. Will create VNet and peering."
        }
    } elseif ($existingMonitor) {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Existing monitor '$monitorName' in state '$($existingMonitor.ProvisioningState)'. Will create a new one."
        # Auto-increment name for failed/creating monitors
        $baseName = if ($monitorName -match '^(.+)_(\d+)$') { $Matches[1] } else { $monitorName }
        for ($suffix = 1; $suffix -le 10; $suffix++) {
            $candidateName = "${baseName}_${suffix}"
            $check = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $candidateName -ErrorAction SilentlyContinue
            if (-not $check) {
                $monitorName = $candidateName
                break
            }
        }
        $Config['ams_monitor_name'] = $monitorName
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Monitor name auto-incremented to: $monitorName"
    }

    $managedRg = if ($Config['managed_resource_group']) { $Config['managed_resource_group'] } else { "MRG_$monitorName" }

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Config: AMS Sub=$subscriptionId, RG=$rgName, Location=$location, SourceVNet=$sourceVnetResourceId, Monitor=$monitorName"

    # --- Validate source VNet (already parsed above) ---
    if (-not $sourceVnetName) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "vnet_resource_id is required and must be a valid VNet resource ID of the source VM VNet."
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Missing or invalid vnet_resource_id (source VM VNet)" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
        return
    }
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Source VM VNet: $sourceVnetName (Sub=$sourceVnetSubId, RG=$sourceVnetRg)"

    $isCrossSub = ($sourceVnetSubId -ne $subscriptionId)
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Cross-subscription: $isCrossSub (AMS=$subscriptionId, Source=$sourceVnetSubId)"

    # --- Step 1: Resource Group in AMS subscription ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Ensuring AMS subscription context: $subscriptionId"
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking resource group: $rgName"
    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating resource group: $rgName in $location"
        New-AzResourceGroup -Name $rgName -Location $location | Out-Null
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Resource group created: $rgName"
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Resource group already exists: $rgName"
    }

    # --- Step 2: Create VNet in AMS subscription ---
    # AMS VNet is always in the AMS subscription/RG (where the monitor lives)
    $amsVnetName = "ams-$($monitorName.ToLower())-vnet"
    $amsVnetRg = $rgName

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking AMS VNet: $amsVnetName in RG $amsVnetRg"
    $amsVnet = Get-AzVirtualNetwork -Name $amsVnetName -ResourceGroupName $amsVnetRg -ErrorAction SilentlyContinue

    if (-not $amsVnet) {
        # Get source VNet address spaces to avoid overlap
        $sourceVnetAddressSpaces = @()
        try {
            if ($isCrossSub) {
                Set-AzContext -Subscription $sourceVnetSubId -ErrorAction Stop | Out-Null
            }
            $sourceVnet = Get-AzVirtualNetwork -Name $sourceVnetName -ResourceGroupName $sourceVnetRg -ErrorAction Stop
            $sourceVnetAddressSpaces = $sourceVnet.AddressSpace.AddressPrefixes
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Source VNet address spaces: $($sourceVnetAddressSpaces -join ', ')"
            if ($isCrossSub) {
                Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Could not read source VNet address spaces: $($_.Exception.Message). Will use default non-overlapping range."
            if ($isCrossSub) {
                Set-AzContext -Subscription $subscriptionId -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # Calculate non-overlapping /28 for both VNet address space and subnet
        $amsVnetCidr = Get-NonOverlappingCidr -ExistingAddressSpaces $sourceVnetAddressSpaces -PrefixLength 28
        if (-not $amsVnetCidr) {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Could not find a non-overlapping /28 address range."
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "No available non-overlapping /28 range for AMS VNet" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }

        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating AMS VNet: $amsVnetName with address space $amsVnetCidr"
        try {
            $amsVnet = New-AzVirtualNetwork -Name $amsVnetName -ResourceGroupName $amsVnetRg `
                -Location $location -AddressPrefix $amsVnetCidr -ErrorAction Stop
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "AMS VNet created: $amsVnetName ($amsVnetCidr)"
        } catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to create AMS VNet: $($_.Exception.Message)"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "AMS VNet creation failed: $($_.Exception.Message)" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "AMS VNet already exists: $amsVnetName (Address: $($amsVnet.AddressSpace.AddressPrefixes -join ', '))"
    }

    # --- Step 3: Create delegated subnet in AMS VNet (/28 minimum) ---
    $subnetName = if ($subnetConfig -and $subnetConfig['name']) { $subnetConfig['name'] } else { 'ams-delegated-subnet' }

    $existingSubnet = $amsVnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    if (-not $existingSubnet) {
        # Subnet CIDR = same as VNet address space (since VNet is /28, subnet fills it)
        $subnetCidr = $amsVnet.AddressSpace.AddressPrefixes[0]
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating subnet: $subnetName ($subnetCidr) with Microsoft.Web/serverFarms delegation"

        try {
            $subnetPath = "/subscriptions/$subscriptionId/resourceGroups/$amsVnetRg/providers/Microsoft.Network/virtualNetworks/$amsVnetName/subnets/$subnetName"
            $subnetBody = @{
                properties = @{
                    addressPrefix = $subnetCidr
                    delegations = @(
                        @{
                            name = "ams-delegation"
                            properties = @{
                                serviceName = "Microsoft.Web/serverFarms"
                            }
                        }
                    )
                }
            } | ConvertTo-Json -Depth 5

            $response = Invoke-AzRestMethod -Path "$($subnetPath)?api-version=2023-11-01" -Method PUT -Payload $subnetBody
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Subnet created with delegation: $subnetName ($subnetCidr)"
            } else {
                $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                $errMsg = if ($errBody.error.message) { $errBody.error.message } else { "HTTP $($response.StatusCode): $($response.Content)" }
                throw $errMsg
            }
        } catch {
            $subnetErr = if ($_.Exception.Message) { $_.Exception.Message } else { "$_" }
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to create subnet: $subnetErr"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Subnet creation failed: $subnetErr" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Subnet already exists: $subnetName"
        if (-not ($existingSubnet.Delegations | Where-Object { $_.ServiceName -eq 'Microsoft.Web/serverFarms' })) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Subnet exists but missing Microsoft.Web/serverFarms delegation!"
        }
    }

    # Refresh VNet to get subnet ID
    $amsVnet = Get-AzVirtualNetwork -Name $amsVnetName -ResourceGroupName $amsVnetRg
    $subnet = $amsVnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    $subnetId = $subnet.Id

    if (-not $subnetId) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Subnet '$subnetName' not found in AMS VNet '$amsVnetName' after creation."
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Subnet not found after creation." -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
        return
    }
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Subnet ID: $subnetId"

    # --- Step 4: VNet Peering (AMS VNet <-> Source VM VNet) ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking VNet peering between AMS VNet and source VM VNet..."

    # Check if peering already exists
    $existingPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $amsVnetName -ResourceGroupName $amsVnetRg -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteVirtualNetwork.Id -match $sourceVnetName }

    if ($existingPeering -and $existingPeering.PeeringState -eq 'Connected') {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "VNet peering already exists and is Connected."
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating VNet peering: $amsVnetName <-> $sourceVnetName (cross-sub=$isCrossSub)"

        # Peering 1: AMS VNet -> Source VM VNet (done in AMS subscription context)
        try {
            $peeringName1 = "ams-to-source-$sourceVnetName"
            $peering1Path = "/subscriptions/$subscriptionId/resourceGroups/$amsVnetRg/providers/Microsoft.Network/virtualNetworks/$amsVnetName/virtualNetworkPeerings/$peeringName1"
            $peering1Body = @{
                properties = @{
                    remoteVirtualNetwork = @{
                        id = $sourceVnetResourceId
                    }
                    allowVirtualNetworkAccess = $true
                    allowForwardedTraffic = $true
                    allowGatewayTransit = $false
                    useRemoteGateways = $false
                }
            } | ConvertTo-Json -Depth 5

            $resp1 = Invoke-AzRestMethod -Path "$($peering1Path)?api-version=2023-11-01" -Method PUT -Payload $peering1Body
            if ($resp1.StatusCode -ge 200 -and $resp1.StatusCode -lt 300) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Peering created: AMS VNet -> Source VNet"
            } else {
                $err1 = ($resp1.Content | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
                if (-not $err1) { $err1 = "HTTP $($resp1.StatusCode): $($resp1.Content)" }
                throw "AMS->Source peering failed: $err1"
            }
        } catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to create AMS->Source peering: $($_.Exception.Message)"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "VNet peering (AMS->Source) failed: $($_.Exception.Message)" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }

        # Peering 2: Source VM VNet -> AMS VNet (needs source subscription context)
        try {
            $peeringName2 = "source-to-ams-$amsVnetName"
            $amsVnetId = $amsVnet.Id
            $peering2Path = "/subscriptions/$sourceVnetSubId/resourceGroups/$sourceVnetRg/providers/Microsoft.Network/virtualNetworks/$sourceVnetName/virtualNetworkPeerings/$peeringName2"
            $peering2Body = @{
                properties = @{
                    remoteVirtualNetwork = @{
                        id = $amsVnetId
                    }
                    allowVirtualNetworkAccess = $true
                    allowForwardedTraffic = $true
                    allowGatewayTransit = $false
                    useRemoteGateways = $false
                }
            } | ConvertTo-Json -Depth 5

            # Use REST API directly — works cross-sub as long as identity has Network Contributor on both
            $resp2 = Invoke-AzRestMethod -Path "$($peering2Path)?api-version=2023-11-01" -Method PUT -Payload $peering2Body
            if ($resp2.StatusCode -ge 200 -and $resp2.StatusCode -lt 300) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Peering created: Source VNet -> AMS VNet"
            } else {
                $err2 = ($resp2.Content | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
                if (-not $err2) { $err2 = "HTTP $($resp2.StatusCode): $($resp2.Content)" }
                throw "Source->AMS peering failed: $err2"
            }
        } catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to create Source->AMS peering: $($_.Exception.Message)"
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "RESOLUTION: Grant the Function App managed identity 'Network Contributor' on RG '$sourceVnetRg' in subscription '$sourceVnetSubId'."
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "VNet peering (Source->AMS) failed: $($_.Exception.Message)" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }

        # Wait for peering to reach Connected state
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Waiting for peering to reach Connected state..."
        $peerWait = 0
        $peerMaxWait = 60
        while ($peerWait -lt $peerMaxWait) {
            $peerStatus = Get-AzVirtualNetworkPeering -VirtualNetworkName $amsVnetName -ResourceGroupName $amsVnetRg -Name $peeringName1 -ErrorAction SilentlyContinue
            if ($peerStatus.PeeringState -eq 'Connected') {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "VNet peering is Connected."
                break
            }
            Start-Sleep -Seconds 5
            $peerWait += 5
        }
        if ($peerWait -ge $peerMaxWait) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Peering not yet Connected after ${peerMaxWait}s. State: $($peerStatus.PeeringState). Continuing..."
        }
    }

    # --- Step 5: Create AMS Monitor ---
    # Ensure we're in AMS subscription context
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking AMS monitor: $monitorName"
    $existingMonitor = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $monitorName -ErrorAction SilentlyContinue

    if (-not $existingMonitor) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating AMS monitor: $monitorName (subnet=$subnetId)"

        try {
            New-AzWorkloadsMonitor -Name $monitorName -ResourceGroupName $rgName `
                -SubscriptionId $subscriptionId -Location $location -AppLocation $location `
                -ManagedResourceGroupName $managedRg -MonitorSubnet $subnetId `
                -RoutingPreference 'RouteAll' | Out-Null

            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "AMS Monitor created: $monitorName"
        } catch {
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
    Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "AMS infrastructure ready (RG + VNet + Subnet + Peering + Monitor)" -DurationSeconds $duration
}

# Execute only when script is run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.' -and $Config) {
    Invoke-Phase2 -Config $Config
}
