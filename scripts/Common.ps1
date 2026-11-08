#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    if ($File -eq 'az' -and $Arguments[0] -notin @('account', 'ad')) {
        if (-not (Get-Variable SubscriptionId -ValueOnly -ErrorAction SilentlyContinue)) {
            throw 'Load or initialize the lab SubscriptionId before resource commands.'
        }
        if ($Arguments -contains '--subscription') {
            throw 'Do not override subscription in helper arguments; the saved lab subscription is authoritative.'
        }
        $Arguments = $Arguments + @('--subscription', $SubscriptionId)
    }

    $PSNativeCommandUseErrorActionPreference = $false
    $result = & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    $result
}

function Invoke-AzTsv {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-Native -File az -Arguments ($Arguments + @('--output', 'tsv'))
    ($result | Out-String).Trim()
}

function Assert-LabSubscription {
    $active = Invoke-AzTsv -Arguments @('account', 'show', '--query', 'id')
    if ($active -ne $SubscriptionId) {
        throw "Active subscription differs from saved lab subscription $SubscriptionId. Select it explicitly before continuing."
    }
}

function Get-ReplicaCount {
    param([Parameter(Mandatory)][string]$Revision)

    $replicaJson = Invoke-Native -File az -Arguments @(
        'containerapp', 'replica', 'list', '-g', $ResourceGroup, '-n', $ContainerAppName,
        '--revision', $Revision, '--output', 'json'
    )
    @((($replicaJson | Out-String) | ConvertFrom-Json)).Count
}

function Wait-AppRevision {
    param(
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [Parameter(Mandatory)][string]$ExpectedImage,
        [Parameter(Mandatory)][int]$MinReplicas,
        [Parameter(Mandatory)][int]$MaxReplicas,
        [switch]$HttpScaling,
        [int]$TimeoutSeconds = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $appJson = Invoke-Native -File az -Arguments @(
            'containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName, '--output', 'json'
        )
        $current = ($appJson | Out-String) | ConvertFrom-Json
        if ($current.properties.latestRevisionName -ne $ExpectedRevision) {
            throw 'The latest revision changed during verification. Stop concurrent deployments and retry.'
        }

        $revisionJson = Invoke-Native -File az -Arguments @(
            'containerapp', 'revision', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName,
            '--revision', $ExpectedRevision, '--output', 'json'
        )
        $revision = ($revisionJson | Out-String) | ConvertFrom-Json
        $properties = $revision.properties
        if ($properties.provisioningState -in @('Failed', 'Deprovisioned', 'ProvisioningFailed')) {
            throw "Revision $ExpectedRevision failed provisioning. Inspect system and console logs."
        }

        $healthyOrIdle = $properties.healthState -eq 'Healthy' -or $properties.runningState -eq 'ScaleTo0'
        if ($current.properties.latestReadyRevisionName -eq $ExpectedRevision -and
            $properties.provisioningState -eq 'Provisioned' -and $healthyOrIdle) {
            $template = $properties.template
            if ($template.containers[0].image -ne $ExpectedImage -or
                $template.scale.minReplicas -ne $MinReplicas -or
                $template.scale.maxReplicas -ne $MaxReplicas) {
                throw 'Ready revision image or replica bounds differ from the intended configuration.'
            }

            $rulesProperty = $template.scale.PSObject.Properties['rules']
            $rules = @()
            if ($rulesProperty -and $null -ne $rulesProperty.Value) {
                $rules = @($rulesProperty.Value)
            }
            if ($HttpScaling) {
                $httpRules = @($rules | Where-Object { $_.name -eq 'http-scaling' })
                if ($httpRules.Count -ne 1 -or
                    $httpRules[0].http.metadata.concurrentRequests -ne '10') {
                    throw 'Ready revision does not contain the intended HTTP concurrency target of 10.'
                }
            } elseif ($rules.Count -gt 0) {
                throw 'Fixed-replica configuration unexpectedly contains scale rules.'
            }

            Write-Host "Verified ready revision: $ExpectedRevision"
            return
        }
        Start-Sleep 5
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Revision $ExpectedRevision did not become ready within $TimeoutSeconds seconds. Inspect revisions, image pull, and console/system logs."
}

function Wait-Environment {
    param([int]$TimeoutSeconds = 900)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Invoke-AzTsv -Arguments @(
            'containerapp', 'env', 'show', '-g', $ResourceGroup, '-n', $ContainerAppsEnvironment,
            '--query', 'properties.provisioningState'
        )
        if ($state -eq 'Succeeded') {
            return
        }
        if ($state -in @('Failed', 'Canceled')) {
            throw 'Environment provisioning failed. Inspect Azure deployment errors.'
        }
        Start-Sleep 10
    } while ([DateTime]::UtcNow -lt $deadline)

    throw 'Environment readiness timed out. Inspect provisioning state before continuing.'
}

function Wait-Agent {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [string]$ExpectedMessage = '',
        [int]$TimeoutSeconds = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastProblem = 'No successful response yet.'
    do {
        try {
            $info = Invoke-RestMethod "$Url/api/info" -TimeoutSec 30
            $health = Invoke-RestMethod "$Url/health" -TimeoutSec 30
            if ($info.version -eq $ExpectedVersion -and $health.status -eq 'Healthy') {
                if ($ExpectedMessage) {
                    $rootResponse = Invoke-RestMethod "$Url/" -TimeoutSec 30
                    if ($rootResponse.message -ne $ExpectedMessage) {
                        throw 'Old source response is still being served.'
                    }
                }
                $info
                return
            }
            $lastProblem = "Expected $ExpectedVersion; received $($info.version)."
        } catch {
            $lastProblem = $_.Exception.Message
        }
        Start-Sleep 10
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Endpoint verification timed out: $lastProblem Inspect revisions, image pull, and console/system logs."
}

function Save-LabEnvironment {
    $settings = [ordered]@{
        SubscriptionId = $SubscriptionId
        Location = $Location
        ResourceGroup = $ResourceGroup
        ContainerAppName = $ContainerAppName
        ImageRepository = $ImageRepository
        ImageTag = $ImageTag
        AcrName = $AcrName
        AcrLoginServer = $AcrLoginServer
        ContainerAppsEnvironment = $ContainerAppsEnvironment
        RegistryImage = $RegistryImage
        ContainerAppFqdn = $ContainerAppFqdn
        ContainerAppUrl = $ContainerAppUrl
    }
    $settings | ConvertTo-Json | Set-Content (Join-Path $Root '.lab-settings.json')

    @'
$settings = Get-Content (Join-Path $PSScriptRoot '.lab-settings.json') -Raw | ConvertFrom-Json
foreach ($property in $settings.PSObject.Properties) {
    Set-Variable -Name $property.Name -Value $property.Value
}
$env:RESOURCE_GROUP = $ResourceGroup
$env:LOCATION = $Location
$env:ACR_NAME = $AcrName
$env:ACR_LOGIN_SERVER = $AcrLoginServer
$env:ACA_ENVIRONMENT = $ContainerAppsEnvironment
$env:CONTAINER_APP_NAME = $ContainerAppName
$env:CONTAINER_APP_FQDN = $ContainerAppFqdn
$env:CONTAINER_APP_URL = $ContainerAppUrl
$env:CONTAINER_IMAGE = $RegistryImage
Remove-Variable settings
'@ | Set-Content (Join-Path $Root '.env.ps1')
}

function Write-AppYaml {
    param(
        [int]$MinReplicas = 1,
        [int]$MaxReplicas = 1,
        [switch]$HttpScaling
    )

    $environmentId = Invoke-AzTsv -Arguments @(
        'containerapp', 'env', 'show', '-g', $ResourceGroup, '-n', $ContainerAppsEnvironment, '--query', 'id'
    )
    $containerName = Invoke-AzTsv -Arguments @(
        'containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName,
        '--query', 'properties.template.containers[0].name'
    )
    if (-not $containerName) {
        throw 'Cannot determine existing container name.'
    }

    $rules = ''
    if ($HttpScaling) {
        $rules = @'
      rules:
        - name: http-scaling
          http:
            metadata:
              concurrentRequests: '10'
'@
    }

    $yaml = @"
name: $ContainerAppName
location: $Location
identity:
  type: SystemAssigned
properties:
  environmentId: $environmentId
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      allowInsecure: false
      targetPort: 8080
      transport: auto
      traffic:
        - latestRevision: true
          weight: 100
    registries:
      - server: $AcrLoginServer
        identity: system
  template:
    containers:
      - name: $containerName
        image: $RegistryImage
        env:
          - name: APP_VERSION
            value: '$ImageTag'
          - name: AGENT_DEFAULT_DELAY_MS
            value: '500'
        resources:
          cpu: 0.5
          memory: 1Gi
        probes:
          - type: Startup
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 60
          - type: Readiness
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          - type: Liveness
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
    scale:
      minReplicas: $MinReplicas
      maxReplicas: $MaxReplicas
$rules
"@

    $path = Join-Path $Root 'artifacts/containerapp.yaml'
    New-Item (Split-Path $path) -ItemType Directory -Force | Out-Null
    $yaml | Set-Content $path
    $path
}

function Publish-AppConfiguration {
    param(
        [int]$MinReplicas = 1,
        [int]$MaxReplicas = 1,
        [switch]$HttpScaling
    )

    Assert-LabSubscription
    $path = Write-AppYaml -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas -HttpScaling:$HttpScaling
    Invoke-Native -File az -Arguments @(
        'containerapp', 'update', '-g', $ResourceGroup, '-n', $ContainerAppName,
        '--yaml', $path, '--output', 'table'
    )
    $script:VerifiedRevision = Invoke-AzTsv -Arguments @(
        'containerapp', 'show', '-g', $ResourceGroup, '-n', $ContainerAppName,
        '--query', 'properties.latestRevisionName'
    )
    if (-not $script:VerifiedRevision) {
        throw 'No latest revision returned after deployment.'
    }
    Wait-AppRevision -ExpectedRevision $script:VerifiedRevision -ExpectedImage $RegistryImage `
        -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas -HttpScaling:$HttpScaling
}