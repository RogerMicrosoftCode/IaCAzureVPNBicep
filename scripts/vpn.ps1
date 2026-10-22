[CmdletBinding()]
param(
    [ValidateSet('Validate', 'WhatIf', 'Deploy', 'CheckDns', 'Status', 'Test')]
    [string]$Mode = 'Validate',

    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$ParameterFile = (Join-Path $PSScriptRoot '..\main.parameters.json'),
    [string]$DeploymentName = 'hybrid-vpn',
    [string[]]$TestTarget = @(),
    [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$templateFile = Join-Path $repoRoot 'main.bicep'
$parameterPath = [System.IO.Path]::GetFullPath($ParameterFile)

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed (exit code $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    return $output
}

function Get-ParameterValue {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Name
    )

    $parameter = $Configuration.parameters.PSObject.Properties[$Name]
    if ($null -eq $parameter) {
        return $null
    }
    return $parameter.Value.value
}

function Assert-NoSecretProperties {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -ne 'pskSecretName' -and [string]$key -match '(?i)psk|shared.?key|password|api.?token|secret|token') {
                throw 'Parameter files may contain Key Vault secret names, but not PSKs, DDNS API tokens, passwords, or other secret values.'
            }
            Assert-NoSecretProperties $Value[$key]
        }
        return
    }
    if ($Value -is [array]) {
        foreach ($item in $Value) {
            if ($null -ne $item) {
                Assert-NoSecretProperties $item
            }
        }
        return
    }
    if ($null -ne $Value -and $Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -ne 'pskSecretName' -and $property.Name -match '(?i)psk|shared.?key|password|api.?token|secret|token') {
                throw 'Parameter files may contain Key Vault secret names, but not PSKs, DDNS API tokens, passwords, or other secret values.'
            }
            Assert-NoSecretProperties $property.Value
        }
    }
}

function ConvertTo-IPv4Range {
    param([Parameter(Mandatory)][string]$Cidr)

    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
        throw "Invalid IPv4 CIDR: $Cidr"
    }

    $address = [System.Net.IPAddress]::Parse($Matches[1])
    $prefix = [int]$Matches[2]
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid IPv4 CIDR: $Cidr"
    }

    [uint64]$numericAddress = 0
    foreach ($octet in $address.GetAddressBytes()) {
        if ($octet -gt 255) {
            throw "Invalid IPv4 CIDR: $Cidr"
        }
        $numericAddress = ($numericAddress * 256) + [uint64]$octet
    }

    [uint64]$blockSize = [math]::Pow(2, 32 - $prefix)
    [uint64]$mask = [uint64]4294967295 - ($blockSize - 1)
    [uint64]$network = $numericAddress -band $mask
    return [pscustomobject]@{
        Cidr  = $Cidr
        Start = $network
        End   = $network + $blockSize - 1
        Prefix = $prefix
    }
}

function Test-RangeOverlap {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    return ($Left.Start -le $Right.End) -and ($Right.Start -le $Left.End)
}

function Test-RangeContains {
    param([Parameter(Mandatory)]$Outer, [Parameter(Mandatory)]$Inner)

    return ($Outer.Start -le $Inner.Start) -and ($Outer.End -ge $Inner.End)
}

function Assert-OwnedResourceNames {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Prefix,
        [string[]]$PrivateDnsZoneNames = @()
    )

    $resourcesJson = Invoke-Az @('resource', 'list', '--resource-group', $ResourceGroup, '--output', 'json')
    $resources = ($resourcesJson -join "`n") | ConvertFrom-Json
    foreach ($resource in $resources) {
        $isSubnetChild = $resource.type -eq 'Microsoft.Network/virtualNetworks/subnets'
        $isPeering = $resource.type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
        $isSolutionPrefix = -not $isSubnetChild -and -not $isPeering -and
            ($resource.name -like "$Prefix-*" -or $resource.name -like "*/$Prefix-*")
        $isConfiguredDnsZone = $resource.type -eq 'Microsoft.Network/privateDnsZones' -and
            $resource.name -in $PrivateDnsZoneNames
        if ($isPeering -and ($resource.name -like "$Prefix-*" -or $resource.name -like "*/$Prefix-*")) {
            $parentVnetName = ($resource.name -split '/')[0]
            $parentVnet = $resources | Where-Object {
                $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.name -eq $parentVnetName
            } | Select-Object -First 1
            if ($null -eq $parentVnet -or $parentVnet.tags.Solution -ne 'hybrid-vpn-bicep') {
                throw "Peering name collision: '$($resource.id)' is not under a solution-owned VNet."
            }
        }
        if ($isSolutionPrefix -or $isConfiguredDnsZone) {
            $solutionTag = $resource.tags.Solution
            if ($solutionTag -ne 'hybrid-vpn-bicep') {
                throw "Resource collision: '$($resource.id)' is not tagged Solution=hybrid-vpn-bicep. Choose another resourcePrefix or review the Private DNS zone ownership."
            }
        }
    }
}

function Assert-Configuration {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required. Install it and sign in before continuing.'
    }
    if (-not (Test-Path $templateFile)) {
        throw "Bicep template not found: $templateFile"
    }
    if (-not (Test-Path $parameterPath)) {
        throw "Parameter file not found: $parameterPath. Copy main.parameters.example.json to main.parameters.json and replace its placeholders."
    }
    if (-not $LocalOnly -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw 'ResourceGroupName is required. This solution never creates or deletes a Resource Group.'
    }

    $rawParameters = Get-Content -LiteralPath $parameterPath -Raw
    $configuration = $rawParameters | ConvertFrom-Json
    Assert-NoSecretProperties $configuration
    $prefix = [string](Get-ParameterValue $configuration 'resourcePrefix')
    $location = [string](Get-ParameterValue $configuration 'location')
    $keyVaultName = [string](Get-ParameterValue $configuration 'keyVaultName')
    $tags = Get-ParameterValue $configuration 'tags'
    $offices = @(Get-ParameterValue $configuration 'offices')
    $spokes = @(Get-ParameterValue $configuration 'spokes')

    if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -match '(?i)CHANGE-ME|REPLACE') {
        throw 'Replace the resourcePrefix placeholder before deploying.'
    }
    if ($prefix -notmatch '^[a-zA-Z0-9-]{3,20}$') {
        throw 'resourcePrefix must contain 3-20 letters, digits, or hyphens.'
    }
    if ([string]::IsNullOrWhiteSpace($location) -or $location -match '(?i)CHANGE-ME|REPLACE') {
        throw 'Set the final Azure region in the parameter file.'
    }
    if ([string]::IsNullOrWhiteSpace($keyVaultName) -or $keyVaultName -match '(?i)CHANGE-ME|REPLACE') {
        throw 'Set the name of an existing Key Vault in the parameter file.'
    }
    foreach ($tagName in @('Solution', 'Environment', 'Owner', 'CostCenter')) {
        $tag = $tags.PSObject.Properties[$tagName]
        if ($null -eq $tag -or [string]::IsNullOrWhiteSpace([string]$tag.Value) -or
            ($tagName -eq 'Solution' -and [string]$tag.Value -ne 'hybrid-vpn-bicep')) {
            throw "Set the required '$tagName' tag. Solution must be hybrid-vpn-bicep."
        }
    }
    if ($offices.Count -eq 0 -or $spokes.Count -eq 0) {
        throw 'At least one office and one Spoke are required.'
    }
    if ($rawParameters -match '(?i)CHANGE-ME|example\.invalid') {
        throw 'Replace all CHANGE-ME and example.invalid values before deployment.'
    }

    $azureNetworks = [System.Collections.Generic.List[object]]::new()
    $hubPrefix = [string](Get-ParameterValue $configuration 'hubAddressPrefix')
    $azureNetworks.Add((ConvertTo-IPv4Range $hubPrefix))
    foreach ($spoke in $spokes) {
        $azureNetworks.Add((ConvertTo-IPv4Range ([string]$spoke.addressPrefix)))
    }
    foreach ($network in $azureNetworks) {
        $reservedOfficeSpace = ConvertTo-IPv4Range '192.168.0.0/16'
        if (Test-RangeOverlap $network $reservedOfficeSpace) {
            throw "Azure address space '$($network.Cidr)' overlaps 192.168.0.0/16, which is reserved for on-premises networks."
        }
    }
    for ($left = 0; $left -lt $azureNetworks.Count; $left++) {
        for ($right = $left + 1; $right -lt $azureNetworks.Count; $right++) {
            if (Test-RangeOverlap $azureNetworks[$left] $azureNetworks[$right]) {
                throw "Azure VNet prefixes overlap: '$($azureNetworks[$left].Cidr)' and '$($azureNetworks[$right].Cidr)'."
            }
        }
    }

    $officeNetworks = [System.Collections.Generic.List[object]]::new()
    $officeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pskSecretNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($office in $offices) {
        if ([string]::IsNullOrWhiteSpace([string]$office.name) -or
            [string]$office.name -notmatch '^[a-zA-Z0-9-]{1,32}$' -or
            [string]::IsNullOrWhiteSpace([string]$office.fqdn) -or
            [string]$office.fqdn -notmatch '^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') {
            throw "Office '$($office.name)' must have a valid public FQDN. Dynamic offices must not use gatewayIpAddress."
        }
        if ($null -ne $office.PSObject.Properties['gatewayIpAddress']) {
            throw "Office '$($office.name)' must use fqdn only; remove gatewayIpAddress from the configuration."
        }
        if (-not $officeNames.Add([string]$office.name)) {
            throw "Office names must be unique; duplicate name '$($office.name)'."
        }
        if (@($office.addressPrefixes).Count -eq 0) {
            throw "Office '$($office.name)' must define at least one on-premises address prefix."
        }
        if ([string]::IsNullOrWhiteSpace([string]$office.pskSecretName)) {
            throw "Office '$($office.name)' must name its PSK secret in Key Vault."
        }
        if (-not $pskSecretNames.Add([string]$office.pskSecretName)) {
            throw "Each office must use a distinct Key Vault PSK secret name; duplicate '$($office.pskSecretName)'."
        }
        foreach ($prefixValue in $office.addressPrefixes) {
            $officeRange = ConvertTo-IPv4Range ([string]$prefixValue)
            foreach ($azureNetwork in $azureNetworks) {
                if (Test-RangeOverlap $officeRange $azureNetwork) {
                    throw "On-premises prefix '$prefixValue' overlaps Azure prefix '$($azureNetwork.Cidr)'."
                }
            }
            foreach ($existingOfficeRange in $officeNetworks) {
                if (Test-RangeOverlap $officeRange $existingOfficeRange) {
                    throw "On-premises prefix '$prefixValue' overlaps another office prefix '$($existingOfficeRange.Cidr)'."
                }
            }
            $officeNetworks.Add($officeRange)
        }
        if ((Get-ParameterValue $configuration 'enableBgp') -eq $true) {
            if ($null -eq $office.asn -or [int64]$office.asn -lt 1 -or [int64]$office.asn -gt 2147483647) {
                throw "BGP is enabled but office '$($office.name)' has an invalid ASN."
            }
            if ([string]::IsNullOrWhiteSpace([string]$office.bgpPeerIp)) {
                throw "BGP is enabled but office '$($office.name)' is missing its BGP peer IP."
            }
            $null = ConvertTo-IPv4Range "$($office.bgpPeerIp)/32"
        }
    }

    $spokeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($spoke in $spokes) {
        if ([string]::IsNullOrWhiteSpace([string]$spoke.name) -or [string]$spoke.name -notmatch '^[a-zA-Z0-9-]{1,32}$' -or @($spoke.subnets).Count -eq 0) {
            throw "Spoke '$($spoke.name)' must have a valid name and at least one subnet."
        }
        if (-not $spokeNames.Add([string]$spoke.name)) {
            throw "Spoke names must be unique; duplicate name '$($spoke.name)'."
        }
        $spokeRange = ConvertTo-IPv4Range ([string]$spoke.addressPrefix)
        $subnetRanges = [System.Collections.Generic.List[object]]::new()
        foreach ($subnet in $spoke.subnets) {
            if ([string]::IsNullOrWhiteSpace([string]$subnet.name)) {
                throw "Every subnet in Spoke '$($spoke.name)' must have a name."
            }
            $subnetRange = ConvertTo-IPv4Range ([string]$subnet.addressPrefix)
            if (-not (Test-RangeContains $spokeRange $subnetRange)) {
                throw "Subnet '$($subnet.name)' prefix '$($subnet.addressPrefix)' is not contained by Spoke '$($spoke.name)' prefix '$($spoke.addressPrefix)'."
            }
            foreach ($otherSubnet in $subnetRanges) {
                if (Test-RangeOverlap $subnetRange $otherSubnet) {
                    throw "Subnet prefix '$($subnetRange.Cidr)' overlaps '$($otherSubnet.Cidr)' in Spoke '$($spoke.name)'."
                }
            }
            $subnetRanges.Add($subnetRange)
        }
    }

    $enabledFirewall = Get-ParameterValue $configuration 'enableFirewall'
    $enabledBastion = Get-ParameterValue $configuration 'enableBastion'
    if ((Get-ParameterValue $configuration 'enableBgp') -eq $true) {
        $azureAsn = Get-ParameterValue $configuration 'azureBgpAsn'
        if ($null -eq $azureAsn -or [int64]$azureAsn -lt 1 -or [int64]$azureAsn -gt 2147483647) {
            throw 'BGP is enabled but azureBgpAsn is invalid.'
        }
    }
    $hubSubnetPrefixes = @(
        [string](Get-ParameterValue $configuration 'gatewaySubnetPrefix'),
        [string](Get-ParameterValue $configuration 'sharedServicesSubnetPrefix'),
        [string](Get-ParameterValue $configuration 'networkManagementSubnetPrefix')
    )
    if ($enabledFirewall -eq $true) {
        $hubSubnetPrefixes += [string](Get-ParameterValue $configuration 'firewallSubnetPrefix')
    }
    if ($enabledBastion -eq $true) {
        $hubSubnetPrefixes += [string](Get-ParameterValue $configuration 'bastionSubnetPrefix')
    }
    $hubSubnetRanges = [System.Collections.Generic.List[object]]::new()
    foreach ($prefixValue in $hubSubnetPrefixes) {
        $subnetRange = ConvertTo-IPv4Range $prefixValue
        $hubRange = $azureNetworks[0]
        if (-not (Test-RangeContains $hubRange $subnetRange)) {
            throw "Hub subnet prefix '$prefixValue' must be contained by hubAddressPrefix."
        }
        foreach ($otherSubnet in $hubSubnetRanges) {
            if (Test-RangeOverlap $subnetRange $otherSubnet) {
                throw "Hub subnet prefix '$($subnetRange.Cidr)' overlaps '$($otherSubnet.Cidr)'."
            }
        }
        $hubSubnetRanges.Add($subnetRange)
    }
    if ($hubSubnetRanges[0].Prefix -gt 27) {
        throw 'gatewaySubnetPrefix must be /27 or larger.'
    }

    if ($enabledFirewall -eq $true) {
        $firewallRange = ConvertTo-IPv4Range ([string](Get-ParameterValue $configuration 'firewallSubnetPrefix'))
        if ($firewallRange.Prefix -gt 26 -or -not (Test-RangeContains $azureNetworks[0] $firewallRange)) {
            throw 'When Firewall is enabled, firewallSubnetPrefix must be /26 or larger and contained in the Hub VNet.'
        }
    }
    if ($enabledBastion -eq $true) {
        $bastionRange = ConvertTo-IPv4Range ([string](Get-ParameterValue $configuration 'bastionSubnetPrefix'))
        if ($bastionRange.Prefix -gt 26 -or -not (Test-RangeContains $azureNetworks[0] $bastionRange)) {
            throw 'When Bastion is enabled, bastionSubnetPrefix must be /26 or larger and contained in the Hub VNet.'
        }
    }
    $authorizedRules = @(Get-ParameterValue $configuration 'authorizedInboundRules')
    if ($authorizedRules.Count -gt 1000) {
        throw 'authorizedInboundRules cannot contain more than 1000 NSG rules.'
    }
    foreach ($rule in $authorizedRules) {
        if ([string]::IsNullOrWhiteSpace([string]$rule.name) -or $rule.name -notmatch '^[a-zA-Z0-9-]{1,64}$' -or
            $null -eq $rule.destinationPort -or [int]$rule.destinationPort -lt 1 -or [int]$rule.destinationPort -gt 65535) {
            throw 'Each authorizedInboundRules entry needs a valid name and a TCP destinationPort from 1 to 65535.'
        }
    }

    $buildOutput = Join-Path $env:TEMP ("hybrid-vpn-{0}.json" -f [guid]::NewGuid())
    try {
        Invoke-Az @('bicep', 'build', '--file', $templateFile, '--outfile', $buildOutput) | Out-Null
    }
    finally {
        if (Test-Path $buildOutput) {
            Remove-Item -LiteralPath $buildOutput -Force
        }
    }

    if ($LocalOnly) {
        return [pscustomobject]@{
            Configuration = $configuration
            ResourcePrefix = $prefix
            ActiveSubscription = 'not checked (LocalOnly)'
        }
    }

    $activeSubscription = [string](Invoke-Az @('account', 'show', '--query', 'id', '--output', 'tsv'))
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and $activeSubscription -ne $SubscriptionId) {
        throw "The active Azure subscription '$activeSubscription' does not match requested subscription '$SubscriptionId'."
    }

    $groupExists = [string](Invoke-Az @('group', 'exists', '--name', $ResourceGroupName, '--output', 'tsv'))
    if ($groupExists.Trim() -ne 'true') {
        throw "Resource Group '$ResourceGroupName' does not exist. This solution will not create it."
    }
    Assert-OwnedResourceNames -ResourceGroup $ResourceGroupName -Prefix $prefix -PrivateDnsZoneNames @((Get-ParameterValue $configuration 'privateDnsZones'))

    $keyVaultRg = [string](Get-ParameterValue $configuration 'keyVaultResourceGroupName')
    if ([string]::IsNullOrWhiteSpace($keyVaultRg)) {
        $keyVaultRg = $ResourceGroupName
    }
    $keyVaultSubscription = [string](Get-ParameterValue $configuration 'keyVaultSubscriptionId')
    $keyVaultArguments = @('keyvault', 'show', '--name', $keyVaultName, '--resource-group', $keyVaultRg, '--query', 'id', '--output', 'tsv')
    if (-not [string]::IsNullOrWhiteSpace($keyVaultSubscription)) {
        $keyVaultArguments += @('--subscription', $keyVaultSubscription)
    }
    $null = Invoke-Az $keyVaultArguments

    return [pscustomobject]@{
        Configuration = $configuration
        ResourcePrefix = $prefix
        ActiveSubscription = $activeSubscription
    }
}

function Invoke-WhatIf {
    $arguments = @(
        'deployment', 'group', 'what-if',
        '--resource-group', $ResourceGroupName,
        '--name', $DeploymentName,
        '--template-file', $templateFile,
        '--parameters', "@$parameterPath",
        '--mode', 'Incremental',
        '--output', 'json'
    )
    $json = Invoke-Az $arguments
    $result = ($json -join "`n") | ConvertFrom-Json
    $changeProperty = $result.PSObject.Properties['changes']
    if ($null -eq $changeProperty -and $null -ne $result.properties) {
        $changeProperty = $result.properties.PSObject.Properties['changes']
    }
    if ($null -eq $changeProperty) {
        throw 'What-if output did not contain a changes list. Deployment stopped for safety.'
    }
    $changes = @($changeProperty.Value)
    foreach ($change in $changes) {
        if ($change.changeType -eq 'Delete') {
            throw "What-if contains a deletion for '$($change.resourceId)'. Deployment stopped."
        }
        if ($change.changeType -notin @('Create', 'Modify', 'NoChange', 'Ignore', 'Deploy')) {
            throw "What-if returned an unrecognized change type '$($change.changeType)'. Review the output manually; deployment stopped."
        }
    }
    Write-Output ($json -join "`n")
}

switch ($Mode) {
    'CheckDns' {
        if (-not (Test-Path $parameterPath)) {
            throw "Parameter file not found: $parameterPath"
        }
        $configuration = (Get-Content -LiteralPath $parameterPath -Raw) | ConvertFrom-Json
        foreach ($office in (Get-ParameterValue $configuration 'offices')) {
            $fqdn = [string]$office.fqdn
            if ($fqdn -match '(?i)example\.invalid|CHANGE-ME') {
                throw "Replace the example FQDN for office '$($office.name)' before checking DNS."
            }
            $records = @(Resolve-DnsName -Name $fqdn -Type A -DnsOnly -ErrorAction Stop)
            $addresses = @($records | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
            if ($addresses.Count -eq 0) {
                throw "No IPv4 A record was returned for $fqdn."
            }
            Write-Output "$fqdn -> $($addresses -join ', ')"
        }
    }
    'Validate' {
        $validation = Assert-Configuration
        Write-Output "Validation succeeded. Subscription: $($validation.ActiveSubscription); Resource Group: $ResourceGroupName; resourcePrefix: $($validation.ResourcePrefix)."
        Write-Output 'No resources were changed. PSKs and DDNS tokens were not read or displayed.'
    }
    'WhatIf' {
        $null = Assert-Configuration
        Invoke-WhatIf
    }
    'Deploy' {
        $validation = Assert-Configuration
        Invoke-WhatIf
        Write-Output 'Review the what-if output above. No Resource Group operations or deletes are part of this deployment.'
        $confirmation = Read-Host "Type DEPLOY to deploy to '$ResourceGroupName' in subscription '$($validation.ActiveSubscription)'"
        if ($confirmation -cne 'DEPLOY') {
            throw 'Deployment cancelled; no resources were changed.'
        }
        Invoke-Az @(
            'deployment', 'group', 'create',
            '--resource-group', $ResourceGroupName,
            '--name', $DeploymentName,
            '--template-file', $templateFile,
            '--parameters', "@$parameterPath",
            '--mode', 'Incremental',
            '--output', 'json'
        ) | Write-Output
    }
    'Status' {
        if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
            throw 'ResourceGroupName is required.'
        }
        $null = Invoke-Az @('group', 'show', '--name', $ResourceGroupName, '--output', 'none')
        $prefix = [string](Get-ParameterValue ((Get-Content -LiteralPath $parameterPath -Raw) | ConvertFrom-Json) 'resourcePrefix')
        $connections = Invoke-Az @(
            'network', 'vpn-connection', 'list',
            '--resource-group', $ResourceGroupName,
            '--query', "[?starts_with(name, '$prefix-')].{name:name,status:connectionStatus,ingressBytes:ingressBytesTransferred,egressBytes:egressBytesTransferred}",
            '--output', 'table'
        )
        Write-Output $connections
    }
    'Test' {
        if ($TestTarget.Count -eq 0) {
            throw 'Supply one or more targets in host:port format, for example -TestTarget 10.101.0.10:443.'
        }
        $failed = $false
        foreach ($target in $TestTarget) {
            if ($target -notmatch '^([^:]+):([0-9]{1,5})$' -or [int]$Matches[2] -lt 1 -or [int]$Matches[2] -gt 65535) {
                throw "Invalid test target '$target'. Use host:port with a TCP port from 1 to 65535."
            }
            $hostName = $Matches[1]
            $port = [int]$Matches[2]
            $reachable = Test-NetConnection -ComputerName $hostName -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
            if ($reachable) {
                Write-Output "$hostName`:$port reachable"
            }
            else {
                Write-Output "$hostName`:$port unreachable"
                $failed = $true
            }
        }
        if ($failed) {
            throw 'One or more TCP connectivity checks failed.'
        }
    }
}
