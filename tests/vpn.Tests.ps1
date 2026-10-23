$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot 'main.bicep'
$source = Join-Path $repoRoot 'scripts\vpn.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$realInvokeAz = (Get-Command Invoke-Az).ScriptBlock
$SubscriptionId = '662141d0-0308-4187-b46b-db1e9466b5ac'
$ResourceGroupName = 'test-rg'
$DeploymentName = 'test-vpn'
$baseId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network"
$parameterPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vpn-tests-{0}.json" -f [guid]::NewGuid())
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message, [string]$Name)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -like "*$Message*") "$Name (received: $caught)"
}

function Reset-Fixture {
    $script:configuration = (Get-Content (Join-Path $repoRoot 'main.parameters.example.json') -Raw).
        Replace('CHANGE-ME', 'jaropro') | ConvertFrom-Json
    $script:collections = @{
        virtualNetworks = @()
        localNetworkGateways = @()
        virtualNetworkGateways = @()
        virtualHubs = @()
        vpnSites = @()
    }
    $script:responses = @{}
    $script:failType = ''
    $script:calls = [System.Collections.Generic.List[object]]::new()
    $script:LocalOnly = $false
    $script:Mode = 'Validate'
    $script:whatIfResponse = '{"changes":[{"changeType":"Create","resourceId":"/test/resource"}]}'
    $script:resourcesJson = '[]'
}

function New-Vnet {
    param([string]$Id, [string[]]$Prefixes, [string]$Owner = '')
    return [pscustomobject]@{
        id = $Id
        tags = @{ Solution = $Owner }
        properties = @{
            addressSpace = @{ addressPrefixes = $Prefixes }
            subnets = @()
            virtualNetworkPeerings = @()
        }
    }
}

function Invoke-Az {
    param([string[]]$Arguments)
    $script:calls.Add($Arguments)
    switch ($Arguments[0]) {
        'bicep' { return }
        'account' { return $SubscriptionId }
        'group' { return 'true' }
        'resource' { return $resourcesJson }
        'keyvault' { return '/test/keyvault' }
        'deployment' {
            if ('--no-pretty-print' -notin $Arguments) { return 'Note: human-readable what-if output' }
            return $whatIfResponse
        }
        'rest' {
            $url = $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            if ($responses.ContainsKey($url)) { return $responses[$url] }
            if ($url -match '/providers/Microsoft.Network/virtualNetworkGateways/[^/?]+\?') {
                $id = ($url -split '\?')[0].Replace('https://management.azure.com', '')
                $gateway = @($collections.virtualNetworkGateways | Where-Object { $_.id -eq $id })
                if ($gateway.Count -ne 1) { throw "Unexpected gateway detail URL: $url" }
                return ($gateway[0] | ConvertTo-Json -Depth 30)
            }
            if ($url -notmatch '/providers/Microsoft.Network/([^/?]+)\?') {
                throw "Unexpected inventory URL: $url"
            }
            $type = $Matches[1]
            if ($type -eq $failType) { throw 'Inventory permission denied' }
            if (-not $collections.ContainsKey($type)) { throw "Unexpected collection: $type" }
            return (@{ value = @($collections[$type]) } | ConvertTo-Json -Depth 30)
        }
        default { throw "Unexpected Azure command: $($Arguments -join ' ')" }
    }
}

try {
    Reset-Fixture
    Assert-True (Test-RangeOverlap (ConvertTo-IPv4Range '10.100.0.0/24') (ConvertTo-IPv4Range '10.100.0.128/25')) 'contained CIDR overlaps'
    Assert-True (Test-RangeOverlap (ConvertTo-IPv4Range '10.100.0.128/25') (ConvertTo-IPv4Range '10.100.0.0/24')) 'reverse containment overlaps'
    Assert-True (-not (Test-RangeOverlap (ConvertTo-IPv4Range '10.100.0.0/25') (ConvertTo-IPv4Range '10.100.0.128/25'))) 'adjacent ranges do not overlap'
    Assert-True (Test-RangeOverlap @{ Start = 10; End = 20 } @{ Start = 15; End = 25 }) 'partial interval overlap'
    Assert-True (Test-RangeContains (ConvertTo-IPv4Range '10.100.0.0/24') (ConvertTo-IPv4Range '10.100.0.0/27')) 'gateway contained in hub'

    $collections.virtualNetworks = @(
        (New-Vnet "$baseId/virtualNetworks/vnet-superag-eastus" @('10.0.0.0/16')),
        (New-Vnet "$baseId/virtualNetworks/vnet-finopsazure" @('10.30.0.0/16'))
    )
    Assert-AzureAddressAvailability $configuration $ResourceGroupName
    Assert-True ($calls.Count -eq 5) 'nonconflicting inventory queried all five collections'
    $collections.virtualNetworks += New-Vnet "$baseId/virtualNetworks/other" @('10.101.0.128/25') 'hybrid-vpn-bicep'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Address conflict' 'contained external prefix conflicts despite ownership tag'

    Reset-Fixture
    $own = New-Vnet "$baseId/virtualNetworks/jaropro-hub-vnet" @('10.100.0.0/24') 'hybrid-vpn-bicep'
    $own.properties.subnets = @(@{
        id = "$($own.id)/subnets/GatewaySubnet"
        name = 'GatewaySubnet'
        properties = @{ addressPrefix = '10.100.0.0/27' }
    })
    $collections.virtualNetworks = @($own)
    $collections.localNetworkGateways = @(@{
        id = "$baseId/localNetworkGateways/jaropro-office-01-lng"
        tags = @{ Solution = 'hybrid-vpn-bicep' }
        properties = @{ localNetworkAddressSpace = @{ addressPrefixes = @('192.168.50.0/24') } }
    })
    Assert-AzureAddressAvailability $configuration $ResourceGroupName
    Assert-True $true 'unchanged exact owned VNet, subnet and LNG redeploy permitted'
    $own.tags.Solution = ''
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'not solution-owned' 'exact ID without ownership rejected'
    $own.tags.Solution = 'hybrid-vpn-bicep'
    $own.properties.addressSpace.addressPrefixes = @('10.110.0.0/24')
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Addressing change blocked' 'owned VNet renumbering rejected'
    $own.properties.addressSpace.addressPrefixes = @('10.100.0.0/24')
    $own.properties.subnets[0].properties.addressPrefix = '10.100.0.32/27'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Addressing change blocked' 'owned subnet renumbering rejected'
    $own.properties.subnets[0].name = 'unknown-subnet'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Removal of existing subnet' 'owned subnet removal rejected'
    $own.properties.subnets = @()
    $collections.localNetworkGateways[0].properties.localNetworkAddressSpace.addressPrefixes = @('192.168.60.0/24')
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Addressing change blocked' 'owned LNG renumbering rejected'

    Reset-Fixture
    $collections.localNetworkGateways = @(@{
        id = "$baseId/localNetworkGateways/other"
        properties = @{ localNetworkAddressSpace = @{ addressPrefixes = @('192.168.50.128/25') } }
    })
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Address conflict' 'external S2S LAN conflict'
    $collections.localNetworkGateways = @()
    $collections.virtualNetworkGateways = @(@{
        id = "$baseId/virtualNetworkGateways/other"
        properties = @{ vpnClientConfiguration = @{ vpnClientAddressPool = @{ addressPrefixes = @('10.102.0.0/25') } } }
    })
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Address conflict' 'P2S pool conflict'
    $collections.virtualNetworkGateways[0].id = "$baseId/virtualNetworkGateways/jaropro-vpn-gateway"
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'preserve its addressing' 'existing own P2S configuration is never silently removed'
    $collections.virtualNetworkGateways[0].id = "$baseId/virtualNetworkGateways/other"
    $collections.virtualNetworkGateways[0].properties.vpnClientConfiguration = @{}
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Missing P2S address pool' 'incomplete P2S inventory stops preflight'

    Reset-Fixture
    $gatewayId = "$baseId/virtualNetworkGateways/jaropro-vpn-gateway"
    $collections.virtualNetworkGateways = @(@{
        id = $gatewayId
        properties = @{ vpnClientConfiguration = @{ vpnClientProtocols = @('OpenVPN', 'IkeV2') } }
    })
    $gatewayUrl = "https://management.azure.com${gatewayId}?api-version=2024-05-01"
    $responses[$gatewayUrl] = (@{ id = $gatewayId; properties = @{ vpnClientConfiguration = $null } } | ConvertTo-Json -Depth 10)
    Assert-AzureAddressAvailability $configuration $ResourceGroupName
    Assert-True ($calls.Count -eq 6) 'gateway detail confirms absent P2S despite list API default fields'
    $responses[$gatewayUrl] = '{}'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Incomplete gateway detail' 'malformed gateway detail cannot bypass P2S checks'
    $responses.Remove($gatewayUrl)
    $collections.virtualNetworkGateways = @()
    Assert-Throws { Invoke-Az @('rest', '--method', 'get', '--url', $gatewayUrl) } 'Unexpected gateway detail' 'inaccessible gateway detail is not a success-shaped fallback'

    Reset-Fixture
    $remoteId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/remote/providers/Microsoft.Network/virtualNetworks/remote'
    $local = New-Vnet "$baseId/virtualNetworks/local" @('10.0.0.0/16')
    $local.properties.virtualNetworkPeerings = @(@{ properties = @{ remoteVirtualNetwork = @{ id = $remoteId } } })
    $collections.virtualNetworks = @($local)
    $responses["https://management.azure.com${remoteId}?api-version=2024-05-01"] = (
        New-Vnet $remoteId @('10.100.0.0/25') | ConvertTo-Json -Depth 20
    )
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Address conflict' 'remote peering live range conflict'
    $responses.Clear()
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Unexpected inventory URL' 'inaccessible remote VNet stops preflight'

    Reset-Fixture
    $failType = 'virtualNetworkGateways'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'permission denied' 'inventory query error stops preflight'
    Reset-Fixture
    $firstUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Network/virtualNetworks?api-version=2024-05-01"
    $responses[$firstUrl] = '{}'
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Invalid network inventory' 'malformed inventory is not empty success'
    $responses[$firstUrl] = (@{ value = @((New-Vnet "$baseId/virtualNetworks/empty" @(''))) } | ConvertTo-Json -Depth 20)
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Missing VNet address space' 'empty inventory prefix is not silently skipped'
    $responses[$firstUrl] = '{"value":[],"nextLink":"https://management.azure.com/test-next-page"}'
    $responses['https://management.azure.com/test-next-page'] = (@{
        value = @((New-Vnet "$baseId/virtualNetworks/page2" @('10.100.0.0/25')))
    } | ConvertTo-Json -Depth 20)
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Address conflict' 'pagination includes conflicting second page'

    Reset-Fixture
    $collections.virtualHubs = @(@{ id = "$baseId/virtualHubs/hub"; properties = @{} })
    Assert-Throws { Assert-AzureAddressAvailability $configuration $ResourceGroupName } 'Virtual WAN' 'Virtual WAN requires separate review'

    Reset-Fixture
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    $LocalOnly = $true
    $localOutput = @(Assert-Configuration 3>&1)
    $result = $localOutput | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
    $localWarnings = @($localOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert-True ($result.ActiveSubscription -eq 'not checked (LocalOnly)' -and $calls.Count -eq 1 -and $calls[0][0] -eq 'bicep') 'LocalOnly builds without Azure inventory'
    Assert-True ("$localWarnings" -like '*availability*NOT checked*') 'LocalOnly explicitly warns about availability'
    $Mode = 'WhatIf'
    Assert-Throws { Assert-Configuration } 'LocalOnly is supported only with Validate' 'WhatIf cannot bypass inventory'
    $Mode = 'Deploy'
    Assert-Throws { Assert-Configuration } 'LocalOnly is supported only with Validate' 'Deploy preflight cannot bypass inventory (no deployment invoked)'
    $Mode = 'Validate'
    $LocalOnly = $false
    $null = Assert-Configuration
    Assert-True (@($calls | Where-Object { $_[0] -eq 'rest' }).Count -eq 5) 'remote Validate runs inventory'
    $SubscriptionId = ''
    Assert-Throws { Assert-Configuration } 'explicit SubscriptionId' 'subscription is mandatory'
    $SubscriptionId = '662141d0-0308-4187-b46b-db1e9466b5ac'
    $LocalOnly = $true
    foreach ($excluded in @('192.168.4.0/24', '192.168.44.0/24', '192.168.5.0/29')) {
        $configuration.parameters.offices.value[0].addressPrefixes = @($excluded)
        $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
        Assert-Throws { Assert-Configuration } 'excluded jaropro ISP/transit' "$excluded cannot be advertised"
    }
    $configuration.parameters.offices.value[0].addressPrefixes = @('192.168.0.0/16')
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'excluded jaropro ISP/transit' 'aggregate containing transit cannot be advertised'
    $configuration.parameters.offices.value[0].addressPrefixes = @('192.168.50.0/24')
    $configuration.parameters.vpnGatewayGeneration.value = 'Generation2'
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'requires Generation1' 'VpnGw1AZ Generation2 rejected'
    $scriptText = Get-Content -LiteralPath $source -Raw
    foreach ($modeName in @('Validate', 'WhatIf', 'Deploy')) {
        $dispatchPattern = [regex]::Escape("'$modeName' {") + '\s+\$(?:validation|null) = Assert-Configuration'
        Assert-True ($scriptText -match $dispatchPattern) "$modeName dispatch starts with shared preflight"
    }

    Reset-Fixture
    $configuration.parameters.manageConnections.value = $false
    $configuration.parameters.PSObject.Properties.Remove('keyVaultName')
    $configuration.parameters.offices.value[0].PSObject.Properties.Remove('pskSecretName')
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    $manualOutput = @(Assert-Configuration 3>&1)
    Assert-True (@($calls | Where-Object { $_[0] -eq 'keyvault' }).Count -eq 0) 'manual mode requires no Key Vault and makes no vault queries'
    Assert-True (@($calls | Where-Object { $_[0] -eq 'rest' }).Count -eq 5) 'manual mode still checks all network inventory'
    Assert-True ("$($manualOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })" -like '*no tunnel is established*') 'manual mode explicitly warns that IPsec is deferred'
    $configuration.parameters.offices.value[0].addressPrefixes = @('10.100.0.0/24')
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'overlaps Azure prefix' 'manual mode cannot bypass LAN overlap validation'
    $configuration.parameters.offices.value[0] | Add-Member -NotePropertyName sharedKey -NotePropertyValue 'not-a-real-secret'
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'not PSKs' 'manual mode still rejects inline shared keys'

    Reset-Fixture
    $configuration.parameters.manageConnections.value = 'false'
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'JSON boolean' 'string false is not a valid manual-mode switch'
    Reset-Fixture
    $configuration.parameters.PSObject.Properties.Remove('manageConnections')
    $configuration.parameters.PSObject.Properties.Remove('keyVaultName')
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'existing Key Vault' 'omitted mode preserves the managed Key Vault requirement'
    Reset-Fixture
    $configuration.parameters.offices.value[0].PSObject.Properties.Remove('pskSecretName')
    $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterPath
    Assert-Throws { Assert-Configuration } 'must name its PSK secret' 'managed mode still requires office secret names'

    Reset-Fixture
    $resourcesJson = '[{"id":"/test/connection","name":"jaropro-office-01-connection","type":"Microsoft.Network/connections","tags":{}}]'
    Assert-OwnedResourceNames -ResourceGroup $ResourceGroupName -Prefix 'jaropro' -ManageConnections $false
    Assert-True ($calls.Count -eq 1) 'manual connections without ownership tags are preserved on redeploy'
    Assert-Throws { Assert-OwnedResourceNames -ResourceGroup $ResourceGroupName -Prefix 'jaropro' } 'Resource collision' 'managed mode rejects taking over an unowned connection'
    $resourcesJson = '[{"id":"/test/vnet","name":"jaropro-hub-vnet","type":"Microsoft.Network/virtualNetworks","tags":{}}]'
    Assert-Throws { Assert-OwnedResourceNames -ResourceGroup $ResourceGroupName -Prefix 'jaropro' -ManageConnections $false } 'Resource collision' 'manual mode still protects unowned infrastructure'

    Reset-Fixture
    $whatIfResult = Invoke-WhatIf | ConvertFrom-Json
    Assert-True ($whatIfResult.changes[0].changeType -eq 'Create') 'WhatIf parses structured CLI output'
    Assert-True ('--no-pretty-print' -in $calls[0]) 'WhatIf disables human-readable formatting'
    $whatIfResponse = '{"changes":[{"changeType":"Delete","resourceId":"/test/resource"}]}'
    Assert-Throws { Invoke-WhatIf } 'contains a deletion' 'WhatIf still blocks deletions'
    $whatIfResponse = '{}'
    Assert-Throws { Invoke-WhatIf } 'did not contain a changes list' 'WhatIf still rejects missing changes'

    # Exercise the real command wrapper with a fake CLI; no process or Azure calls.
    function az {
        $script:cliArguments = @($args)
        $global:LASTEXITCODE = 0
        return 'ok'
    }
    $null = & $realInvokeAz -Arguments @('group', 'exists', '--name', 'test')
    Assert-True ($cliArguments[-2] -eq '--subscription' -and $cliArguments[-1] -eq $SubscriptionId) 'CLI wrapper always passes explicit subscription'
    $null = & $realInvokeAz -Arguments @('keyvault', 'show', '--subscription', 'other')
    Assert-True (@($cliArguments | Where-Object { $_ -eq '--subscription' }).Count -eq 1) 'explicit Key Vault subscription preserved'
    function az { $global:LASTEXITCODE = 1; return '' }
    Assert-Throws { & $realInvokeAz -Arguments @('rest', '--method', 'get') } 'Azure CLI command failed' 'CLI failure is not empty success'

    Write-Host "$passed assertions passed; no Azure resources or devices were contacted."
}
finally {
    if (Test-Path -LiteralPath $parameterPath) { Remove-Item -LiteralPath $parameterPath }
}
