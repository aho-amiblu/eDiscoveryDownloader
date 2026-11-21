#Requires -Version 7.2
Set-StrictMode -Version Latest

$script:EDConnection = $null
$script:EDPurviewToken = $null
$script:PurviewResourceAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'
$script:GraphBase = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'

function Get-EDProperty {
    param([AllowNull()][object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) { return $InputObject[$key] }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-EDConnected {
    if ($null -eq $script:EDConnection) {
        throw 'Not connected. Run Connect-EDiscovery first.'
    }
    $context = Get-MgContext
    if ($null -eq $context -or
        [string]$context.TenantId -ne $script:EDConnection.TenantId -or
        [string]$context.ClientId -ne $script:EDConnection.ClientId -or
        [string]$context.AuthType -ne 'AppOnly') {
        throw 'Microsoft Graph session does not match Connect-EDiscovery. Run Connect-EDiscovery again.'
    }
}

function Invoke-EDGraphGet {
    param([Parameter(Mandatory)][string]$Uri)
    Assert-EDConnected
    try {
        Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers @{ Prefer = 'include-unknown-enum-members' } -ErrorAction Stop
    }
    catch {
        throw "Microsoft Graph eDiscovery request failed: $($_.Exception.Message). Verify Graph eDiscovery.ReadWrite.All (Application), admin consent, and the application's Purview eDiscovery role/case access."
    }
}

function Get-EDGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)
    $next = $Uri
    $seen = @{}
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        if ($seen.ContainsKey($next)) { throw 'Graph returned a repeated pagination link.' }
        $seen[$next] = $true
        $page = Invoke-EDGraphGet -Uri $next
        foreach ($item in @(Get-EDProperty -InputObject $page -Name 'value')) {
            if ($null -ne $item) { Write-Output $item }
        }
        $next = [string](Get-EDProperty -InputObject $page -Name '@odata.nextLink')
        if ($next -and -not $next.StartsWith('https://graph.microsoft.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Graph returned an unexpected pagination URL; refusing to follow it.'
        }
    }
}

function Get-EDJwtClaims {
    param([Parameter(Mandatory)][string]$Jwt)
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { throw 'Could not inspect the Purview token.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'Invalid token encoding.' }
    }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Get-EDPurviewToken {
    if ($null -ne $script:EDPurviewToken -and
        $script:EDPurviewToken.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $script:EDPurviewToken
    }
    $auth = @{
        TenantId = $script:EDConnection.TenantId
        ClientId = $script:EDConnection.ClientId
        Scopes = @("$($script:PurviewResourceAppId)/.default")
        ErrorAction = 'Stop'
    }
    if ($script:EDConnection.AuthMethod -eq 'Certificate') {
        $auth.ClientCertificate = $script:EDConnection.Certificate
    }
    else {
        $auth.ClientSecret = $script:EDConnection.ClientSecret
    }
    try {
        $script:EDPurviewToken = Get-MsalToken @auth
    }
    catch {
        throw "Could not acquire the MicrosoftPurviewEDiscovery token: $($_.Exception.Message). Verify the eDiscovery.Download.Read application permission and admin consent."
    }
    return $script:EDPurviewToken
}

function Connect-EDiscovery {
    <#
    .SYNOPSIS
    Connect to Graph and Purview export downloads using a registered Entra application.
    .EXAMPLE
    Connect-EDiscovery -TenantId <tenant-guid> -ClientId <app-guid> -ClientSecret (Read-Host 'Client secret' -AsSecureString)
    .EXAMPLE
    Connect-EDiscovery -TenantId <tenant-guid> -ClientId <app-guid> -CertificateThumbprint <thumbprint>
    #>
    [CmdletBinding(DefaultParameterSetName = 'Certificate')]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$ClientId,
        [Parameter(Mandatory, ParameterSetName = 'Certificate')][string]$CertificateThumbprint,
        [Parameter(Mandatory, ParameterSetName = 'Secret')][securestring]$ClientSecret,
        [switch]$NoInstall,
        [switch]$SkipPermissionCheck
    )

    foreach ($module in @('Microsoft.Graph.Authentication', 'MSAL.PS')) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            if ($NoInstall) {
                throw "Required module $module is missing. Install-Module $module -Scope CurrentUser"
            }
            Write-Host "Installing missing module $module for CurrentUser..."
            Install-Module -Name $module -Scope CurrentUser -ErrorAction Stop
        }
        Import-Module -Name $module -ErrorAction Stop
    }

    $script:EDConnection = $null
    $script:EDPurviewToken = $null
    $connection = @{
        TenantId = [string]$TenantId
        ClientId = [string]$ClientId
    }
    $graphAuth = @{
        TenantId = [string]$TenantId
        ClientId = [string]$ClientId
        ContextScope = 'Process'
        NoWelcome = $true
        ErrorAction = 'Stop'
    }

    if ($PSCmdlet.ParameterSetName -eq 'Certificate') {
        $thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
        $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
        if (-not $cert.HasPrivateKey) { throw 'The selected certificate has no private key.' }
        $graphAuth.Certificate = $cert
        $connection.AuthMethod = 'Certificate'
        $connection.Certificate = $cert
    }
    else {
        $credential = [pscredential]::new([string]$ClientId, $ClientSecret)
        $graphAuth.Remove('ClientId')
        $graphAuth.ClientSecretCredential = $credential
        $connection.AuthMethod = 'Secret'
        $connection.ClientSecret = $ClientSecret
    }

    try {
        Connect-MgGraph @graphAuth | Out-Null
        $script:EDConnection = $connection
        if (-not $SkipPermissionCheck) {
            Test-EDiscoveryAccess | Out-Null
        }
    }
    catch {
        $script:EDConnection = $null
        $script:EDPurviewToken = $null
        throw
    }
    [pscustomobject]@{
        TenantId = $connection.TenantId
        ClientId = $connection.ClientId
        AuthMethod = $connection.AuthMethod
        Connected = $true
        PermissionCheck = $(if ($SkipPermissionCheck) { 'Skipped' } else { 'Passed' })
    }
}

function Test-EDiscoveryAccess {
    <#
    .SYNOPSIS
    Check Graph case-list access and the Purview download app role in its access token.
    .NOTES
    This cannot prove case-specific role assignment or download permission until an actual export is accessed.
    #>
    [CmdletBinding()]
    param()
    Assert-EDConnected
    $null = Invoke-EDGraphGet -Uri "$($script:GraphBase)?\$top=1"
    $token = Get-EDPurviewToken
    $claims = Get-EDJwtClaims -Jwt $token.AccessToken
    if (@(Get-EDProperty -InputObject $claims -Name 'roles') -notcontains 'eDiscovery.Download.Read') {
        throw "Purview token has no eDiscovery.Download.Read application role. Add MicrosoftPurviewEDiscovery > Application permission > eDiscovery.Download.Read and grant admin consent."
    }
    [pscustomobject]@{
        GraphCases = 'OK'
        PurviewDownloadAppRole = 'OK'
        CaseOperationAccess = 'Not yet tested'
        ActualDownload = 'Not yet tested'
    }
}

function Get-ExportList {
    <#
    .SYNOPSIS
    Lists generated export jobs in accessible Microsoft Purview eDiscovery cases.
    .EXAMPLE
    Get-ExportList
    .EXAMPLE
    Get-ExportList -CaseName 'Mailbox*' -Name '*Archive*' |
        Download-Export -DestinationFolder 'D:\eDiscovery'
    #>
    [CmdletBinding()]
    param(
        [string]$CaseName = '*',
        [string]$Name = '*',
        [string]$CaseId,
        [ValidateSet('all', 'succeeded', 'partiallySucceeded', 'running', 'failed', 'notStarted', 'submissionFailed')]
        [string]$Status = 'all'
    )
    Assert-EDConnected

    if ($CaseId) {
        $cases = @(Invoke-EDGraphGet -Uri "$($script:GraphBase)/$([uri]::EscapeDataString($CaseId))")
    }
    else {
        $cases = @(Get-EDGraphCollection -Uri $script:GraphBase)
    }
    foreach ($case in $cases) {
        $caseDisplay = [string](Get-EDProperty -InputObject $case -Name 'displayName')
        if ($caseDisplay -notlike $CaseName) { continue }
        $id = [string](Get-EDProperty -InputObject $case -Name 'id')
        $operationsUri = "$($script:GraphBase)/$([uri]::EscapeDataString($id))/operations"
        foreach ($item in @(Get-EDGraphCollection -Uri $operationsUri)) {
            $action = [string](Get-EDProperty -InputObject $item -Name 'action')
            if ($action -notin @('exportResult', 'contentExport', 'exportReport')) { continue }
            $operationId = [string](Get-EDProperty -InputObject $item -Name 'id')
            $details = Invoke-EDGraphGet -Uri "$operationsUri/$([uri]::EscapeDataString($operationId))"
            $state = [string](Get-EDProperty -InputObject $details -Name 'status')
            if ($Status -ne 'all' -and $state -ne $Status) { continue }
            $extra = Get-EDProperty -InputObject $details -Name 'additionalProperties'
            $display = $null
            foreach ($field in @('displayName', 'exportName', 'name', 'operationName', 'exportJobName')) {
                $display = Get-EDProperty -InputObject $details -Name $field
                if (-not $display) { $display = Get-EDProperty -InputObject $extra -Name $field }
                if ($display) { break }
            }
            if (-not $display) { $display = "Export $operationId" }
            if ([string]$display -notlike $Name) { continue }

            $metadata = Get-EDProperty -InputObject $details -Name 'exportFileMetadata'
            if ($null -eq $metadata) { $metadata = Get-EDProperty -InputObject $extra -Name 'exportFileMetadata' }
            $packages = @($metadata | Where-Object { $null -ne $_ })
            $bytes = [long]0
            foreach ($package in $packages) {
                $size = Get-EDProperty -InputObject $package -Name 'size'
                if ($null -eq $size) { $size = Get-EDProperty -InputObject $package -Name 'fileSize' }
                $parsed = [long]0
                if ([long]::TryParse([string]$size, [ref]$parsed)) { $bytes += $parsed }
            }

            [pscustomobject]@{
                PSTypeName = 'eDiscoveryDownloader.Export'
                Name = [string]$display
                CaseName = $caseDisplay
                Status = $state
                Created = (Get-EDProperty -InputObject $details -Name 'createdDateTime')
                Packages = $packages.Count
                SizeGB = [math]::Round($bytes / 1GB, 2)
                Action = $action
                CaseId = $id
                ExportId = $operationId
            }
        }
    }
}

function ConvertTo-EDSafeName {
    param([string]$Name)
    $result = ($Name -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($result)) { $result = 'Export' }
    if ($result.Length -gt 80) { $result = $result.Substring(0, 80).TrimEnd(' ', '.') }
    return $result
}

function Download-Export {
    <#
    .SYNOPSIS
    Downloads all ZIP packages/reports from an existing eDiscovery export.
    .EXAMPLE
    Get-ExportList -Name '*Former User*' | Download-Export -DestinationFolder 'D:\eDiscovery'
    .EXAMPLE
    Get-ExportList | Out-GridView -PassThru | Download-Export -DestinationFolder 'D:\eDiscovery'
    .EXAMPLE
    Get-ExportList | Download-Export -DestinationFolder 'D:\eDiscovery' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][psobject]$Export,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [string]$PackageName = '*',
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [switch]$Force,
        [switch]$NoSubfolder
    )
    begin {
        Assert-EDConnected
        $destinationRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationFolder)
    }
    process {
        if ($Export.PSTypeNames -notcontains 'eDiscoveryDownloader.Export') {
            throw 'Download-Export expects objects from Get-ExportList (use Get-ExportList | Download-Export).'
        }
        if ($Export.Status -notin @('succeeded', 'partiallySucceeded')) {
            Write-Warning "Skipping '$($Export.Name)' because its status is '$($Export.Status)'."
            return
        }

        $url = "$($script:GraphBase)/$([uri]::EscapeDataString([string]$Export.CaseId))/operations/$([uri]::EscapeDataString([string]$Export.ExportId))"
        $details = Invoke-EDGraphGet -Uri $url
        $extra = Get-EDProperty -InputObject $details -Name 'additionalProperties'
        $metadata = Get-EDProperty -InputObject $details -Name 'exportFileMetadata'
        if ($null -eq $metadata) { $metadata = Get-EDProperty -InputObject $extra -Name 'exportFileMetadata' }
        $packages = @($metadata | Where-Object { $null -ne $_ })
        if ($packages.Count -eq 0) {
            throw "No download packages are available for '$($Export.Name)'. It may not be ready or the 14-day export retention may have expired."
        }

        $exportFolder = $destinationRoot
        if (-not $NoSubfolder) {
            $shortId = [string]$Export.ExportId
            if ($shortId.Length -gt 8) { $shortId = $shortId.Substring(0, 8) }
            $exportFolder = Join-Path $destinationRoot "$(ConvertTo-EDSafeName $Export.CaseName)\$(ConvertTo-EDSafeName $Export.Name)_$shortId"
        }
        foreach ($package in $packages) {
            $fileName = [string](Get-EDProperty -InputObject $package -Name 'fileName')
            if ($fileName -notlike $PackageName) { continue }
            if ([string]::IsNullOrWhiteSpace($fileName) -or
                [IO.Path]::GetFileName($fileName) -cne $fileName -or
                $fileName -match '[<>:"/\\|?*\x00-\x1F]') {
                throw 'Export metadata contains an invalid or unsafe package file name.'
            }
            $downloadUrl = [string](Get-EDProperty -InputObject $package -Name 'downloadUrl')
            $downloadUri = $null
            if (-not [uri]::TryCreate($downloadUrl, [UriKind]::Absolute, [ref]$downloadUri) -or
                $downloadUri.Scheme -ne 'https' -or
                $downloadUri.Host -notmatch '(^|\.)(cloud\.microsoft|microsoft\.com|windows\.net)$') {
                throw "Unexpected package URL host for '$fileName'; refusing to send an access token."
            }
            $sizeText = Get-EDProperty -InputObject $package -Name 'size'
            if ($null -eq $sizeText) { $sizeText = Get-EDProperty -InputObject $package -Name 'fileSize' }
            $expectedBytes = [long]0
            $null = [long]::TryParse([string]$sizeText, [ref]$expectedBytes)
            $target = Join-Path $exportFolder $fileName
            if (-not $PSCmdlet.ShouldProcess($target, "Download export package")) { continue }

            $null = New-Item -Path $exportFolder -ItemType Directory -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $existingSize = (Get-Item -LiteralPath $target).Length
                if (-not $Force -and $expectedBytes -gt 0 -and $existingSize -eq $expectedBytes) {
                    Write-Verbose "Skipping existing file with matching size: $target"
                    [pscustomobject]@{ ExportName = $Export.Name; FileName = $fileName; Path = $target; Status = 'Skipped'; SizeBytes = $existingSize }
                    continue
                }
                if (-not $Force) { throw "File already exists (size differs or size is unknown): $target. Use -Force to replace it." }
            }

            $part = "$target.partial"
            $success = $false
            for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction Stop }
                    $token = Get-EDPurviewToken
                    $headers = @{
                        Authorization = "Bearer $($token.AccessToken)"
                        'X-AllowWithAADToken' = 'true'
                    }
                    Write-Progress -Activity "Downloading $($Export.Name)" -Status "$fileName (attempt $attempt/$RetryCount)"
                    $null = Invoke-WebRequest -Method GET -Uri $downloadUrl -Headers $headers -OutFile $part -ErrorAction Stop
                    $actualBytes = (Get-Item -LiteralPath $part -ErrorAction Stop).Length
                    if ($expectedBytes -gt 0 -and $actualBytes -ne $expectedBytes) {
                        throw "Size mismatch for '$fileName': expected $expectedBytes bytes, received $actualBytes."
                    }
                    if ($fileName.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
                        $stream = [IO.File]::OpenRead($part)
                        try {
                            if ($stream.ReadByte() -ne 80 -or $stream.ReadByte() -ne 75) {
                                throw "Response for '$fileName' was not a ZIP file (possibly an authentication redirect)."
                            }
                        }
                        finally { $stream.Dispose() }
                    }
                    [IO.File]::Move($part, $target, [bool]$Force)
                    [pscustomobject]@{ ExportName = $Export.Name; FileName = $fileName; Path = $target; Status = 'Downloaded'; SizeBytes = $actualBytes }
                    $success = $true
                    break
                }
                catch {
                    Write-Warning "Download attempt $attempt/$RetryCount failed for '$fileName': $($_.Exception.Message)"
                    $script:EDPurviewToken = $null
                    if ($attempt -lt $RetryCount) { Start-Sleep -Seconds ([math]::Min($attempt * 2, 10)) }
                }
            }
            if (-not $success) {
                throw "Could not download '$fileName' after $RetryCount attempts. Check permissions, export expiry, and network access. Any .partial file is incomplete."
            }
        }
        Write-Progress -Activity "Downloading $($Export.Name)" -Completed
    }
}

Export-ModuleMember -Function Connect-EDiscovery, Test-EDiscoveryAccess, Get-ExportList, Download-Export
