#Requires -Version 7.2
# Run: Install-Module Pester -Scope CurrentUser; Invoke-Pester ./tests
# These tests deliberately do not access a tenant or create an application.

Describe 'Entra app provisioning script' {
    BeforeAll {
        $script:setupScript = Join-Path $PSScriptRoot '..' 'scripts' 'New-EDiscoveryDownloaderApp.ps1'
        $script:source = Get-Content -LiteralPath $script:setupScript -Raw
    }

    It 'has valid PowerShell syntax' {
        $tokens = $null
        $syntaxErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script:setupScript,
            [ref]$tokens,
            [ref]$syntaxErrors
        )
        @($syntaxErrors).Count | Should -Be 0
    }

    It 'uses a non-exportable certificate instead of generating a client secret' {
        $script:source | Should -Match 'KeyExportPolicy NonExportable'
        $script:source | Should -Match 'New-SelfSignedCertificate'
        $script:source | Should -Not -Match 'AddPassword|New-MgApplicationPassword'
    }

    It 'keeps tenant-wide consent and eDiscovery Administrator opt-in' {
        $script:source | Should -Match '\[switch\]\$GrantAdminConsent'
        $script:source | Should -Match '\[switch\]\$GrantEDiscoveryAdministrator'
        $script:source | Should -Match '\$GrantEDiscoveryAdministrator -and -not \$ConfigurePurviewRoles'
        $script:source | Should -Match 'SupportsShouldProcess'
    }

    It 'requests only the two application permissions needed by the downloader' {
        $script:source | Should -Match 'eDiscovery\.ReadWrite\.All'
        $script:source | Should -Match 'eDiscovery\.Download\.Read'
    }
}
