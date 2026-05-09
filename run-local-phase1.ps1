# ============================================================================
# run-local-phase1.ps1 - Run Phase 1 locally to test VM Run Command
# ============================================================================
$ErrorActionPreference = 'Continue'

# Connect to target subscription
$subscriptionId = "2b331373-3d36-4585-bdb9-d3364786e775"
Write-Host "Connecting to subscription $subscriptionId..." -ForegroundColor Cyan
Connect-AzAccount -Subscription $subscriptionId -ErrorAction Stop | Out-Null
Write-Host "Connected." -ForegroundColor Green

# Disable global dashboard flush (we're running locally)
$global:DashboardFlushEnabled = $false

# Source helpers
. (Join-Path $PSScriptRoot 'helpers\Common.ps1')

# Build config matching what the dashboard sends
$config = @{
    subscription_id    = $subscriptionId
    resource_group     = "LAB-NOEU-SAP01-CHA"
    location           = "northeurope"
    os_type            = "SUSE"
    os_version         = "SLES 15 SP5"
    sap_sid            = "CHA"
    cluster_name       = "ha_ascs_cluster"
    execution_method   = "vm_run_command"
    nodes              = @(
        @{
            hostname          = "chascs01l0c2"
            ip_address        = "10.8.1.41"
            vm_name           = "LAB-NOEU-SAP01-CHA_chascs01l0c2"
            vm_resource_group = "LAB-NOEU-SAP01-CHA"
        },
        @{
            hostname          = "chascs02l0c2"
            ip_address        = "10.8.1.39"
            vm_name           = "LAB-NOEU-SAP01-CHA_chascs02l0c2"
            vm_resource_group = "LAB-NOEU-SAP01-CHA"
        }
    )
}

# Source and run Phase 1
Write-Host "`n=== Running Phase 1 locally ===" -ForegroundColor Yellow
. (Join-Path $PSScriptRoot 'phases\Phase1-InstallExporter.ps1')
Invoke-Phase1 -Config $config

# Show results
Write-Host "`n=== Phase Results ===" -ForegroundColor Yellow
$script:PhaseResults | ForEach-Object { Write-Host "$($_.Phase): $($_.Status) - $($_.Message)" -ForegroundColor $(if ($_.Status -eq 'Passed') { 'Green' } else { 'Red' }) }

Write-Host "`n=== Log Entries ===" -ForegroundColor Yellow
$script:LogEntries | ForEach-Object { Write-Host "[$($_.Level)] $($_.Message)" -ForegroundColor $(switch ($_.Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'SUCCESS' { 'Green' } default { 'White' } }) }
