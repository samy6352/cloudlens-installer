# Onboard extra subscriptions to a running CloudLens - self-contained, nothing to download.
# Paste into Azure Cloud Shell (PowerShell) after editing the three values below.
# Sign in as Owner or User Access Administrator on every subscription listed.
#
# Per subscription it (1) grants CloudLens's managed identity Reader, Cost Management Reader and
# Cost Management Contributor, then (2) creates the cost export and gives the export's own
# identity write access to the CloudLens storage account. The runtime app is deliberately unable
# to do step 2, which is why an administrator does it once here. Safe to re-run.

# ===================== PARAMETERS =====================
# Example: ./onboard.ps1 -ResourceGroup rg-cloudlens -AppName app-cloudlens -Subscriptions '<sub-a>','<sub-b>'
param(
    [Parameter(Mandatory)][string]$ResourceGroup,   # resource group of the CloudLens web app
    [Parameter(Mandatory)][string]$AppName,         # CloudLens web app name
    [Parameter(Mandatory)][string[]]$Subscriptions, # subscription IDs to add (comma-separated)
    [switch]$SkipRoleGrants                         # roles already granted to the app identity; only create exports
)
$Subscriptions = @($Subscriptions | ForEach-Object { $_ -split "[,\s'`"]+" } | Where-Object { $_ })
# ======================================================

$ErrorActionPreference = 'Stop'
$Roles = 'Reader', 'Cost Management Reader', 'Cost Management Contributor'
$BlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
$Api = '2025-03-01'

function AzJson { $ErrorActionPreference = 'Continue'; $script:AzErr = ''; $o = & az @args 2>&1; $err = @($o | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '; $o = @($o | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }); if ($LASTEXITCODE) { $script:AzErr = $err; return $null }; $t = ($o | Out-String).Trim(); if ($t) { try { $t | ConvertFrom-Json } catch { $t } } }

# ---- read the app's settings and identity
$app = AzJson webapp show -g $ResourceGroup -n $AppName -o json
if (-not $app) { throw "Cannot read web app $AppName in $ResourceGroup. Check the names and your access." }
$principal = @($app.identity.userAssignedIdentities.PSObject.Properties.Value.principalId) + @($app.identity.principalId) | Where-Object { $_ } | Select-Object -First 1
$settings = @{}; foreach ($s in (AzJson webapp config appsettings list -g $ResourceGroup -n $AppName -o json)) { $settings[$s.name] = $s.value }
$account   = $settings['ARCHIVE_ACCOUNT_ID']; $location = $settings['ARCHIVE_LOCATION']
$container = if ($settings['FOCUS_EXPORT_CONTAINER']) { $settings['FOCUS_EXPORT_CONTAINER'] } else { 'focus-exports' }
$prefix    = if ($settings['FOCUS_EXPORT_PREFIX']) { $settings['FOCUS_EXPORT_PREFIX'] } else { 'focus' }
if (-not $principal -or -not $account -or -not $location) { throw 'App identity or export storage settings not found on the web app.' }
$storageSub = $account.Split('/')[2]

# The app recognises an export as its own only by this name (hash of the destination).
function ExportName($folder) {
    $key = "$($account.ToLowerInvariant().TrimEnd('/'))|$container|$folder"
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($key))
    'cloudlens-focus-' + (-join ($h | ForEach-Object { $_.ToString('x2') })).Substring(0, 20)
}

$from = (Get-Date).ToUniversalTime().AddDays(1).Date.AddHours(2)
$report = @()
foreach ($sub in $Subscriptions) {
    $sub = $sub.Trim().ToLowerInvariant(); $status = 'ready'
    Write-Host "`n== $sub" -ForegroundColor Cyan
    try {
        foreach ($role in $(if ($SkipRoleGrants) { @() } else { $Roles })) {
            & az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal --role $role --scope "/subscriptions/$sub" -o none 2>$null
            if ($LASTEXITCODE) { throw "cannot grant '$role' (need Owner or User Access Administrator here)" }
            Write-Host "   granted $role"
        }

        $folder = "$prefix/$sub"; $name = ExportName $folder
        foreach ($rp in 'Microsoft.CostManagement', 'Microsoft.CostManagementExports') {
            & az provider register -n $rp --subscription $sub --wait -o none 2>$null
        }
        $uri = "/subscriptions/$sub/providers/Microsoft.CostManagement/exports/$name`?api-version=$Api"
        $body = [ordered]@{
            identity = @{ type = 'SystemAssigned' }; location = $location
            properties = [ordered]@{
                schedule = [ordered]@{ status = 'Inactive'; recurrence = 'Daily'
                    recurrencePeriod = @{ from = $from.ToString('yyyy-MM-ddTHH:mm:ssZ'); to = $from.AddYears(3).ToString('yyyy-MM-ddTHH:mm:ssZ') } }
                format = 'Parquet'; compressionMode = 'snappy'; partitionData = $true; dataOverwriteBehavior = 'CreateNewReport'
                deliveryInfo = @{ destination = @{ type = 'AzureBlob'; resourceId = $account; container = $container; rootFolderPath = $folder } }
                definition = [ordered]@{ type = 'FocusCost'; timeframe = 'MonthToDate'
                    dataSet = [ordered]@{ granularity = 'Daily'; configuration = @{ dataVersion = '1.0r2' } } }
            }
        }
        $existing = AzJson rest --method get --uri $uri -o json
        if ($existing -and $existing.eTag) {   # re-run: update in place, keep history
            $body.eTag = $existing.eTag; $body.location = $existing.location
            $body.properties.schedule.recurrencePeriod = $existing.properties.schedule.recurrencePeriod
        }
        $file = New-TemporaryFile
        try {
            ($body | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $file -Encoding utf8
            $made = AzJson rest --method put --uri $uri --body "@$file" --headers 'Content-Type=application/json' -o json
        } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        if (-not $made) { throw "export create failed: $script:AzErr" }
        Write-Host "   export $name ready"

        $exportId = [string]$made.identity.principalId
        if (-not $exportId) { throw 'Azure returned no export identity' }
        $has = AzJson role assignment list --scope $account --subscription $storageSub --query "[?principalId=='$exportId' && ends_with(roleDefinitionId,'$BlobContributor')].id" -o json
        if (-not $has -or @($has).Count -eq 0) {
            & az role assignment create --assignee-object-id $exportId --assignee-principal-type ServicePrincipal --role $BlobContributor --scope $account --subscription $storageSub -o none 2>$null
            if ($LASTEXITCODE) { throw 'cannot grant the export storage access (need Owner or User Access Administrator on the CloudLens storage account)' }
        }
        Write-Host '   export storage access OK'
    } catch { $status = "FAILED: $($_.Exception.Message)"; Write-Warning $status }
    $report += [pscustomobject]@{ Subscription = $sub; Status = $status }
}

$report | Format-Table -AutoSize
Write-Host 'Subscriptions appear in CloudLens within a few minutes (Setup > Check now to skip the wait). Re-run to retry any failures.'
