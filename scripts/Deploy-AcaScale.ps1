#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9_.-]{0,127}$')]
    [string]$ImageTag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

foreach ($command in @('az', 'docker', 'dotnet')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing required tool: $command"
    }
}
if (-not (Test-Path './src/Agent.Api/Dockerfile')) {
    throw 'Dockerfile is missing. Run the earlier tutorial steps first.'
}

$ActiveSubscription = (& az account show --query id --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or -not $ActiveSubscription) {
    throw 'Azure CLI is not authenticated. Run the tenant-specific az login command first.'
}

if (-not (Test-Path './.env.ps1')) {
    throw 'Saved lab settings are missing. Complete Step 7 before using this menu.'
}
. './.env.ps1'
if ($SubscriptionId -ne $ActiveSubscription) {
    throw 'Active subscription differs from saved lab subscription.'
}

. './scripts/Common.ps1'
if ($ImageTag) {
    $script:ImageTag = $ImageTag
}

function Resolve-Registry {
    $script:AcrLoginServer = Invoke-AzTsv -Arguments @(
        'acr', 'show', '-g', $ResourceGroup, '-n', $AcrName, '--query', 'loginServer'
    )
    $mode = Invoke-AzTsv -Arguments @(
        'acr', 'show', '-g', $ResourceGroup, '-n', $AcrName, '--query', 'roleAssignmentMode'
    )
    $admin = Invoke-AzTsv -Arguments @(
        'acr', 'show', '-g', $ResourceGroup, '-n', $AcrName, '--query', 'adminUserEnabled'
    )
    if ($mode -ne 'LegacyRegistryPermissions') {
        throw "This lab requires registry RBAC; service returned roleAssignmentMode '$mode'."
    }
    if ($admin -ne 'false') {
        throw 'ACR admin credentials must remain disabled.'
    }
    if ($AcrLoginServer -notlike '*.azurecr.io') {
        throw 'The registry login server is invalid.'
    }
    $script:RegistryImage = "$AcrLoginServer/${ImageRepository}:$ImageTag"
}

function Confirm-Overwrite {
    param([Parameter(Mandatory)][string]$Reference)
    $answer = Read-Host "Reference $Reference exists. Type OVERWRITE to replace it"
    if ($answer -cne 'OVERWRITE') {
        throw "Refusing to overwrite $Reference."
    }
}

function Test-LocalImageExists {
    param([Parameter(Mandatory)][string]$Reference)
    docker image inspect $Reference *> $null
    return $LASTEXITCODE -eq 0
}

function Get-RemoteTags {
    $json = Invoke-Native -File az -Arguments @(
        'acr', 'repository', 'show-tags', '-n', $AcrName, '-r', $ImageRepository, '--output', 'json'
    )
    @((($json | Out-String) | ConvertFrom-Json))
}

function Build-LabImage {
    param([switch]$Cloud)
    Resolve-Registry
    $localImage = "${ImageRepository}:$ImageTag"
    $remoteTags = Get-RemoteTags
    if (Test-LocalImageExists -Reference $localImage) { Confirm-Overwrite -Reference $localImage }
    if ($remoteTags -contains $ImageTag) { Confirm-Overwrite -Reference $RegistryImage }

    if ($Cloud) {
        Invoke-Native -File az -Arguments @(
            'acr', 'build', '-g', $ResourceGroup, '-r', $AcrName,
            '--platform', 'linux/amd64', '--timeout', '1800',
            '--image', "${ImageRepository}:$ImageTag", '--file', './src/Agent.Api/Dockerfile', '.'
        )
    } else {
        Invoke-Native -File docker -Arguments @(
            'build', '--platform', 'linux/amd64', '--progress=plain',
            '--file', './src/Agent.Api/Dockerfile', '--tag', $localImage, '.'
        )
        Invoke-Native -File az -Arguments @('acr', 'login', '-n', $AcrName)
        Invoke-Native -File docker -Arguments @('tag', $localImage, $RegistryImage)
        Invoke-Native -File docker -Arguments @('push', $RegistryImage)
    }
    Save-LabEnvironment
}

function New-LabRegistry {
    Invoke-Native -File az -Arguments @('group', 'create', '-n', $ResourceGroup, '-l', $Location, '--output', 'table')
    $found = Invoke-AzTsv -Arguments @('acr', 'list', '-g', $ResourceGroup, '--query', "[?name=='$AcrName'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @(
            'acr', 'create', '-g', $ResourceGroup, '-n', $AcrName, '--sku', 'Basic',
            '--role-assignment-mode', 'rbac', '--admin-enabled', 'false', '--output', 'table'
        )
    }
    Resolve-Registry
    Save-LabEnvironment
}

function New-LabEnvironment {
    $found = Invoke-AzTsv -Arguments @('containerapp', 'env', 'list', '-g', $ResourceGroup, '--query', "[?name=='$ContainerAppsEnvironment'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @('containerapp', 'env', 'create', '-g', $ResourceGroup, '-n', $ContainerAppsEnvironment, '-l', $Location, '--output', 'table')
    }
    Wait-Environment
}

function Deploy-LabApp {
    Resolve-Registry
    Wait-Environment
    $found = Invoke-AzTsv -Arguments @('containerapp', 'list', '-g', $ResourceGroup, '--query', "[?name=='$ContainerAppName'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @(
            'containerapp', 'create', '-g', $ResourceGroup, '-n', $ContainerAppName,
            '--environment', $ContainerAppsEnvironment, '--image', 'mcr.microsoft.com/k8se/quickstart:latest',
            '--system-assigned', '--ingress', 'external', '--target-port', '80',
            '--min-replicas', '1', '--max-replicas', '1', '--output', 'table'
        )
    }
    $principal = Invoke-AzTsv -Arguments @('containerapp', 'identity', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--query', 'principalId')
    if (-not $principal) { throw 'The app has no system identity.' }
    $acrId = Invoke-AzTsv -Arguments @('acr', 'show', '-g', $ResourceGroup, '-n', $AcrName, '--query', 'id')
    $assignment = Invoke-Native -File az -Arguments @(
        'role', 'assignment', 'list', '--assignee', $principal, '--scope', $acrId, '--role', 'AcrPull', '--output', 'json'
    )
    $assignmentItems = @((($assignment | Out-String) | ConvertFrom-Json))
    if ($assignmentItems.Count -eq 0) {
        Invoke-Native -File az -Arguments @(
            'role', 'assignment', 'create', '--assignee-object-id', $principal,
            '--assignee-principal-type', 'ServicePrincipal', '--role', 'AcrPull',
            '--scope', $acrId, '--output', 'table'
        )
    }
    $auth = Invoke-AzTsv -Arguments @('acr', 'config', 'authentication-as-arm', 'show', '-r', $AcrName, '--query', 'status')
    if ($auth -ne 'enabled') { throw 'ARM-audience tokens are disabled. Review Step 10.4 before enabling them.' }
    Invoke-Native -File az -Arguments @('containerapp', 'registry', 'set', '-g', $ResourceGroup, '-n', $ContainerAppName, '--server', $AcrLoginServer, '--identity', 'system')
    Publish-AppConfiguration
    $script:ContainerAppFqdn = Invoke-AzTsv -Arguments @('containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--query', 'properties.configuration.ingress.fqdn')
    $script:ContainerAppUrl = "https://$ContainerAppFqdn"
    Wait-Agent -Url $ContainerAppUrl -ExpectedVersion $ImageTag
    Save-LabEnvironment
}

function Show-LabStatus {
    Resolve-Registry
    Invoke-Native -File az -Arguments @('account', 'show', '--query', '{name:name,id:id,tenantId:tenantId,user:user.name}', '--output', 'table')
    Invoke-Native -File az -Arguments @('acr', 'repository', 'show', '-n', $AcrName, '--image', "${ImageRepository}:$ImageTag", '--output', 'table')
    Invoke-Native -File az -Arguments @('containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--query', '{state:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn,ready:properties.latestReadyRevisionName,image:properties.template.containers[0].image}', '--output', 'table')
    Invoke-Native -File az -Arguments @('containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--query', 'properties.template.scale', '--output', 'json')
    Invoke-Native -File az -Arguments @('containerapp', 'logs', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--type', 'system', '--tail', '20', '--output', 'tsv')
}

while ($true) {
    Write-Host @"
Azure Container Apps lab | subscription $SubscriptionId
Resource group: $ResourceGroup | region: $Location | image tag: $ImageTag
1. Create/reuse resource group and ACR
2. Build locally and push
3. Build in ACR Tasks
4. Create/reuse environment and wait
5. Bootstrap/deploy app with one fixed replica and verify endpoint
6. Apply HTTP autoscaling YAML (0-10, target 10)
7. Show status
8. Delete the entire lab resource group
9. Exit
"@
    try {
        $selection = Read-Host 'Select 1-9'
        if ($selection -eq '9') { return }
        Assert-LabSubscription
        switch ($selection) {
            '1' { New-LabRegistry }
            '2' { Build-LabImage }
            '3' { Build-LabImage -Cloud }
            '4' { New-LabEnvironment }
            '5' { Deploy-LabApp }
            '6' {
                Resolve-Registry
                Publish-AppConfiguration -MinReplicas 0 -MaxReplicas 10 -HttpScaling
                Wait-Agent -Url $ContainerAppUrl -ExpectedVersion $ImageTag
                Save-LabEnvironment
            }
            '7' { Show-LabStatus }
            '8' {
                $active = Invoke-AzTsv -Arguments @('account', 'show', '--query', 'id')
                if ($active -ne $SubscriptionId) { throw 'Subscription changed. Deletion blocked.' }
                Invoke-Native -File az -Arguments @('resource', 'list', '-g', $ResourceGroup, '--output', 'table')
                if ((Read-Host "Delete ALL resources in '$ResourceGroup' in '$SubscriptionId'? Type DELETE") -eq 'DELETE') {
                    Invoke-Native -File az -Arguments @('group', 'delete', '-n', $ResourceGroup, '--yes')
                    do {
                        Start-Sleep 10
                        $exists = Invoke-AzTsv -Arguments @('group', 'exists', '-n', $ResourceGroup)
                    } while ($exists -eq 'true')
                    Write-Host 'Resource group deletion verified.'
                }
            }
            default { Write-Warning 'Select 1-9.' }
        }
    } catch {
        Write-Warning $_.Exception.Message
        Write-Warning 'Operation failed. No success is implied. Correct the cause before retrying.'
    }
}