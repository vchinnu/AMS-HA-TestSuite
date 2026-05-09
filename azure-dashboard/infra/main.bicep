// ============================================================================
// HA Cluster Test Dashboard - Azure Infrastructure (Bicep)
// ============================================================================
// Deploys: Storage Account, Function App (PowerShell), Static Web App
// Usage:  az deployment group create -g <RG> -f main.bicep -p location=northeurope
// ============================================================================

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Azure region for Static Web App (limited availability)')
param swaLocation string = 'westeurope'

@description('Base name for resources (will be suffixed)')
param baseName string = 'haclustertest'

@description('Unique suffix for globally unique names')
param uniqueSuffix string = uniqueString(resourceGroup().id)

// --- Variables ---
var storageAccountName = toLower('${take(baseName, 10)}${take(uniqueSuffix, 8)}')
var functionAppName = '${baseName}-func-${take(uniqueSuffix, 6)}'
var appServicePlanName = '${baseName}-plan'
var staticWebAppName = '${baseName}-dashboard'
var appInsightsName = '${baseName}-insights'

// --- Storage Account (reports + table) ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource reportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'ha-test-reports'
  properties: { publicAccess: 'None' }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource runsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableService
  name: 'HaClusterTestRuns'
}

// --- Application Insights ---
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// --- App Service Plan (Consumption) ---
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

// --- Function App (PowerShell 7.4) ---
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      cors: {
        allowedOrigins: [
          'https://${staticWebAppName}.azurestaticapps.net'
        ]
      }
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'REPORT_STORAGE_ACCOUNT'
          value: storageAccount.name
        }
        {
          name: 'REPORT_STORAGE_RG'
          value: resourceGroup().name
        }
      ]
    }
  }
}

// --- Static Web App ---
resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: staticWebAppName
  location: swaLocation
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
}

// --- RBAC: Function App Managed Identity → Contributor on subscription ---
// (Needed to create AMS resources, run VM commands, etc.)
// NOTE: Apply this manually or via a subscription-level deployment:
//   az role assignment create --assignee <functionApp-principalId> --role Contributor --scope /subscriptions/<sub-id>

// --- Outputs ---
output storageAccountName string = storageAccount.name
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output staticWebAppName string = staticWebApp.name
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output functionAppPrincipalId string = functionApp.identity.principalId
