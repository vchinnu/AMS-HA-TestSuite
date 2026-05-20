# ============================================================================
# redeploy.ps1 - Quick code-only redeployment to existing Azure resources
# ============================================================================
# Use this when infrastructure already exists and you just need to push
# updated code to the Function App and/or Static Web App.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Azure Functions Core Tools (func --version)
#   - SWA CLI (swa --version) — optional, skips SWA deploy if missing
#   - Node.js & npm (for building the static web app)
#
# Usage:
#   .\redeploy.ps1                          # Deploy both
#   .\redeploy.ps1 -SkipFunctionApp         # Deploy only static web app
#   .\redeploy.ps1 -SkipStaticWebApp        # Deploy only function app
# ============================================================================

param(
    [string]$FunctionAppName = 'haclustertest-func-hjwf23',
    [string]$StaticWebAppName = 'haclustertest-dashboard',
    [switch]$SkipFunctionApp,
    [switch]$SkipStaticWebApp
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     HA Cluster Test Dashboard - Code Redeployment          ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$stepNum = 0
$totalSteps = 0
if (-not $SkipFunctionApp) { $totalSteps++ }
if (-not $SkipStaticWebApp) { $totalSteps += 2 }  # build + deploy

# ---------------------------------------------------------------------------
# Function App Deployment
# ---------------------------------------------------------------------------
if (-not $SkipFunctionApp) {
    $stepNum++
    Write-Host "  [$stepNum/$totalSteps] Deploying Function App ($FunctionAppName)..." -ForegroundColor Yellow

    # Verify func CLI
    if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ Azure Functions Core Tools not found. Install: npm i -g azure-functions-core-tools@4" -ForegroundColor Red
        exit 1
    }

    Push-Location (Join-Path $scriptDir 'function-app')
    try {
        func azure functionapp publish $FunctionAppName --powershell 2>&1 | ForEach-Object {
            if ($_ -match 'Invoke url:') { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Write-Host "  ✓ Function App deployed" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Static Web App Deployment
# ---------------------------------------------------------------------------
if (-not $SkipStaticWebApp) {
    $staticDir = Join-Path $scriptDir 'static-webapp'

    # Build
    $stepNum++
    Write-Host "  [$stepNum/$totalSteps] Building Static Web App..." -ForegroundColor Yellow

    Push-Location $staticDir
    try {
        npm run build 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗ Build failed. Run 'npm run build' manually to see errors." -ForegroundColor Red
            exit 1
        }
        Write-Host "  ✓ Build succeeded" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    # Deploy
    $stepNum++
    Write-Host "  [$stepNum/$totalSteps] Deploying Static Web App ($StaticWebAppName)..." -ForegroundColor Yellow

    if (-not (Get-Command swa -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ SWA CLI not found. Install: npm i -g @azure/static-web-apps-cli" -ForegroundColor Red
        exit 1
    }

    $token = az staticwebapp secrets list --name $StaticWebAppName --query 'properties.apiKey' -o tsv 2>$null
    if (-not $token) {
        Write-Host "  ✗ Could not retrieve deployment token for '$StaticWebAppName'" -ForegroundColor Red
        exit 1
    }

    Push-Location $staticDir
    try {
        $output = swa deploy dist --deployment-token $token --env production 2>&1
        $deployedUrl = $output | Select-String -Pattern 'https://.*azurestaticapps\.net' | ForEach-Object { $_.Matches[0].Value }
        Write-Host "  ✓ Static Web App deployed" -ForegroundColor Green
        if ($deployedUrl) { Write-Host "    $deployedUrl" -ForegroundColor DarkGray }
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  REDEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
