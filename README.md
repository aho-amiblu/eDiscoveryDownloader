# eDiscoveryDownloader

PowerShell 7 module for **listing existing Microsoft Purview eDiscovery exports** and downloading **every package** from selected jobs. Based on [Microsoft's current Graph + Purview API examples](https://learn.microsoft.com/en-us/purview/edisc-ref-api-guide).

> [!IMPORTANT]
> This downloads already-generated export ZIP packages (which may contain PSTs). It does **not** create a new search/export, extract PSTs, or bypass Purview permissions. Export packages normally expire after **14 days**. The API requires **app-only authentication**, and Microsoft documents this for **cases with premium features enabled**. Cases without premium features may require a different workflow. Test access with your specific case first.

## Quick start

Use **PowerShell 7.2+ on Windows**. Open PowerShell in the cloned repository:

```powershell
Import-Module .\eDiscoveryDownloader.psm1

# One-time setup: authenticate with an Entra app and a client secret
Connect-EDiscovery -TenantId '<tenant-guid>' -ClientId '<app-guid>' `
    -ClientSecret (Read-Host 'Client secret' -AsSecureString)

# Show exports from accessible cases
Get-ExportList | Format-Table Name,CaseName,Status,Packages,SizeGB,Created

# Download one export, chosen interactively
Get-ExportList | Out-GridView -PassThru |
    Download-Export -DestinationFolder 'D:\eDiscovery'

# Or choose by name / case and download all matches
Get-ExportList -CaseName 'Mailbox Archives' -Name '*Former*' |
    Download-Export -DestinationFolder 'D:\eDiscovery'

# Preview intended files without downloading
Get-ExportList -Status succeeded |
    Download-Export -DestinationFolder 'D:\eDiscovery' -WhatIf
```

**Recommended:** Use a certificate instead of a client secret:

```powershell
Connect-EDiscovery -TenantId '<tenant-guid>' -ClientId '<app-guid>' `
    -CertificateThumbprint '<thumbprint>'
```

Certificate must be installed with a private key in **CurrentUser\Personal (My)**. Do not put client secrets or PSTs in GitHub. No credentials are committed by this project.

## From Purview's "Download support information" JSON

**Fastest route if you already know the export:** In Purview, open the completed export, select **Download support information**, and save the resulting JSON as support.json. Its jobId is the Graph export operation ID. You do **not** need to call Get-ExportList.

~~~powershell
Import-Module .\eDiscoveryDownloader.psm1

# Authenticate with your configured Entra application, as explained above:
Connect-EDiscovery -TenantId '<tenant-guid>' -ClientId '<app-guid>' -ClientSecret (Read-Host 'Client secret' -AsSecureString)

Import-ExportSupportInfo -Path '.\support.json' |
    Download-Export -DestinationFolder 'D:\eDiscovery'

# Or paste the support JSON into your clipboard:
Get-Clipboard -Raw | Import-ExportSupportInfo |
    Download-Export -DestinationFolder 'D:\eDiscovery'
~~~

Import-ExportSupportInfo only parses and validates the support JSON, mapping caseId and jobId to a downloadable export object. It does not contain download URLs or access credentials. **The existing app authentication is still required for Download-Export.** The command checks that the support JSON's tenant matches the connected tenant. An interactive user can also use Microsoft Graph PowerShell to retrieve package metadata without a custom app registration (subject to delegated permissions), but downloading through the separate Purview API still requires appropriate authentication.

## One-time Entra / Purview configuration

The module installs missing `Microsoft.Graph.Authentication` and `MSAL.PS` modules for CurrentUser (use `-NoInstall` to prevent this), but **cannot grant itself tenant permissions**.

1. Register a single-tenant application under **Entra admin center → App registrations**, and configure a certificate or client secret.
2. Grant **Microsoft Graph application permission `eDiscovery.ReadWrite.All`**, and **admin consent**. The Microsoft Graph API documents these requirements for retrieving full case-operation details; this is broad, write-capable permission even though this module only makes **GET** requests. Treat the app credential as privileged.
3. Ensure the **MicrosoftPurviewEDiscovery** enterprise app/service principal exists (application ID `b26e684c-5068-4120-a679-64a5d2c909d9`). If needed, register its service principal as described in the [Microsoft guide](https://learn.microsoft.com/en-us/purview/edisc-ref-api-guide).
4. Under your app's **API permissions → APIs my organization uses**, select **MicrosoftPurviewEDiscovery → Application permissions → `eDiscovery.Download.Read`**, and grant admin consent.
5. Register your application as a **Purview eDiscovery service principal** and assign the appropriate eDiscovery role/case permissions, following [Microsoft's app-only setup documentation](https://learn.microsoft.com/en-us/purview/edisc-ref-api-guide). For least privilege, restrict case access where possible. Microsoft notes that app-only API access requires eDiscovery cases with **premium features enabled**.

Check configuration:

```powershell
Test-EDiscoveryAccess
Get-ExportList -CaseName 'My Case'
```

`Connect-EDiscovery` runs the initial permission check automatically. It checks Graph case listing and that the Purview token has the download role, but **cannot guarantee specific case access or successful package download** until those actions are attempted. Use `-SkipPermissionCheck` for diagnosis only.

## Command reference

| Command | Parameters | Notes |
| --- | --- | --- |
| `Connect-EDiscovery` | `-TenantId`, `-ClientId`, **either** `-CertificateThumbprint` **or** `-ClientSecret`, `-NoInstall`, `-SkipPermissionCheck` | App-only connection, auto-install required modules |
| `Test-EDiscoveryAccess` | none | Checks Graph case listing and token role |
| Import-ExportSupportInfo | -Path or JSON from pipeline | Parses support JSON directly into a pipeline-ready export object |
| `Get-ExportList` | `-CaseName`, `-CaseId`, `-Name`, `-Status` | Lists exports across accessible cases, follows Graph paging |
| `Download-Export` | `-Export` (pipeline), **`-DestinationFolder`**, `-PackageName`, `-RetryCount`, `-Force`, `-NoSubfolder`, `-WhatIf` | Downloads all matching packages, returns one result object per package |

Examples:

```powershell
$exports = @(Get-ExportList -Status succeeded)
$exports | Select-Object Name,CaseName,ExportId
$exports[0] | Download-Export -DestinationFolder 'E:\PST'

# Download only package names matching a pattern
Get-ExportList -Name '*Finance*' | Download-Export -DestinationFolder 'E:\PST' -PackageName '*.zip'

# Replace existing files and retry transient failures
Get-ExportList -CaseId '<case-guid>' | Download-Export -DestinationFolder 'E:\PST' -Force -RetryCount 5 -Verbose

# Download ALL eligible exports (be careful with disk space!)
Get-ExportList -Status succeeded | Download-Export -DestinationFolder 'E:\PST'
```

Each export gets its own `<destination>\<safe case name>\<safe export name>_<id>\` folder unless `-NoSubfolder` is specified. The script handles retries and token refresh, writes to `.partial` first, verifies the reported file size (where provided), and skips existing files only when the size matches. `-Force` overwrites existing downloads. It avoids sending tokens to unexpected hosts.

A `partiallySucceeded` job may still contain useful packages, but review the Purview export report for errors or missing items.

## Troubleshooting

- **401 / 403 / permission errors:** verify Graph permission **and** Purview download permission, admin consent, and Purview role/case assignment. App-only access on a non-premium case may be unsupported.
- **No exports:** `Get-ExportList` lists case operation actions `exportResult`, `contentExport`, and `exportReport`. Verify the case ID and exported operation in Purview using **Copy support information**.
- **No packages:** the export may not have finished, or its download retention may have expired.
- **Incorrect package size:** download is retried; an incomplete `.partial` file is never renamed to a finished ZIP.
- **Existing file:** rerun with `-Force` to replace, or keep the existing file if its reported size matches.
- **Unsupported URL host:** the downloader intentionally refuses to attach an access token to a new/unrecognized domain; review Microsoft's current endpoint and update the allowlist only after verification.
- **Large ZIP downloads:** `Invoke-WebRequest` downloads one package at a time. Interrupted package downloads are retried from the beginning, not resumed via byte ranges.

## Security and scope

This project is a helper for **authorized administrators**. Downloaded mailbox exports contain sensitive personal and company data. Store them on encrypted storage with restricted access and apply your retention policy. Avoid logging bearer tokens or pre-authorized download URLs. Review third-party code before using it with privileged app credentials.

This project is independent of Microsoft and is not yet validated against a live tenant. Public module imports/syntax should be verified in your environment before production use.

**Source:** [Microsoft Purview eDiscovery API guide and example scripts](https://learn.microsoft.com/en-us/purview/edisc-ref-api-guide)
