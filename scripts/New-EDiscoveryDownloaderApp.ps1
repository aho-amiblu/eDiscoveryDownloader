#Requires -Version 7.2
<#
.SYNOPSIS
Creates a single-tenant Entra application for eDiscoveryDownloader.
.DESCRIPTION
Signs in interactively with an administrator, ensures that the Microsoft Purview
download API service principal exists, registers an app, sets API permissions,
and installs a non-exportable authentication certificate in CurrentUser\My.

Application permissions are only requested unless -GrantAdminConsent is specified.
Purview RBAC is only changed if -ConfigurePurviewRoles is specified.
No private key or client secret is written to disk.

Requires PowerShell 7.2+ on Windows. No changes are made to the tenant by simply
downloading this file; run it explicitly with your tenant ID.
.EXAMPLE
.\scripts\New-EDiscoveryDownloaderApp.ps1 -TenantId '<tenant-guid>'
.EXAMPLE
.\scripts\New-EDiscoveryDownloaderApp.ps1 -TenantId '<tenant-guid>' -GrantAdminConsent -ConfigurePurviewRoles
.EXAMPLE
.\scripts\New-EDiscoveryDownloaderApp.ps1 -TenantId '<tenant-guid>' -GrantAdminConsent -ConfigurePurviewRoles -GrantEDiscoveryAdministrator
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [guid]$TenantId,

    [ValidateNotNullOrEmpty()]
    [string]$DisplayName = 'HPUSA eDiscovery Downloader',

    [ValidateRange(1, 11)]
    [int]$CertificateMonths = 11,

    [string]$OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'eDiscoveryDownloader'),

    [switch]$GrantAdminConsent,

    [switch]$ConfigurePurviewRoles,

    [switch]$GrantEDiscoveryAdministrator,

    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:EDSetupGraphBase = 'https://graph.microsoft.com/v1.0'
$script:EDSetupGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:EDSetupPurviewAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'

function Install-EDSetupModule {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if ($NoInstall) {
            throw "Missing PowerShell module '$Name'. Install it with: Install-Module $Name -Scope CurrentUser"
        }
        Write-Host "Installing $Name for the current user..."
        Install-Module -Name $Name -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    }
    Import-Module -Name $Name -ErrorAction Stop
}

function Invoke-EDSetupGraph {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowNull()][object]$Body
    )
    $args = @{
        Method = $Method
        Uri = $Uri
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $args.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        $args.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @args
}

function Get-EDSetupServicePrincipal {
    param([Parameter(Mandatory = $true)][guid]$AppId)

    $query = [uri]::EscapeDataString("appId eq '$AppId'")
    $uri = $script:EDSetupGraphBase + '/servicePrincipals?$filter=' + $query + '&$select=id,appId,displayName,appRoles'
    $result = Invoke-EDSetupGraph -Method GET -Uri $uri
    @($result.value) | Where-Object { $null -ne $_ } | Select-Object -First 1
}

function Wait-EDSetupServicePrincipal {
    param([Parameter(Mandatory = $true)][guid]$AppId)
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $sp = Get-EDSetupServicePrincipal -AppId $AppId
        if ($null -ne $sp) { return $sp }
        Start-Sleep -Seconds 3
    }
    throw "Service principal $AppId was not visible after creation. Allow Entra replication and retry the remaining setup manually."
}

function Get-EDSetupRole {
    param(
        [Parameter(Mandatory = $true)][object]$ServicePrincipal,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $role = @($ServicePrincipal.appRoles) | Where-Object {
        $null -ne $_ -and
        $_.value -eq $Name -and
        $_.isEnabled -eq $true -and
        @($_.allowedMemberTypes) -contains 'Application'
    } | Select-Object -First 1

    if ($null -eq $role) {
        throw "Application role '$Name' is not exposed by resource '$($ServicePrincipal.displayName)'."
    }
    return $role
}

function Grant-EDSetupAppRole {
    param(
        [Parameter(Mandatory = $true)][object]$ClientServicePrincipal,
        [Parameter(Mandatory = $true)][object]$ResourceServicePrincipal,
        [Parameter(Mandatory = $true)][object]$Role
    )
    $uri = "$($script:EDSetupGraphBase)/servicePrincipals/$($ClientServicePrincipal.id)/appRoleAssignments"
    $existing = Invoke-EDSetupGraph -Method GET -Uri $uri

    foreach ($assignment in @($existing.value)) {
        if ($null -ne $assignment -and
            [string]$assignment.resourceId -eq [string]$ResourceServicePrincipal.id -and
            [string]$assignment.appRoleId -eq [string]$Role.id) {
            Write-Host "Already consented: $($Role.value)"
            return
        }
    }

    $body = @{
        principalId = [string]$ClientServicePrincipal.id
        resourceId = [string]$ResourceServicePrincipal.id
        appRoleId = [string]$Role.id
    }
    $null = Invoke-EDSetupGraph -Method POST -Uri $uri -Body $body
    Write-Host "Granted application permission: $($Role.value)"
}

function Set-EDSetupPurviewRoles {
    param(
        [Parameter(Mandatory = $true)][object]$ClientServicePrincipal,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Administrator
    )

    Install-EDSetupModule -Name ExchangeOnlineManagement
    Write-Host 'Opening an interactive Security & Compliance PowerShell sign-in...'
    Connect-IPPSSession -ErrorAction Stop | Out-Null

    $registered = @(Get-ServicePrincipal -ErrorAction Stop) | Where-Object {
        [string]$_.AppId -eq $ClientId
    } | Select-Object -First 1

    if (-not $registered) {
        $null = New-ServicePrincipal -AppId $ClientId -ObjectId $ClientServicePrincipal.id -DisplayName $Name -ErrorAction Stop
        Write-Host 'Registered the Entra service principal in Microsoft Purview.'
    }
    else {
        Write-Host 'The service principal is already registered in Microsoft Purview.'
    }

    $member = @(Get-RoleGroupMember -Identity 'eDiscoveryManager' -ErrorAction Stop) | Where-Object {
        [string]$_.ExternalDirectoryObjectId -eq [string]$ClientServicePrincipal.id -or
        [string]$_.Guid -eq [string]$ClientServicePrincipal.id
    } | Select-Object -First 1

    if (-not $member) {
        Add-RoleGroupMember -Identity 'eDiscoveryManager' -Member $ClientServicePrincipal.id -ErrorAction Stop
        Write-Host 'Added the service principal to eDiscoveryManager.'
    }
    else {
        Write-Host 'Service principal is already a member of eDiscoveryManager.'
    }

    if ($Administrator) {
        # Broad, tenant-wide case access. This is opt-in only.
        $admin = @(Get-eDiscoveryCaseAdmin -ErrorAction Stop) | Where-Object {
            [string]$_.ExternalDirectoryObjectId -eq [string]$ClientServicePrincipal.id -or
            [string]$_.Guid -eq [string]$ClientServicePrincipal.id
        } | Select-Object -First 1

        if (-not $admin) {
            Add-eDiscoveryCaseAdmin -User $ClientServicePrincipal.id -ErrorAction Stop
            Write-Host 'Added the service principal as an eDiscovery Administrator (tenant-wide case access).'
        }
    }
}

if (-not $IsWindows) {
    throw 'Certificate setup requires Windows (PowerShell 7.2+ and the Windows certificate store).'
}
if ($TenantId -eq [guid]::Empty) {
    throw 'Specify a real, nonempty -TenantId.'
}
if ($GrantEDiscoveryAdministrator -and -not $ConfigurePurviewRoles) {
    throw '-GrantEDiscoveryAdministrator requires -ConfigurePurviewRoles.'
}

$actionDescription = "create Entra app '$DisplayName', assign requested API permissions, and create a local certificate"
if ($GrantAdminConsent) { $actionDescription += '; grant tenant-wide admin consent' }
if ($ConfigurePurviewRoles) { $actionDescription += '; change Microsoft Purview role membership' }
if ($GrantEDiscoveryAdministrator) { $actionDescription += '; give the app eDiscovery Administrator access to all cases' }

if (-not $PSCmdlet.ShouldProcess("Entra tenant $TenantId", $actionDescription)) { return }

Install-EDSetupModule -Name Microsoft.Graph.Authentication
if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
    throw 'New-SelfSignedCertificate is missing. Run this on Windows with the PKI module.'
}

$scopes = @('Application.ReadWrite.All')
if ($GrantAdminConsent) { $scopes += 'AppRoleAssignment.ReadWrite.All' }

Write-Host "Signing in to tenant $TenantId using Microsoft Graph (MFA supported)..."
Connect-MgGraph -TenantId ([string]$TenantId) -Scopes $scopes -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
$context = Get-MgContext
if (-not $context -or [string]$context.TenantId -ne [string]$TenantId) {
    throw 'Microsoft Graph is not connected to the requested tenant.'
}

$escapedName = $DisplayName.Replace("'", "''")
$filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
$uri = $script:EDSetupGraphBase + '/applications?$filter=' + $filter + '&$select=id,appId,displayName'
$existingApps = Invoke-EDSetupGraph -Method GET -Uri $uri
if (@($existingApps.value | Where-Object { $null -ne $_ }).Count -gt 0) {
    throw "An application named '$DisplayName' already exists. Stop to avoid accidentally creating a duplicate. Review it in Entra App registrations."
}

$graphResource = Wait-EDSetupServicePrincipal -AppId ([guid]$script:EDSetupGraphAppId)
$purviewResource = Get-EDSetupServicePrincipal -AppId ([guid]$script:EDSetupPurviewAppId)
if (-not $purviewResource) {
    Write-Host 'Provisioning the MicrosoftPurviewEDiscovery Microsoft enterprise application...'
    $null = Invoke-EDSetupGraph -Method POST -Uri "$($script:EDSetupGraphBase)/servicePrincipals" -Body @{
        appId = $script:EDSetupPurviewAppId
    }
    $purviewResource = Wait-EDSetupServicePrincipal -AppId ([guid]$script:EDSetupPurviewAppId)
}

$graphRole = Get-EDSetupRole -ServicePrincipal $graphResource -Name 'eDiscovery.ReadWrite.All'
$purviewRole = Get-EDSetupRole -ServicePrincipal $purviewResource -Name 'eDiscovery.Download.Read'

$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
$null = New-Item -Path $destination -ItemType Directory -Force -ErrorAction Stop

$cert = New-SelfSignedCertificate -Subject "CN=eDiscoveryDownloader-$($TenantId.ToString().Substring(0,8))" -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeySpec Signature -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddMonths($CertificateMonths) -ErrorAction Stop
if (-not $cert.HasPrivateKey) {
    throw 'The generated certificate has no private key.'
}

$publicCertificate = Join-Path $destination "eDiscoveryDownloader-$($cert.Thumbprint).cer"
$null = Export-Certificate -Cert $cert -FilePath $publicCertificate -Force -ErrorAction Stop

$body = @{
    displayName = $DisplayName
    signInAudience = 'AzureADMyOrg'
    requiredResourceAccess = @(
        @{
            resourceAppId = $script:EDSetupGraphAppId
            resourceAccess = @(@{ id = [string]$graphRole.id; type = 'Role' })
        },
        @{
            resourceAppId = $script:EDSetupPurviewAppId
            resourceAccess = @(@{ id = [string]$purviewRole.id; type = 'Role' })
        }
    )
}

$app = Invoke-EDSetupGraph -Method POST -Uri "$($script:EDSetupGraphBase)/applications" -Body $body
Write-Host "Created app registration: $($app.appId)"
Write-Host "Application object ID: $($app.id)"

try {
    $key = @{
        displayName = 'eDiscoveryDownloader authentication'
        type = 'AsymmetricX509Cert'
        usage = 'Verify'
        key = [Convert]::ToBase64String($cert.RawData)
        startDateTime = $cert.NotBefore.ToUniversalTime().ToString('o')
        endDateTime = $cert.NotAfter.ToUniversalTime().ToString('o')
    }
    $null = Invoke-EDSetupGraph -Method PATCH -Uri "$($script:EDSetupGraphBase)/applications/$($app.id)" -Body @{
        keyCredentials = @($key)
    }
    Write-Host "Certificate registered (thumbprint: $($cert.Thumbprint))."

    $clientServicePrincipal = Get-EDSetupServicePrincipal -AppId ([guid]$app.appId)
    if (-not $clientServicePrincipal) {
        $null = Invoke-EDSetupGraph -Method POST -Uri "$($script:EDSetupGraphBase)/servicePrincipals" -Body @{
            appId = [string]$app.appId
        }
        $clientServicePrincipal = Wait-EDSetupServicePrincipal -AppId ([guid]$app.appId)
    }
}
catch {
    Write-Warning "App $($app.appId) was created, but certificate/service-principal setup failed: $($_.Exception.Message)"
    Write-Warning "The app and certificate might need manual completion in Entra. Do NOT rerun this script with the same name."
    throw
}

$consentStatus = 'Pending'
if ($GrantAdminConsent) {
    try {
        Grant-EDSetupAppRole -ClientServicePrincipal $clientServicePrincipal -ResourceServicePrincipal $graphResource -Role $graphRole
        Grant-EDSetupAppRole -ClientServicePrincipal $clientServicePrincipal -ResourceServicePrincipal $purviewResource -Role $purviewRole
        $consentStatus = 'Granted'
    }
    catch {
        $consentStatus = 'Not fully granted'
        Write-Warning "Automatic admin consent failed: $($_.Exception.Message)"
        Write-Warning 'A tenant administrator must finish admin consent in Entra > App registrations > API permissions.'
    }
}

$purviewStatus = 'Not configured'
if ($ConfigurePurviewRoles) {
    try {
        Set-EDSetupPurviewRoles -ClientServicePrincipal $clientServicePrincipal -ClientId ([string]$app.appId) -Name $DisplayName -Administrator:$GrantEDiscoveryAdministrator
        $purviewStatus = $(if ($GrantEDiscoveryAdministrator) { 'Administrator assigned' } else { 'Manager assigned' })
    }
    catch {
        $purviewStatus = 'Incomplete'
        Write-Warning "Microsoft Purview role configuration failed: $($_.Exception.Message)"
        Write-Warning "Complete the New-ServicePrincipal, Add-RoleGroupMember and optional Add-eDiscoveryCaseAdmin steps in README.md."
    }
}

Write-Host ''
Write-Host 'Entra application setup results:'
[pscustomobject]@{
    DisplayName = $DisplayName
    TenantId = [string]$TenantId
    ClientId = [string]$app.appId
    ServicePrincipalObjectId = [string]$clientServicePrincipal.id
    CertificateThumbprint = $cert.Thumbprint
    CertificateStore = 'Cert:\CurrentUser\My'
    PublicCertificate = $publicCertificate
    CertificateExpires = $cert.NotAfter
    AdminConsent = $consentStatus
    PurviewRoles = $purviewStatus
}
Write-Host ''
Write-Host "Connect with: Connect-EDiscovery -TenantId '$TenantId' -ClientId '$($app.appId)' -CertificateThumbprint '$($cert.Thumbprint)'"
if ($consentStatus -ne 'Granted') {
    Write-Warning 'Next step: Entra App registrations > this app > API permissions > Grant admin consent.'
}
if ($purviewStatus -eq 'Not configured') {
    Write-Warning 'Next step: Register the service principal in Purview and assign eDiscovery roles; instructions are in README.md.'
}
Write-Warning 'App-only Graph eDiscovery access requires premium-enabled cases. Standard cases may not work with this app-based downloader.'
