#Requires -Version 7.2
# Run with: Invoke-Pester ./tests (requires Pester 5)
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'eDiscoveryDownloader.psm1') -Force
}

Describe 'eDiscoveryDownloader helpers' {
    InModuleScope eDiscoveryDownloader {
        It 'reads dictionary properties case-insensitively' {
            Get-EDProperty -InputObject @{ 'FileNAME' = 'archive.zip' } -Name 'filename' |
                Should -Be 'archive.zip'
        }
        It 'replaces Windows-unsafe filename characters' {
            ConvertTo-EDSafeName -Name 'case:folder/name?' |
                Should -Be 'case_folder_name_'
        }
        It 'refuses to proceed without a connection' {
            $script:EDConnection = $null
            { Assert-EDConnected } | Should -Throw '*Not connected*'
        }
        It 'rejects malformed JWT payloads' {
            { Get-EDJwtClaims -Jwt 'bad-token' } | Should -Throw
        }
    }
}

Describe 'Get-ExportList result shape' {
    InModuleScope eDiscoveryDownloader {
        BeforeEach {
            $script:EDConnection = @{ TenantId = 'test'; ClientId = 'test' }
            Mock Assert-EDConnected {}
            Mock Get-EDGraphCollection {
                param($Uri)
                if ($Uri -match '/operations$') {
                    return @(
                        @{ id = 'job1'; action = 'exportResult' },
                        @{ id = 'hold1'; action = 'applyHold' }
                    )
                }
                return @(@{ id = 'case1'; displayName = 'Mailbox Archives' })
            }
            Mock Invoke-EDGraphGet {
                param($Uri)
                return @{
                    id = 'job1'
                    action = 'exportResult'
                    status = 'succeeded'
                    createdDateTime = '2026-11-01T00:00:00Z'
                    additionalProperties = @{
                        displayName = 'Former User Mailbox'
                        exportFileMetadata = @(
                            @{ fileName = 'Mailbox_001.zip'; size = '1073741824'; downloadUrl = 'https://example.blob.core.windows.net/file' }
                        )
                    }
                }
            }
        }
        It 'lists only exports and exposes pipeline identifiers' {
            $result = @(Get-ExportList)
            $result.Count | Should -Be 1
            $result[0].PSTypeNames | Should -Contain 'eDiscoveryDownloader.Export'
            $result[0].Name | Should -Be 'Former User Mailbox'
            $result[0].ExportId | Should -Be 'job1'
            $result[0].CaseId | Should -Be 'case1'
            $result[0].Packages | Should -Be 1
            $result[0].SizeGB | Should -Be 1
        }
        It 'filters export names and statuses' {
            @(Get-ExportList -Name '*missing*').Count | Should -Be 0
            @(Get-ExportList -Name '*Former*' -Status succeeded).Count | Should -Be 1
            @(Get-ExportList -Status failed).Count | Should -Be 0
        }
    }
}

Describe 'Download-Export safeguards' {
    InModuleScope eDiscoveryDownloader {
        BeforeEach {
            $script:EDConnection = @{ TenantId = 'test'; ClientId = 'test' }
            Mock Assert-EDConnected {}
            Mock Invoke-EDGraphGet {
                return @{
                    exportFileMetadata = @(
                        @{ fileName = 'file.zip'; size = '5'; downloadUrl = 'https://evil.example/file.zip' }
                    )
                }
            }
            $script:testExport = [pscustomobject]@{
                PSTypeName = 'eDiscoveryDownloader.Export'
                Name = 'Example'
                CaseName = 'Example Case'
                CaseId = 'case1'
                ExportId = 'job1'
                Status = 'succeeded'
            }
        }
        It 'refuses to send tokens to unapproved hosts' {
            { $script:testExport | Download-Export -DestinationFolder (Join-Path $TestDrive 'out') -Confirm:$false } |
                Should -Throw '*Unexpected package URL host*'
        }
        It 'does not access Graph for unfinished exports' {
            $script:testExport.Status = 'running'
            $script:testExport | Download-Export -DestinationFolder (Join-Path $TestDrive 'out') -WarningAction SilentlyContinue
            Should -Invoke Invoke-EDGraphGet -Times 0
        }
    }
}


Describe 'Import-ExportSupportInfo' {
    InModuleScope eDiscoveryDownloader {
        BeforeAll {
            $script:sampleSupportJson = @{
                tenantId = 'abe233c7-2098-4409-91fc-b0da584aef6b'
                caseId = 'ccec2be3-f6c4-4ced-b513-6c3629af2b28'
                jobId = '94eb8fcee6c043b383cbc2a76ba32826'
                jobState = 'Completed'
                jobName = 'DirectExport'
                created = '2026-11-20T09:08:56Z'
            } | ConvertTo-Json
        }
        It 'accepts support JSON on the pipeline' {
            $export = $script:sampleSupportJson | Import-ExportSupportInfo
            $export.PSTypeNames | Should -Contain 'eDiscoveryDownloader.Export'
            $export.CaseId | Should -Be 'ccec2be3-f6c4-4ced-b513-6c3629af2b28'
            $export.ExportId | Should -Be '94eb8fcee6c043b383cbc2a76ba32826'
            $export.Status | Should -Be 'succeeded'
        }
        It 'accepts support JSON from a file' {
            $path = Join-Path $TestDrive 'support.json'
            Set-Content -LiteralPath $path -Value $script:sampleSupportJson
            (Import-ExportSupportInfo -Path $path).Name | Should -Be 'DirectExport'
        }
        It 'rejects missing job IDs' {
            $invalid = @{ tenantId = 'abe233c7-2098-4409-91fc-b0da584aef6b'; caseId = 'ccec2be3-f6c4-4ced-b513-6c3629af2b28' } | ConvertTo-Json
            { $invalid | Import-ExportSupportInfo } | Should -Throw '*valid jobId*'
        }
        It 'checks tenant matches when downloading' {
            $script:EDConnection = @{ TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; ClientId = 'test' }
            Mock Assert-EDConnected {}
            Mock Invoke-EDGraphGet { throw 'Should not call Graph for a mismatched tenant' }
            $export = $script:sampleSupportJson | Import-ExportSupportInfo
            { $export | Download-Export -DestinationFolder (Join-Path $TestDrive 'export') -Confirm:$false } |
                Should -Throw '*Support information is for tenant*'
            Should -Invoke Invoke-EDGraphGet -Times 0
        }
    }
}
