# ============================================================================
# deploy.ps1 - One-click deployment of HA Cluster Test Dashboard to Azure
# ============================================================================
# Prerequisites:
#   - Azure CLI installed (az --version)
#   - Logged in (az login)
#   - Target subscription selected (az account set -s <sub-id>)
# ============================================================================

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,
    
    [string]$Location = 'northeurope',
    [string]$BaseName = 'haclustertest'
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     HA Cluster Test Dashboard - Azure Deployment           ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor White
Write-Host "  Location:        $Location" -ForegroundColor White
Write-Host "  Base Name:       $BaseName" -ForegroundColor White
Write-Host ""

# --- Step 1: Create Resource Group ---
Write-Host "  [1/5] Creating resource group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none 2>$null
Write-Host "  ✓ Resource group ready" -ForegroundColor Green

# --- Step 2: Deploy Bicep ---
Write-Host "  [2/5] Deploying infrastructure (Bicep)..." -ForegroundColor Yellow
$bicepPath = Join-Path $scriptDir 'infra\main.bicep'
$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepPath `
    --parameters location=$Location baseName=$BaseName `
    --output json | ConvertFrom-Json

$functionAppName = $deployment.properties.outputs.functionAppName.value
$functionAppUrl = $deployment.properties.outputs.functionAppUrl.value
$staticWebAppName = $deployment.properties.outputs.staticWebAppName.value
$staticWebAppUrl = $deployment.properties.outputs.staticWebAppUrl.value
$storageAccountName = $deployment.properties.outputs.storageAccountName.value
$principalId = $deployment.properties.outputs.functionAppPrincipalId.value

Write-Host "  ✓ Infrastructure deployed" -ForegroundColor Green
Write-Host "    Function App: $functionAppUrl" -ForegroundColor DarkGray
Write-Host "    Static Web App: $staticWebAppUrl" -ForegroundColor DarkGray

# --- Step 3: Deploy Function App code ---
Write-Host "  [3/5] Deploying Function App code..." -ForegroundColor Yellow
$funcAppDir = Join-Path $scriptDir 'function-app'

# Copy phase scripts and helpers into function app for execution
$phasesTarget = Join-Path $funcAppDir 'phases'
$helpersTarget = Join-Path $funcAppDir 'helpers'
$kqlTarget = Join-Path $funcAppDir 'kql'

if (-not (Test-Path $phasesTarget)) { New-Item -ItemType Directory -Path $phasesTarget -Force | Out-Null }
if (-not (Test-Path $helpersTarget)) { New-Item -ItemType Directory -Path $helpersTarget -Force | Out-Null }
if (-not (Test-Path $kqlTarget)) { New-Item -ItemType Directory -Path $kqlTarget -Force | Out-Null }

$rootDir = Split-Path $scriptDir -Parent
Copy-Item -Path (Join-Path $rootDir 'phases\*.ps1') -Destination $phasesTarget -Force
Copy-Item -Path (Join-Path $rootDir 'helpers\*.ps1') -Destination $helpersTarget -Force
Copy-Item -Path (Join-Path $rootDir 'kql\*') -Destination $kqlTarget -Force -ErrorAction SilentlyContinue

# Zip deploy
$zipPath = Join-Path $env:TEMP 'hacluster-func.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$funcAppDir\*" -DestinationPath $zipPath -Force

az functionapp deployment source config-zip `
    --resource-group $ResourceGroup `
    --name $functionAppName `
    --src $zipPath --output none

Write-Host "  ✓ Function App deployed" -ForegroundColor Green

# --- Step 4: Deploy Static Web App ---
Write-Host "  [4/5] Deploying Static Web App..." -ForegroundColor Yellow
$staticDir = Join-Path $scriptDir 'static-webapp'

# Get deployment token
$token = az staticwebapp secrets list --name $staticWebAppName --resource-group $ResourceGroup --query 'properties.apiKey' -o tsv 2>$null

if ($token) {
    # Use SWA CLI if available, otherwise manual upload note
    $swaCliExists = Get-Command swa -ErrorAction SilentlyContinue
    if ($swaCliExists) {
        Push-Location $staticDir
        swa deploy --deployment-token $token --app-location .
        Pop-Location
        Write-Host "  ✓ Static Web App deployed" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Install SWA CLI for auto-deploy: npm install -g @azure/static-web-apps-cli" -ForegroundColor Yellow
        Write-Host "    Then run: swa deploy --deployment-token $token --app-location $staticDir" -ForegroundColor DarkGray
        Write-Host "    Or deploy via Azure Portal > Static Web App > Manual upload" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  ⚠ Could not get deployment token. Deploy static content manually via Azure Portal." -ForegroundColor Yellow
}

# --- Step 5: Grant Managed Identity permissions ---
Write-Host "  [5/5] Granting Function App Managed Identity permissions..." -ForegroundColor Yellow
$subId = (az account show --query id -o tsv)
az role assignment create `
    --assignee $principalId `
    --role "Contributor" `
    --scope "/subscriptions/$subId" `
    --output none 2>$null

Write-Host "  ✓ Contributor role assigned to Function App identity" -ForegroundColor Green

# --- Done ---
Write-Host ""
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Dashboard URL:  $staticWebAppUrl" -ForegroundColor White
Write-Host "  Function API:   $functionAppUrl/api" -ForegroundColor White
Write-Host "  Storage:        $storageAccountName" -ForegroundColor White
Write-Host ""
Write-Host "  Share this URL with your team: $staticWebAppUrl" -ForegroundColor Green
Write-Host ""

# Cleanup temp files
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
if (Test-Path $phasesTarget) { Remove-Item $phasesTarget -Recurse -Force }
if (Test-Path $helpersTarget) { Remove-Item $helpersTarget -Recurse -Force }
if (Test-Path $kqlTarget) { Remove-Item $kqlTarget -Recurse -Force }
