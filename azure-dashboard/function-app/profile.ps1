# Azure Functions profile - runs once when Function App starts
# Authenticates using Managed Identity
try {
    if ($env:IDENTITY_ENDPOINT) {
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity | Out-Null
    }
} catch {
    Write-Warning "Profile: Managed Identity login failed - $_"
}
