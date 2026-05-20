# ============================================================================
# HtmlReportGenerator.ps1 - Generate interactive HTML dashboard report
# ============================================================================

function New-TestReport {
    param(
        [array]$PhaseResults,
        [array]$LogEntries,
        [hashtable]$Config,
        [string]$OutputPath,
        [array]$Phase6ComparisonData = @(),
        [hashtable]$Phase6Summary = @{}
    )

    $runTimestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $reportFile = Join-Path $OutputPath "HACluster_TestReport_$runTimestamp.html"

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $osType = $Config['os_type']
    $osVersion = $Config['os_version']
    $sid = $Config['sap_sid']
    $clusterName = $Config['cluster_name']
    $nodeCount = $Config['nodes'].Count

    # Build phase cards HTML
    $phaseCardsHtml = ""
    foreach ($pr in $PhaseResults) {
        $statusClass = switch ($pr.Status) {
            'Passed'  { 'passed' }
            'Failed'  { 'failed' }
            'Skipped' { 'skipped' }
            'Running' { 'running' }
            default   { 'pending' }
        }
        $statusIcon = switch ($pr.Status) {
            'Passed'  { '&#10004;' }
            'Failed'  { '&#10008;' }
            'Skipped' { '&#9723;' }
            'Running' { '&#9203;' }
            default   { '&#9744;' }
        }
        $duration = if ($pr.DurationSeconds -gt 0) { "$($pr.DurationSeconds)s" } else { '-' }
        $phaseCardsHtml += @"
        <div class="phase-card $statusClass">
            <div class="phase-icon">$statusIcon</div>
            <div class="phase-info">
                <div class="phase-name">$($pr.Phase)</div>
                <div class="phase-message">$($pr.Message)</div>
            </div>
            <div class="phase-meta">
                <span class="duration">$duration</span>
                <span class="timestamp">$($pr.Timestamp)</span>
            </div>
        </div>
"@
    }

    # Build log table rows
    $logRowsHtml = ""
    foreach ($le in $LogEntries) {
        $levelClass = $le.Level.ToLower()
        $logRowsHtml += @"
        <tr class="log-$levelClass">
            <td>$($le.Timestamp)</td>
            <td>$($le.Phase)</td>
            <td><span class="badge badge-$levelClass">$($le.Level)</span></td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($le.Message))</td>
        </tr>
"@
    }

    # Summary stats
    $totalPhases = $PhaseResults.Count
    $passedCount = ($PhaseResults | Where-Object { $_.Status -eq 'Passed' }).Count
    $failedCount = ($PhaseResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $overallStatus = if ($failedCount -eq 0 -and $passedCount -gt 0) { 'ALL PASSED' } 
                     elseif ($failedCount -gt 0) { 'FAILURES DETECTED' } 
                     else { 'IN PROGRESS' }
    $overallClass = if ($failedCount -eq 0 -and $passedCount -gt 0) { 'passed' } 
                    elseif ($failedCount -gt 0) { 'failed' } 
                    else { 'running' }

    # --- Build Phase 6 Data Integrity Section ---
    $phase6Html = ""
    if ($Phase6ComparisonData -and $Phase6ComparisonData.Count -gt 0) {
        $p6Pass = ($Phase6ComparisonData | Where-Object { $_.Result -eq 'PASS' }).Count
        $p6Fail = ($Phase6ComparisonData | Where-Object { $_.Result -eq 'FAIL' }).Count
        $p6Warn = ($Phase6ComparisonData | Where-Object { $_.Result -eq 'WARN' }).Count
        $p6Total = $Phase6ComparisonData.Count
        $dcNode = $Phase6Summary['DCNode'] ?? ''
        $totalResources = $Phase6Summary['TotalResources'] ?? $p6Total
        $activeCount = $Phase6Summary['ActiveCount'] ?? 0
        $stoppedCount = $Phase6Summary['StoppedCount'] ?? 0

        $compRowsHtml = ""
        foreach ($row in $Phase6ComparisonData) {
            $rowClass = switch ($row.Result) { 'PASS' { 'row-pass' } 'FAIL' { 'row-fail' } default { 'row-warn' } }
            $resultClass = switch ($row.Result) { 'PASS' { 'result-pass' } 'FAIL' { 'result-fail' } default { 'result-warn' } }
            $stateClass = if ($row.State -eq 'active') { 'state-active' } else { 'state-stopped' }
            $nodeDisplay = if ($row.Node) { $row.Node } else { '(none)' }
            $dcBadge = if ($row.Node -eq $dcNode) { ' <span class="dc-badge">DC</span>' } else { '' }
            $roleDisplay = if ($row.Role) { $row.Role } else { '-' }
            $compRowsHtml += @"
            <tr class="$rowClass">
                <td><span class="$resultClass">$($row.Result)</span></td>
                <td>$($row.Resource)</td>
                <td>$($row.Agent)$dcBadge</td>
                <td>$nodeDisplay</td>
                <td>$roleDisplay</td>
                <td><span class="$stateClass">$($row.State)</span></td>
                <td>$($row.Managed)</td>
                <td>$($row.ExporterValue)</td>
                <td>$($row.WorkbookValue)</td>
            </tr>
"@
        }

        $certClass = if ($p6Fail -eq 0) { 'certified' } else { 'not-certified' }
        $certTitle = if ($p6Fail -eq 0) { '&#10004; OS CERTIFIED FOR AMS HA PROVIDER' } else { '&#10008; CERTIFICATION FAILED' }
        $certMsg = if ($p6Fail -eq 0) { 
            "All $p6Total resource checks passed. $osType $osVersion is validated for AMS HA cluster monitoring." 
        } else { 
            "$p6Fail of $p6Total checks failed. Review mismatches above before certifying." 
        }

        $phase6Html = @"
        <div class="phase6-section">
            <h2>Phase 6 - Data Integrity Validation (OS Certification)</h2>
            <div class="phase6-summary">
                <div class="phase6-stat pass"><div class="stat-label">Pass</div><div class="stat-value">$p6Pass</div></div>
                <div class="phase6-stat fail"><div class="stat-label">Fail</div><div class="stat-value">$p6Fail</div></div>
                <div class="phase6-stat warn"><div class="stat-label">Warn</div><div class="stat-value">$p6Warn</div></div>
                <div class="phase6-stat"><div class="stat-label">Total Resources</div><div class="stat-value">$totalResources</div></div>
                <div class="phase6-stat"><div class="stat-label">Active</div><div class="stat-value">$activeCount</div></div>
                <div class="phase6-stat"><div class="stat-label">Stopped</div><div class="stat-value">$stoppedCount</div></div>
                <div class="phase6-stat"><div class="stat-label">DC Node</div><div class="stat-value">$dcNode</div></div>
            </div>
            <table class="comparison-table">
                <thead>
                    <tr><th>Result</th><th>Resource</th><th>Agent (Node)</th><th>Node</th><th>Role</th><th>State</th><th>Managed</th><th>Exporter</th><th>Workbook</th></tr>
                </thead>
                <tbody>
                    $compRowsHtml
                </tbody>
            </table>
            <div class="cert-banner $certClass">
                <h3>$certTitle</h3>
                <p>$certMsg</p>
            </div>
        </div>
"@
    }

    # --- Build Inputs Panel HTML ---
    $nodesHtml = ""
    if ($Config['nodes']) {
        foreach ($node in $Config['nodes']) {
            $hn = $node['hostname']
            $ip = $node['ip_address']
            $vm = $node['vm_name']
            $nodesHtml += "                        <li><span class=`"node-name`">$hn</span><span>$ip</span></li>`n"
        }
    }
    $vmListHtml = ""
    if ($Config['nodes']) {
        foreach ($node in $Config['nodes']) {
            $vm = if ($node['vm_resource_id']) {
                # Parse VM name from resource ID
                if ($node['vm_resource_id'] -match '/virtualMachines/([^/]+)$') { $Matches[1] } else { $node['vm_resource_id'] }
            } else { $node['vm_name'] }
            $vmListHtml += "                        <li><span class=`"node-name`">$vm</span></li>`n"
        }
    }
    $vnetName = if ($Config['vnet']) { $Config['vnet']['name'] } else { '-' }
    $vnetRg = if ($Config['vnet']) { $Config['vnet']['resource_group'] } else { '-' }
    $subnetName = if ($Config['subnet']) { $Config['subnet']['name'] } else { '-' }
    $subnetCidr = if ($Config['subnet']) { $Config['subnet']['cidr'] } else { '-' }
    $execMethod = $Config['execution_method'] ?? 'vm_run_command'
    $laWsName = $Config['log_analytics_workspace_name'] ?? '-'
    $laWsId = $Config['log_analytics_workspace_id'] ?? '-'
    $subId = $Config['subscription_id'] ?? '-'
    $subIdShort = if ($subId.Length -gt 13) { "$($subId.Substring(0,8))...$($subId.Substring($subId.Length-4))" } else { $subId }
    $laIdShort = if ($laWsId.Length -gt 13) { "$($laWsId.Substring(0,8))...$($laWsId.Substring($laWsId.Length-4))" } else { $laWsId }
    # Derive VM RG and VM subscription from resource ID or fallback to explicit fields
    $vmRg = '-'
    $vmSubId = '-'
    if ($Config['nodes'] -and $Config['nodes'][0]) {
        $firstNode = $Config['nodes'][0]
        if ($firstNode['vm_resource_id'] -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/') {
            $vmSubId = $Matches[1]
            $vmRg = $Matches[2]
        } else {
            $vmRg = if ($firstNode['vm_resource_group']) { $firstNode['vm_resource_group'] } else { '-' }
            $vmSubId = $subId
        }
    }
    $vmSubIdShort = if ($vmSubId.Length -gt 13) { "$($vmSubId.Substring(0,8))...$($vmSubId.Substring($vmSubId.Length-4))" } else { $vmSubId }

    $inputsPanelHtml = @"
        <div class="inputs-panel">
            <h2>Test Input Details</h2>
            <div class="inputs-grid">
                <div class="inputs-group">
                    <h4>Cluster Configuration</h4>
                    <div class="input-row"><span class="key">SAP SID</span><span class="val">$sid</span></div>
                    <div class="input-row"><span class="key">Cluster Name</span><span class="val">$clusterName</span></div>
                    <div class="input-row"><span class="key">OS Type</span><span class="val">$osType</span></div>
                    <div class="input-row"><span class="key">OS Version</span><span class="val">$osVersion</span></div>
                    <div class="input-row"><span class="key">Exec Method</span><span class="val">$execMethod</span></div>
                    <h4 style="margin-top:14px;">Cluster Nodes</h4>
                    <ul class="node-list">
$nodesHtml                    </ul>
                </div>
                <div class="inputs-group">
                    <h4>Azure Resources</h4>
                    <div class="input-row"><span class="key">Subscription</span><span class="val">$subIdShort</span></div>
                    <div class="input-row"><span class="key">Resource Group</span><span class="val">$($Config['resource_group'])</span></div>
                    <div class="input-row"><span class="key">Location</span><span class="val">$($Config['location'])</span></div>
                    <div class="input-row"><span class="key">AMS Monitor</span><span class="val">$($Config['ams_monitor_name'])</span></div>
                    <div class="input-row"><span class="key">LA Workspace</span><span class="val">$laWsName</span></div>
                    <div class="input-row"><span class="key">Workspace ID</span><span class="val">$laIdShort</span></div>
                </div>
                <div class="inputs-group">
                    <h4>Network &amp; VMs</h4>
                    <div class="input-row"><span class="key">VNet</span><span class="val">$vnetName</span></div>
                    <div class="input-row"><span class="key">VNet RG</span><span class="val">$vnetRg</span></div>
                    <div class="input-row"><span class="key">Subnet</span><span class="val">$subnetName</span></div>
                    <div class="input-row"><span class="key">Subnet CIDR</span><span class="val">$subnetCidr</span></div>
                    <h4 style="margin-top:14px;">VM Names</h4>
                    <ul class="node-list">
$vmListHtml                    </ul>
                    <div class="input-row"><span class="key">VM RG</span><span class="val">$vmRg</span></div>
                    <div class="input-row"><span class="key">VM Subscription</span><span class="val">$vmSubIdShort</span></div>
                </div>
            </div>
        </div>
"@

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HA Cluster E2E Test Report - $runTimestamp</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', system-ui, sans-serif; background: #1a1a2e; color: #eaeaea; }
        .header { background: linear-gradient(135deg, #16213e, #0f3460); padding: 30px 40px; border-bottom: 3px solid #0ea5e9; }
        .header h1 { font-size: 24px; color: #fff; }
        .header .subtitle { color: #94a3b8; margin-top: 5px; }
        .container { max-width: 1400px; margin: 0 auto; padding: 30px 40px; }
        
        /* Summary Strip */
        .summary-strip { display: flex; gap: 20px; margin-bottom: 30px; flex-wrap: wrap; }
        .summary-card { background: #16213e; border-radius: 10px; padding: 20px; flex: 1; min-width: 150px; border: 1px solid #1e3a5f; }
        .summary-card .label { font-size: 12px; color: #64748b; text-transform: uppercase; letter-spacing: 1px; }
        .summary-card .value { font-size: 28px; font-weight: 700; margin-top: 5px; color: #fff; }
        .summary-card.passed .value { color: #22c55e; }
        .summary-card.failed .value { color: #ef4444; }
        .summary-card.running .value { color: #f59e0b; }

        /* Phase Cards */
        .phases-section h2 { margin-bottom: 15px; color: #94a3b8; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; }
        .phase-card { display: flex; align-items: center; background: #16213e; border-radius: 8px; padding: 16px 20px; margin-bottom: 10px; border-left: 4px solid #334155; transition: all 0.2s; }
        .phase-card:hover { background: #1e293b; }
        .phase-card.passed { border-left-color: #22c55e; }
        .phase-card.failed { border-left-color: #ef4444; }
        .phase-card.skipped { border-left-color: #64748b; }
        .phase-card.running { border-left-color: #f59e0b; }
        .phase-icon { font-size: 22px; width: 40px; text-align: center; }
        .phase-card.passed .phase-icon { color: #22c55e; }
        .phase-card.failed .phase-icon { color: #ef4444; }
        .phase-card.running .phase-icon { color: #f59e0b; }
        .phase-info { flex: 1; margin-left: 15px; }
        .phase-name { font-weight: 600; font-size: 15px; }
        .phase-message { color: #94a3b8; font-size: 13px; margin-top: 3px; }
        .phase-meta { text-align: right; color: #64748b; font-size: 12px; }
        .phase-meta .duration { display: block; font-weight: 600; color: #94a3b8; }

        /* Log Table */
        .logs-section { margin-top: 40px; }
        .logs-section h2 { margin-bottom: 15px; color: #94a3b8; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; }
        .log-filter { margin-bottom: 15px; display: flex; gap: 8px; }
        .log-filter button { padding: 6px 14px; border: 1px solid #334155; background: #16213e; color: #94a3b8; border-radius: 6px; cursor: pointer; font-size: 12px; }
        .log-filter button.active { background: #0ea5e9; color: #fff; border-color: #0ea5e9; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #0f172a; padding: 10px 12px; text-align: left; font-size: 12px; text-transform: uppercase; color: #64748b; letter-spacing: 0.5px; }
        td { padding: 10px 12px; border-bottom: 1px solid #1e293b; font-size: 13px; }
        tr:hover { background: #1e293b; }
        .badge { padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
        .badge-info { background: #0ea5e922; color: #38bdf8; }
        .badge-warn { background: #f59e0b22; color: #fbbf24; }
        .badge-error { background: #ef444422; color: #f87171; }
        .badge-success { background: #22c55e22; color: #4ade80; }

        /* Config Panel */
        .config-panel { background: #16213e; border-radius: 10px; padding: 20px; margin-top: 30px; border: 1px solid #1e3a5f; }
        .config-panel h3 { color: #94a3b8; font-size: 13px; text-transform: uppercase; margin-bottom: 10px; }
        .config-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
        .config-item .label { font-size: 11px; color: #64748b; }
        .config-item .value { font-size: 14px; color: #fff; font-weight: 500; }

        /* Phase 6 Data Integrity Section */
        .phase6-section { margin-top: 40px; }
        .phase6-section h2 { margin-bottom: 15px; color: #94a3b8; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; }
        .phase6-summary { display: flex; gap: 15px; margin-bottom: 20px; flex-wrap: wrap; }
        .phase6-stat { background: #0f172a; border-radius: 8px; padding: 12px 18px; border: 1px solid #1e3a5f; }
        .phase6-stat .stat-label { font-size: 11px; color: #64748b; text-transform: uppercase; }
        .phase6-stat .stat-value { font-size: 20px; font-weight: 700; color: #fff; margin-top: 2px; }
        .phase6-stat.pass .stat-value { color: #22c55e; }
        .phase6-stat.fail .stat-value { color: #ef4444; }
        .phase6-stat.warn .stat-value { color: #f59e0b; }
        .comparison-table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        .comparison-table th { background: #0f172a; padding: 10px 12px; text-align: left; font-size: 11px; text-transform: uppercase; color: #64748b; letter-spacing: 0.5px; border-bottom: 2px solid #1e3a5f; }
        .comparison-table td { padding: 9px 12px; border-bottom: 1px solid #1e293b; font-size: 13px; }
        .comparison-table tr:hover { background: #1e293b; }
        .comparison-table tr.row-pass { border-left: 3px solid #22c55e; }
        .comparison-table tr.row-fail { border-left: 3px solid #ef4444; }
        .comparison-table tr.row-warn { border-left: 3px solid #f59e0b; }
        .state-active { color: #22c55e; font-weight: 600; }
        .state-stopped { color: #f59e0b; font-weight: 600; }
        .result-pass { color: #22c55e; font-weight: 700; }
        .result-fail { color: #ef4444; font-weight: 700; }
        .result-warn { color: #f59e0b; font-weight: 700; }
        .dc-badge { background: #7c3aed33; color: #a78bfa; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }

        /* Certification Banner */
        .cert-banner { margin-top: 30px; padding: 20px 25px; border-radius: 10px; text-align: center; }
        .cert-banner.certified { background: linear-gradient(135deg, #064e3b, #065f46); border: 2px solid #22c55e; }
        .cert-banner.not-certified { background: linear-gradient(135deg, #450a0a, #7f1d1d); border: 2px solid #ef4444; }
        .cert-banner h3 { font-size: 18px; margin-bottom: 5px; }
        .cert-banner.certified h3 { color: #22c55e; }
        .cert-banner.not-certified h3 { color: #ef4444; }
        .cert-banner p { color: #94a3b8; font-size: 13px; }

        /* Inputs Panel */
        .inputs-panel { background: #16213e; border-radius: 10px; padding: 25px; margin-bottom: 30px; border: 1px solid #1e3a5f; }
        .inputs-panel h2 { color: #94a3b8; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 18px; }
        .inputs-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 20px; }
        .inputs-group { background: #0f172a; border-radius: 8px; padding: 16px; border: 1px solid #1e3a5f; }
        .inputs-group h4 { color: #0ea5e9; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; border-bottom: 1px solid #1e3a5f; padding-bottom: 8px; }
        .input-row { display: flex; justify-content: space-between; margin-bottom: 8px; }
        .input-row .key { color: #64748b; font-size: 12px; }
        .input-row .val { color: #fff; font-size: 13px; font-weight: 500; text-align: right; max-width: 60%; word-break: break-all; }
        .node-list { list-style: none; padding: 0; }
        .node-list li { background: #1e293b; border-radius: 4px; padding: 6px 10px; margin-bottom: 4px; font-size: 12px; color: #94a3b8; display: flex; justify-content: space-between; }
        .node-list li .node-name { color: #fff; font-weight: 600; }
    </style>
</head>
<body>
    <div class="header">
        <h1>HA Cluster E2E Test Report</h1>
        <div class="subtitle">$osType $osVersion | SID: $sid | Cluster: $clusterName | Nodes: $nodeCount | Generated: $runTimestamp</div>
    </div>
    <div class="container">
        <div class="summary-strip">
            <div class="summary-card $overallClass"><div class="label">Overall</div><div class="value">$overallStatus</div></div>
            <div class="summary-card"><div class="label">Phases Run</div><div class="value">$totalPhases</div></div>
            <div class="summary-card passed"><div class="label">Passed</div><div class="value">$passedCount</div></div>
            <div class="summary-card failed"><div class="label">Failed</div><div class="value">$failedCount</div></div>
            <div class="summary-card"><div class="label">OS Type</div><div class="value">$osType $osVersion</div></div>
        </div>

        $inputsPanelHtml

        <div class="phases-section">
            <h2>Phase Execution Timeline</h2>
            $phaseCardsHtml
        </div>

        <div class="logs-section">
            <h2>Execution Log</h2>
            <div class="log-filter">
                <button class="active" onclick="filterLogs('all')">All</button>
                <button onclick="filterLogs('error')">Errors</button>
                <button onclick="filterLogs('warn')">Warnings</button>
                <button onclick="filterLogs('success')">Success</button>
            </div>
            <table>
                <thead><tr><th>Time</th><th>Phase</th><th>Level</th><th>Message</th></tr></thead>
                <tbody id="logBody">
                    $logRowsHtml
                </tbody>
            </table>
        </div>

        $phase6Html

        <div class="config-panel">
            <h3>Test Configuration</h3>
            <div class="config-grid">
                <div class="config-item"><div class="label">Subscription</div><div class="value">$($Config['subscription_id'])</div></div>
                <div class="config-item"><div class="label">Resource Group</div><div class="value">$($Config['resource_group'])</div></div>
                <div class="config-item"><div class="label">Location</div><div class="value">$($Config['location'])</div></div>
                <div class="config-item"><div class="label">Execution Method</div><div class="value">$($Config['execution_method'])</div></div>
                <div class="config-item"><div class="label">AMS Monitor</div><div class="value">$($Config['ams_monitor_name'])</div></div>
                <div class="config-item"><div class="label">Cluster Name</div><div class="value">$clusterName</div></div>
            </div>
        </div>
    </div>
    <script>
    function filterLogs(level) {
        document.querySelectorAll('.log-filter button').forEach(b => b.classList.remove('active'));
        event.target.classList.add('active');
        document.querySelectorAll('#logBody tr').forEach(row => {
            row.style.display = (level === 'all' || row.classList.contains('log-' + level)) ? '' : 'none';
        });
    }
    </script>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding utf8
    Write-PhaseLog -Phase 'Report' -Level 'SUCCESS' -Message "HTML report saved: $reportFile"
    
    # Also save JSON log for agent troubleshooting
    $jsonReport = @{
        Timestamp    = $runTimestamp
        Config       = @{ os_type = $osType; os_version = $osVersion; sid = $sid; cluster = $clusterName }
        PhaseResults = $PhaseResults
        LogEntries   = $LogEntries
        Phase6Comparison = $Phase6ComparisonData
        Phase6Summary    = $Phase6Summary
    } | ConvertTo-Json -Depth 5
    $jsonFile = Join-Path $OutputPath "HACluster_TestReport_$runTimestamp.json"
    $jsonReport | Out-File -FilePath $jsonFile -Encoding utf8

    return $reportFile
}

if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function *
}
