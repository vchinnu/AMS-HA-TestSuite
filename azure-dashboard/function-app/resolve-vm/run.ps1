using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# resolve-vm - Resolve VM details (hostname, private IP) from a resource ID
# ============================================================================
# Input: POST body with { "vm_resource_id": "/subscriptions/.../virtualMachines/..." }
# Output: { "vm_name": "...", "ip_address": "...", "hostname": "..." }
# ============================================================================

$ErrorActionPreference = 'Stop'

$body = $Request.Body
if (-not $body -or -not $body.vm_resource_id) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::BadRequest
        Body        = (@{ error = "vm_resource_id is required" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

$resourceId = $body.vm_resource_id.Trim()

# Parse resource ID
if ($resourceId -notmatch '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::BadRequest
        Body        = (@{ error = "Invalid VM resource ID format" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

$subId  = $Matches[1]
$rgName = $Matches[2]
$vmName = $Matches[3]

try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Subscription $subId -ErrorAction Stop | Out-Null

    # Get VM to find NIC
    $vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction Stop

    # Get primary NIC's private IP
    $ipAddress = ''
    if ($vm.NetworkProfile.NetworkInterfaces.Count -gt 0) {
        $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
        $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
        if ($nic.IpConfigurations.Count -gt 0) {
            $ipAddress = $nic.IpConfigurations[0].PrivateIpAddress
        }
    }

    # Get computer name (OS hostname) if available
    $hostname = $vmName
    if ($vm.OSProfile -and $vm.OSProfile.ComputerName) {
        $hostname = $vm.OSProfile.ComputerName
    }

    $result = @{
        vm_name    = $vmName
        hostname   = $hostname
        ip_address = $ipAddress
        resource_group = $rgName
        subscription_id = $subId
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::OK
        Body        = ($result | ConvertTo-Json)
        ContentType = "application/json"
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::InternalServerError
        Body        = (@{ error = $_.Exception.Message; vm_name = $vmName } | ConvertTo-Json)
        ContentType = "application/json"
    })
}
