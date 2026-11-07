# AI-200 practical tutorial: Build, deploy, and scale a C# container in Azure Container Apps

**Version:** 1.2  
**Updated:** 8 November 2026  
**Primary shell:** PowerShell 7.4 or later  
**Application stack:** C# 14, .NET 10 LTS, ASP.NET Core Minimal API  
**Azure services:** Azure Container Registry and Azure Container Apps  
**Estimated time:** 120 to 180 minutes, excluding Azure provisioning and scale-in delays

## Purpose

This tutorial adapts the Microsoft Learn **Scale containers in Azure Container Apps** exercise using C#/.NET and PowerShell instead of Python and Flask. It deliberately exposes the complete image lifecycle:

1. Write and run C# source code.
2. Publish the .NET application.
3. Package the published application as an OCI container image.
4. Run and inspect the image locally.
5. Push the image to Azure Container Registry (ACR).
6. Deploy that image to Azure Container Apps (ACA).
7. Configure HTTP autoscaling, generate concurrent load, and observe replicas.
8. Build and deploy a second image to create a new revision.

The final PowerShell deployment script performs the same broad resource and image-deployment tasks as the supplied `azdeploy.py`, but you will run the underlying commands manually first so that the script does not hide the learning.

> **Scope:** This tutorial demonstrates HTTP concurrency scaling only. KEDA-backed Service Bus, Kafka, CPU, memory, traffic splitting, and Container Apps Jobs are outside this focused exercise.

## Key concepts

| Concept | Meaning in this tutorial |
|---|---|
| Source code | `Program.cs`, compiled by the .NET SDK |
| Published application | Release-ready DLLs and configuration produced by `dotnet publish` |
| Dockerfile | Repeatable instructions for building an image |
| Build context | Files available to `docker build`; represented by the final `.` in the command |
| Image | Immutable, layered application package, for example `agent-api:v1` |
| Container | A running instance of an image |
| Registry | A service that stores and distributes images |
| Repository | A named image collection inside a registry, for example `agent-api` |
| Tag | A mutable label for an image manifest, for example `v1` |
| Digest | A content-derived, immutable image identifier |
| Revision | An immutable snapshot of a Container App configuration |
| Replica | A running instance of a revision |
| Scale rule | A condition that controls horizontal replica count |

Azure Container Apps uses declarative scale rules and KEDA. HTTP rules scale a revision according to concurrent HTTP requests. Changing scale rules creates a new immutable revision.

---

## Step 1: Prepare your workstation and Azure subscription

**Purpose:** Install the tools that build the application, build the image, and deploy Azure resources.

### 1.1 Required tools

Install the current stable versions of the following tools. Use PowerShell 7.4 or later throughout:

- [Visual Studio Code](https://code.visualstudio.com/)
- [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit)
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Docker Desktop](https://docs.docker.com/desktop/) or another Docker-compatible local engine
- [Git](https://git-scm.com/downloads)

.NET 10 is used because it is the current Long-Term Support release. Use current servicing patches, but keep the application target at `net10.0`.

### 1.2 Verify the tools

Open a **PowerShell 7** terminal in VS Code and run:

```powershell
$PSVersionTable.PSVersion
dotnet --version
az version
docker version
docker info --format '{{.OSType}}'
git --version
code --version
code --list-extensions | Select-String '^ms-dotnettools\.csdevkit$'
```

Start Docker Desktop if `docker version` cannot contact the Docker engine. The `docker info` command must return `linux`. On Windows, select **Linux containers**, not Windows containers. This tutorial builds `linux/amd64` images for ACA. ARM-based machines need a builder capable of amd64 emulation; if unavailable, use ACR Tasks for Azure builds and perform local-container steps on a compatible machine.

In every new PowerShell terminal, enable fail-fast handling for native tools:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
```

Do not continue after a failed command. Later scripts also check native exit codes explicitly. On Windows, if locally created scripts are blocked, review `Get-ExecutionPolicy -List` and use an organization-approved policy; do not bypass managed policy.

### 1.3 Sign in and select the subscription

For a standard sign-in, run:

```powershell
az login
```

If the subscription belongs to a different Microsoft Entra tenant, specify that tenant explicitly instead:

```powershell
az login --tenant "<tenant-id>"
```

Then select and verify the subscription:

```powershell
az account list --output table
az account set --subscription "<subscription-name-or-id>"
az account show --query "{subscription:name, subscriptionId:id, tenantId:tenantId, user:user.name}" --output table
```

Replace `<tenant-id>` with the tenant GUID and `<subscription-name-or-id>` with the subscription you intend to use. Confirm that both the subscription and tenant displayed by `az account show` are correct before continuing. If you are already signed in to the intended tenant and subscription, run only the verification command.

### 1.4 Install the Container Apps extension and register providers

```powershell
az extension add --name containerapp --upgrade
az extension show --name containerapp --query "{name:name, version:version}" --output table
az containerapp --help

az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
```

The `--wait` option blocks until each registration finishes. Verify the final states:

```powershell
az provider show --namespace Microsoft.App --query registrationState --output tsv
az provider show --namespace Microsoft.OperationalInsights --query registrationState --output tsv
az provider show --namespace Microsoft.ContainerRegistry --query registrationState --output tsv
```

All three commands should eventually return `Registered`.

> **Permissions:** You need permission to create the resources and role assignments used below. `Contributor` can create resources but cannot normally create role assignments. `Owner`, `User Access Administrator`, or a suitable delegated role is required for the `AcrPull` assignment.
>
> **Cost:** ACR, Log Analytics, and Container Apps can incur charges. The ACR cloud-build command also requires ACR Tasks availability. Use the cleanup step when finished.

### Acceptance criteria

- [ ] PowerShell 7, `dotnet`, `az`, `docker`, `git`, and `code` commands run successfully.
- [ ] C# Dev Kit appears in the VS Code extension list.
- [ ] Docker reports both client and server information, and its server operating system is `linux`.
- [ ] `az account show` displays the intended subscription and tenant.
- [ ] The Container Apps extension is installed and `az containerapp --help` succeeds.
- [ ] `Microsoft.App`, `Microsoft.OperationalInsights`, and `Microsoft.ContainerRegistry` report `Registered`.

---

## Step 2: Create the solution and repository

**Purpose:** Create a minimal, understandable project structure before adding container and Azure concerns.

### 2.1 Create the folders and solution

When starting from a parent directory, create and initialize a new repository:

```powershell
mkdir aca-scale-csharp
Set-Location aca-scale-csharp

git init
```

If the current directory is already the Git repository you intend to use, skip the preceding commands. From the repository root, run:

```powershell
dotnet new sln --name AcaScale --format sln
mkdir src, scripts, artifacts

dotnet new web --name Agent.Api --output ./src/Agent.Api --framework net10.0
dotnet sln ./AcaScale.sln add ./src/Agent.Api/Agent.Api.csproj
```

### 2.2 Create `global.json`

Run:

```powershell
$SdkVersion = dotnet --version
if ($SdkVersion -notmatch '^10\.0\.\d+$') {
    throw 'Select a stable .NET 10 SDK before creating global.json. Check dotnet --list-sdks.'
}
dotnet new globaljson --sdk-version $SdkVersion --roll-forward latestFeature

$GlobalJson = Get-Content ./global.json -Raw | ConvertFrom-Json
$GlobalJson.sdk | Add-Member -NotePropertyName allowPrerelease -NotePropertyValue $false -Force
$GlobalJson | ConvertTo-Json -Depth 10 | Set-Content ./global.json -Encoding utf8
```

This selects .NET 10 while allowing later .NET 10 feature bands and patches. It also excludes prerelease SDKs. The Dockerfile copies this file before restore, so both builds use the same major/minor and roll-forward policy. The floating SDK image can still have a different compatible servicing version; this is not an exact SDK pin.

### 2.3 Create `.gitignore`

Create `.gitignore` in the repository root:

```gitignore
**/bin/
**/obj/
artifacts/
.vs/
.vscode/
.env
.env.ps1
.lab-settings.json
*.user
*.suo
```

If the repository already has a comprehensive `.gitignore`, preserve it and add only any missing patterns from this list. Git does not retain empty directories; `scripts` and `artifacts` will appear in version control after later steps add files to them.

### 2.4 Build the generated project

```powershell
dotnet restore
dotnet build --configuration Release --no-restore
```

### Acceptance criteria

- [ ] `AcaScale.sln` contains `src/Agent.Api/Agent.Api.csproj`.
- [ ] The project targets `net10.0`.
- [ ] `global.json` selects a stable .NET 10 SDK, uses `latestFeature`, and disables prerelease SDKs.
- [ ] `dotnet build --configuration Release` completes with no errors.
- [ ] Build output and generated environment files are excluded from Git.

---

## Step 3: Implement the C# Minimal API

**Purpose:** Create a real C# API whose delayed requests make HTTP concurrency and scale-out observable.

Replace `src/Agent.Api/Program.cs` with:

```csharp
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "v1";
var defaultDelayMs = int.TryParse(
    Environment.GetEnvironmentVariable("AGENT_DEFAULT_DELAY_MS"),
    out var configuredDelay)
    ? Math.Clamp(configuredDelay, 0, 30_000)
    : 500;

app.MapGet("/", () => Results.Ok(new
{
    service = "agent-api",
    version,
    message = "C# API running in Azure Container Apps"
}));

app.MapGet("/health", () => Results.Ok(new { status = "Healthy" }));

app.MapGet("/api/info", () => Results.Ok(new
{
    service = "agent-api",
    version,
    machine = Environment.MachineName,
    defaultDelayMs,
    framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription
}));

app.MapPost("/api/process", async (ProcessRequest? request, CancellationToken cancellationToken) =>
{
    var delayMs = Math.Clamp(request?.DelayMilliseconds ?? defaultDelayMs, 0, 30_000);
    var stopwatch = Stopwatch.StartNew();

    await Task.Delay(delayMs, cancellationToken);

    return Results.Ok(new ProcessResponse(
        request?.Prompt ?? "demo request",
        version,
        Environment.MachineName,
        delayMs,
        stopwatch.ElapsedMilliseconds));
});

app.Run();

public sealed record ProcessRequest(string? Prompt, int? DelayMilliseconds);

public sealed record ProcessResponse(
    string Prompt,
    string Version,
    string Machine,
    int RequestedDelayMilliseconds,
    long ElapsedMilliseconds);
```

The `machine` value identifies the replica that processed a request. The endpoint caps delay at 30 seconds to keep the load test controlled.

### 3.1 Run the API directly

```powershell
$env:ASPNETCORE_URLS = "http://localhost:8080"
$env:APP_VERSION = "v1"
$env:AGENT_DEFAULT_DELAY_MS = "500"
dotnet run --project ./src/Agent.Api --no-launch-profile
```

Open a second PowerShell terminal at the repository root:

```powershell
Invoke-RestMethod http://localhost:8080/
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/api/info

$body = @{ prompt = "Explain autoscaling"; delayMilliseconds = 1000 } | ConvertTo-Json
Invoke-RestMethod `
    -Method Post `
    -Uri http://localhost:8080/api/process `
    -ContentType application/json `
    -Body $body
```

Confirm the startup log says `Now listening on: http://localhost:8080`. `--no-launch-profile` prevents the generated launch profile from overriding the port. Stop the application with **Ctrl+C** in the first terminal.

### Acceptance criteria

- [ ] `GET /`, `/health`, and `/api/info` return HTTP 200 responses.
- [ ] `POST /api/process` returns the prompt, version, machine, and elapsed duration.
- [ ] The returned elapsed duration is approximately the requested delay.
- [ ] The application listens on port `8080` without a container.

---

## Step 4: Publish and inspect the .NET application

**Purpose:** Separate .NET publishing from container-image building.

### 4.1 Publish

```powershell
Remove-Item ./artifacts/publish -Recurse -Force -ErrorAction SilentlyContinue

dotnet publish ./src/Agent.Api/Agent.Api.csproj `
    --configuration Release `
    --output ./artifacts/publish

Get-ChildItem ./artifacts/publish
```

Important output includes:

- `Agent.Api.dll`: compiled application assembly.
- `Agent.Api.deps.json`: dependency graph.
- `Agent.Api.runtimeconfig.json`: runtime configuration.
- Dependency assemblies, when required, and application configuration files.

### 4.2 Run the published application

```powershell
$env:ASPNETCORE_URLS = "http://localhost:8080"
$env:APP_VERSION = "v1"
$env:AGENT_DEFAULT_DELAY_MS = "500"
dotnet ./artifacts/publish/Agent.Api.dll
```

In another terminal:

```powershell
Invoke-RestMethod http://localhost:8080/api/info
```

Confirm that the response reports version `v1` and `defaultDelayMs` as `500`, then stop the application with **Ctrl+C**.

> This is a framework-dependent publish. The output does not include the entire .NET runtime, so running the DLL locally requires a compatible .NET 10 ASP.NET Core runtime. The runtime will be supplied later by the ASP.NET Core runtime base image.

### Acceptance criteria

- [ ] `artifacts/publish` contains `Agent.Api.dll`, `.deps.json`, and `.runtimeconfig.json`.
- [ ] `dotnet ./artifacts/publish/Agent.Api.dll` starts the API successfully.
- [ ] The published API returns HTTP 200 from `/api/info` with version `v1` and default delay `500`.
- [ ] You can explain that `dotnet publish` creates deployable application files but does not create a container image.

---

## Step 5: Create the Dockerfile and build context

**Purpose:** Define exactly how source becomes a small, runnable Linux image.

### 5.1 Create `.dockerignore`

Create `.dockerignore` in the repository root:

```dockerignore
.git
.gitignore
.vs
.vscode
**/bin
**/obj
artifacts
.env
.env.ps1
.lab-settings.json
README.md
```

The build context is the repository root, but ignored files are not sent to the Docker builder.

### 5.2 Create the multi-stage Dockerfile

Create `src/Agent.Api/Dockerfile`:

```dockerfile
# Build stage: contains the .NET SDK, compiler, and NuGet tooling.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy the project first so package restore can be cached independently.
COPY global.json ./
COPY src/Agent.Api/Agent.Api.csproj src/Agent.Api/
RUN dotnet restore src/Agent.Api/Agent.Api.csproj

# Copy source and publish a framework-dependent Release build.
COPY src/Agent.Api/ src/Agent.Api/
RUN dotnet publish src/Agent.Api/Agent.Api.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore \
    /p:UseAppHost=false

# Runtime stage: excludes the SDK and source code.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

COPY --from=build /app/publish .

# The .NET Linux image supplies this unprivileged user.
USER $APP_UID

ENTRYPOINT ["dotnet", "Agent.Api.dll"]
```

### 5.3 Understand the stages

- `sdk:10.0` contains build tools and produces `/app/publish`.
- `aspnet:10.0` contains only the runtime needed by ASP.NET Core.
- `COPY --from=build` transfers only published output to the final stage.
- `USER $APP_UID` avoids running the application as root.
- `EXPOSE 8080` documents the intended container port. It does not publish a host port.
- `ENTRYPOINT` starts the DLL when a container starts.

> The `10.0` base-image tag receives servicing updates. Rebuild the image regularly. For rigorously reproducible production releases, pin approved base-image digests and automate dependency refreshes.

### Acceptance criteria

- [ ] `.dockerignore` excludes Git metadata, local build output, and environment files.
- [ ] The Dockerfile has separate SDK build and ASP.NET runtime stages.
- [ ] The final stage copies only published output and runs as a non-root user.
- [ ] The application is configured to listen on container port `8080`.

---

## Step 6: Build, run, and inspect the local image

**Purpose:** Make the image-building process visible before Azure automates it.

### 6.1 Build the image

From the repository root:

```powershell
$ExistingContainer = docker ps --all --filter "name=^/agent-api$" --format '{{.Names}}'
if ($ExistingContainer) {
    throw "A container named 'agent-api' already exists. Inspect it before deciding whether to remove it."
}

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
    throw 'Host port 8080 is already in use.'
}

docker build `
    --platform linux/amd64 `
    --progress=plain `
    --file ./src/Agent.Api/Dockerfile `
    --tag agent-api:v1 `
    .
```

The final `.` is the **build context**. The Dockerfile can copy only files that are inside this context and not excluded by `.dockerignore`.

During the build, observe:

1. Docker resolves the SDK and runtime base images.
2. The project file is copied and NuGet restore runs.
3. Source files are copied and `dotnet publish` runs.
4. A fresh runtime stage is created.
5. Published files are copied into the runtime stage.
6. Docker records runtime metadata and assigns the local tag `agent-api:v1`.

### 6.2 Inspect the image

```powershell
docker image ls agent-api
docker image inspect agent-api:v1
docker image inspect agent-api:v1 `
    --format 'OS={{.Os}} Architecture={{.Architecture}} User={{.Config.User}} Ports={{json .Config.ExposedPorts}} Entrypoint={{json .Config.Entrypoint}}'
docker history agent-api:v1
```

Record the image ID and size. Confirm that the formatted output reports `linux`, `amd64`, a nonzero user, and port `8080/tcp`. `docker history` shows the final stage and its runtime base history. The SDK build-stage layers are not retained. Use the build logs to inspect restore and publish, or build a separately tagged `--target build` image when investigating that stage.

### 6.3 Run a container

```powershell
docker run `
    --detach `
    --name agent-api `
    --publish 8080:8080 `
    --env APP_VERSION=v1 `
    --env AGENT_DEFAULT_DELAY_MS=500 `
    agent-api:v1
```

`--publish 8080:8080` maps host port `8080` to container port `8080`.

Test and inspect:

```powershell
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/api/info
docker ps
docker logs agent-api
docker inspect agent-api --format '{{.Config.Image}}'
docker inspect agent-api --format 'User={{.Config.User}} Ports={{json .NetworkSettings.Ports}}'
```

If the first request races container startup, use `docker logs agent-api` to confirm that the application is listening on port `8080`, then retry. The health response should report `Healthy`; the info response should report version `v1`, default delay `500`, and a container machine name.

### 6.4 Remove only the container

```powershell
docker stop agent-api
docker rm agent-api
docker image ls agent-api
```

The container is gone, but the reusable image remains.

### 6.5 Rebuild to observe caching

Run the same build command again without changing the source. Restore, publish, and other unchanged eligible steps should report `CACHED` in the plain progress output.

Optionally, make a temporary change to one message in `Program.cs` and rebuild to observe that source-dependent steps run again while earlier restore layers remain cached. Revert that temporary change and run the build once more before continuing, so `agent-api:v1` matches the checked-in source.

### Acceptance criteria

- [ ] `docker build` creates `agent-api:v1` successfully.
- [ ] Image inspection reports Linux AMD64, port `8080/tcp`, and a non-root configured user.
- [ ] `docker history` shows the final runtime image history, including the published-output copy, not the SDK-stage restore/publish layers.
- [ ] A container created from `agent-api:v1` returns HTTP 200 from `/health` and `/api/info`.
- [ ] The response reports `version = v1` and a container machine name.
- [ ] Removing the container does not remove the image.
- [ ] A second build demonstrates layer caching.

---

## Step 7: Define Azure names and create ACR

**Purpose:** Create a private registry and prepare a registry-qualified image name.

### 7.1 Define variables

Use lowercase names. ACR names must be globally unique and contain only alphanumeric characters.

```powershell
$Location = "australiaeast"
$ResourceGroup = "rg-aca-scale-csharp"
$ContainerAppName = "agent-api"
$ImageRepository = "agent-api"
$ImageTag = "v1"

$Account = az account show --output json | ConvertFrom-Json
$SubscriptionId = $Account.id
$TenantId = $Account.tenantId
if (-not $SubscriptionId -or -not $TenantId) {
    throw 'Unable to determine the active Azure subscription and tenant.'
}
$Account | Select-Object name, id, tenantId, user

$UserObjectId = az ad signed-in-user show --query id --output tsv
if (-not $UserObjectId) { throw "Unable to determine the signed-in user. Run az login." }

$AcrProviderState = az provider show --subscription $SubscriptionId `
    --namespace Microsoft.ContainerRegistry --query registrationState --output tsv
if ($AcrProviderState -ne 'Registered') {
    throw 'Microsoft.ContainerRegistry is not registered in the active subscription.'
}

$LocationDisplayName = az account list-locations --subscription $SubscriptionId `
    --query "[?name=='$Location'].displayName | [0]" --output tsv
$AcrLocations = az provider show --subscription $SubscriptionId `
    --namespace Microsoft.ContainerRegistry `
    --query "resourceTypes[?resourceType=='registries'].locations | [0]" `
    --output json | ConvertFrom-Json
if (-not $LocationDisplayName -or $AcrLocations -notcontains $LocationDisplayName) {
    throw "Azure Container Registry is not available in $Location."
}

$Sha1 = [System.Security.Cryptography.SHA1]::Create()
$HashBytes = $Sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$UserObjectId/$SubscriptionId/$ResourceGroup"))
$Hash = ([System.BitConverter]::ToString($HashBytes)).Replace("-", "").ToLowerInvariant().Substring(0, 8)

$AcrName = "acr$Hash"
$ContainerAppsEnvironment = "aca-env-$Hash"

$ResourceGroup
$AcrName
$ContainerAppsEnvironment
```

Confirm that the displayed subscription and tenant are the ones selected in Step 1 before continuing.

Check for existing resources and global ACR name availability before creating anything:

```powershell
$GroupExists = (az group exists --subscription $SubscriptionId --name $ResourceGroup) -eq 'true'
if ($GroupExists) {
    $ExistingLocation = az group show --subscription $SubscriptionId `
        --name $ResourceGroup --query location --output tsv
    if ($ExistingLocation -ne $Location) {
        throw "Resource group $ResourceGroup already exists in $ExistingLocation, not $Location."
    }
}

$ExistingAcr = az acr list --subscription $SubscriptionId `
    --query "[?name=='$AcrName'] | [0]" --output json | ConvertFrom-Json

if ($ExistingAcr) {
    if ($ExistingAcr.resourceGroup -ne $ResourceGroup) {
        throw "Registry $AcrName already exists in another resource group."
    }
} else {
    $NameCheck = az acr check-name --subscription $SubscriptionId `
        --name $AcrName --output json | ConvertFrom-Json
    if (-not $NameCheck.nameAvailable) {
        throw "Registry name $AcrName is unavailable: $($NameCheck.message)"
    }
}
```

Do not silently reuse a resource group or registry whose ownership or configuration is uncertain. If the globally unique registry name is unavailable outside your subscription, choose another lowercase alphanumeric name and persist that choice below.

### 7.2 Create the resource group and ACR

```powershell
az group create --subscription $SubscriptionId `
    --name $ResourceGroup `
    --location $Location `
    --output table

if (-not $ExistingAcr) {
    az acr create --subscription $SubscriptionId `
        --resource-group $ResourceGroup `
        --name $AcrName `
        --sku Basic `
        --role-assignment-mode rbac `
        --admin-enabled false `
        --output table
}

$Registry = az acr show --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $AcrName `
    --output json | ConvertFrom-Json

if ($Registry.provisioningState -ne 'Succeeded' -or
    $Registry.location -ne $Location -or
    $Registry.sku.name -ne 'Basic' -or
    $Registry.adminUserEnabled -ne $false -or
    $Registry.roleAssignmentMode -ne 'LegacyRegistryPermissions') {
    throw 'The registry does not match the required location, SKU, admin, provisioning, or RBAC settings.'
}

$AcrLoginServer = $Registry.loginServer
if ($AcrLoginServer -notlike '*.azurecr.io') {
    throw 'Unexpected ACR login server.'
}

$RegistryImage = "$AcrLoginServer/${ImageRepository}:$ImageTag"
$RegistryImage
```

Check the registry uses ordinary registry RBAC, not repository ABAC:

```powershell
$Registry.roleAssignmentMode
```

The `--role-assignment-mode rbac` input is reported by the service as `LegacyRegistryPermissions`. This is ordinary registry RBAC, not repository ABAC.

If an existing registry uses repository ABAC, do not assume `AcrPull`/`AcrPush` apply; use a separate lab registry or obtain an approved role design. If the generated registry name is unavailable, choose another lowercase alphanumeric name and use it consistently.

The ACR admin account remains disabled. Your interactive push uses your Microsoft Entra identity.

### 7.3 Authenticate Docker to ACR

```powershell
az acr login --name $AcrName --subscription $SubscriptionId
```

If login or push fails with authorization errors, ensure your identity has an appropriate ACR data-plane role, such as `AcrPush`, for this lab's registry permission mode.

### 7.4 Persist settings for later terminals

Save these non-secret values now so Steps 8–10 do not depend on keeping this PowerShell session open. The deployment helper created in Step 10 uses the same schema and later fills in the application endpoint values.

```powershell
$Root = (Get-Location).Path
$ContainerAppFqdn = ''
$ContainerAppUrl = ''

$LabSettings = [ordered]@{
    SubscriptionId=$SubscriptionId; Location=$Location; ResourceGroup=$ResourceGroup
    ContainerAppName=$ContainerAppName; ImageRepository=$ImageRepository; ImageTag=$ImageTag
    AcrName=$AcrName; AcrLoginServer=$AcrLoginServer
    ContainerAppsEnvironment=$ContainerAppsEnvironment; RegistryImage=$RegistryImage
    ContainerAppFqdn=$ContainerAppFqdn; ContainerAppUrl=$ContainerAppUrl
}
$LabSettings | ConvertTo-Json | Set-Content (Join-Path $Root '.lab-settings.json')

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
```

Both files are excluded by `.gitignore` and `.dockerignore`. In a new terminal at the repository root, restore the values with `. ./.env.ps1`; the loader does not change the active Azure subscription.

### Acceptance criteria

- [ ] The active tenant, subscription, provider registration, region, existing resources, and ACR name availability are verified before creation.
- [ ] The resource group exists in `australiaeast` or your selected supported region.
- [ ] A Basic ACR reports `Succeeded`, `LegacyRegistryPermissions`, and an admin account that remains disabled.
- [ ] `$AcrLoginServer` ends with `.azurecr.io`.
- [ ] `$RegistryImage` has the form `<registry>.azurecr.io/agent-api:v1`.
- [ ] `az acr login` succeeds without using the ACR admin account.
- [ ] `. ./.env.ps1` restores the same non-secret subscription, resource, and image values in a new terminal.

---

## Step 8: Tag and push the local image

**Purpose:** Understand the boundary between a local image and an image stored in ACR.

### 8.1 Add a registry-qualified tag

```powershell
docker tag agent-api:v1 $RegistryImage
docker image ls agent-api
docker image ls $AcrLoginServer/agent-api
```

A tag does not copy the layers. It adds another reference to the same local image content.

### 8.2 Push the image

```powershell
docker push $RegistryImage
```

Docker uploads missing layers, then publishes an image manifest and associates `v1` with it.

### 8.3 Inspect the repository and digest

```powershell
az acr repository list --subscription $SubscriptionId `
    --name $AcrName `
    --output table

az acr repository show-tags --subscription $SubscriptionId `
    --name $AcrName `
    --repository $ImageRepository `
    --detail `
    --output table

az acr manifest list-metadata --subscription $SubscriptionId `
    --registry $AcrName `
    --name $ImageRepository `
    --output table
```

The tag `v1` is readable but mutable. The manifest digest identifies specific image content.

### Acceptance criteria

- [ ] The local image has both `agent-api:v1` and the registry-qualified tag.
- [ ] `docker push` completes successfully.
- [ ] ACR contains repository `agent-api` and tag `v1`.
- [ ] You can identify the image manifest digest.
- [ ] You can explain that ACR stores the image but does not run it.

---

## Step 9: Compare local build-and-push with `az acr build`

**Purpose:** Reveal what the supplied Python script combines into one cloud-build command.

Run:

```powershell
az acr build --subscription $SubscriptionId `
    --platform linux/amd64 `
    --resource-group $ResourceGroup `
    --registry $AcrName `
    --image "${ImageRepository}:cloud-v1" `
    --file ./src/Agent.Api/Dockerfile `
    .
```

Do not use `--no-logs`; inspect the cloud build output.

Compare the workflows:

| Local workflow | ACR cloud build |
|---|---|
| `docker build` creates an image locally | Source context is uploaded to ACR Tasks |
| `docker tag` adds registry name | `--image` defines the repository and tag |
| `docker push` uploads layers and manifest | ACR Tasks pushes the result directly into ACR |
| Requires a local Docker engine | Build runs in Azure |
| Best for learning and local testing | Useful for automated or remote builds |

The Dockerfile is the same in both cases. The builder location changes.

> Some subscription offers or policies restrict ACR Tasks. If `az acr build` is unavailable, continue with the already-pushed `v1` image. The rest of the tutorial does not require cloud build.

### Acceptance criteria

- [ ] `cloud-v1` appears in ACR, or an ACR Tasks restriction is documented and `v1` remains available.
- [ ] You can explain that `az acr build` uploads the build context, runs the Dockerfile remotely, and stores the result in ACR.
- [ ] You can distinguish build context, Dockerfile, image, tag, repository, and registry.

---

## Step 10: Bootstrap identity, configure probes, and deploy the private image

**Purpose:** Create a usable identity before asking ACA to pull the private image. This lab retains a system-assigned identity for continuity with the original exercise. A pre-authorized user-assigned identity is an alternative for production IaC.

### 10.1 Create the shared helper file

Create `scripts/Common.ps1` with the complete content below. It checks every native exit code, pins resource commands to the saved subscription, bounds endpoint and intended-revision readiness waits, validates the revision image and scale settings, saves session settings, and generates the YAML used by both manual deployment and the menu script. It contains no credentials.

```powershell
#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([Parameter(Mandatory)][string]$File,
          [Parameter(Mandatory)][string[]]$Arguments)
    # Pin resource commands to the saved subscription, even if CLI defaults change.
    # Account and directory commands intentionally retain their own context.
    if ($File -eq 'az' -and $Arguments[0] -notin @('account','ad')) {
        if (-not (Get-Variable SubscriptionId -ValueOnly -ErrorAction SilentlyContinue)) {
            throw 'Load or initialize the lab SubscriptionId before resource commands.'
        }
        if ($Arguments -contains '--subscription') {
            throw 'Do not override subscription in helper arguments; the saved lab subscription is authoritative.'
        }
        $Arguments = $Arguments + @('--subscription', $SubscriptionId)
    }
    # Check every native command immediately, independent of caller preferences.
    $PSNativeCommandUseErrorActionPreference = $false
    $result = & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    $result
}
function Invoke-AzTsv {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = Invoke-Native -File az -Arguments ($Arguments + @('--output','tsv'))
    ($result | Out-String).Trim()
}
function Assert-LabSubscription {
    $active = Invoke-AzTsv -Arguments @('account','show','--query','id')
    if ($active -ne $SubscriptionId) {
        throw "Active subscription differs from saved lab subscription $SubscriptionId. Select it explicitly before continuing."
    }
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
        $appJson = Invoke-Native -File az -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--output','json')
        $current = ($appJson | Out-String) | ConvertFrom-Json
        if ($current.properties.latestRevisionName -ne $ExpectedRevision) {
            throw 'The latest revision changed during verification. Stop concurrent deployments and retry.'
        }
        $revisionJson = Invoke-Native -File az -Arguments @('containerapp','revision','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--revision',$ExpectedRevision,'--output','json')
        $revision = ($revisionJson | Out-String) | ConvertFrom-Json
        $p = $revision.properties
        if ($p.provisioningState -in @('Failed','Deprovisioned')) {
            throw "Revision $ExpectedRevision failed provisioning. Inspect system and console logs."
        }
        # A previously ready revision can legitimately be idle at zero replicas.
        $healthyOrIdle = $p.healthState -eq 'Healthy' -or $p.runningState -eq 'ScaleTo0'
        if ($current.properties.latestReadyRevisionName -eq $ExpectedRevision -and
            $p.provisioningState -eq 'Provisioned' -and $healthyOrIdle) {
            $template = $p.template
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
    throw "Revision $ExpectedRevision did not become ready within $TimeoutSeconds seconds. Inspect revision status and logs."
}
function Wait-Environment {
    param([int]$TimeoutSeconds = 900)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Invoke-AzTsv -Arguments @('containerapp','env','show','-g',$ResourceGroup,'-n',$ContainerAppsEnvironment,'--query','properties.provisioningState')
        if ($state -eq 'Succeeded') { return }
        if ($state -eq 'Failed') { throw 'Environment provisioning failed. Inspect Azure deployment errors.' }
        Start-Sleep 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Environment readiness timed out. Inspect provisioning state before continuing.'
}
function Wait-Agent {
    param([Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$ExpectedVersion,
          [string]$ExpectedMessage = '', [int]$TimeoutSeconds = 600)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastProblem = 'No successful response yet.'
    do {
        try {
            $info = Invoke-RestMethod "$Url/api/info" -TimeoutSec 30
            $health = Invoke-RestMethod "$Url/health" -TimeoutSec 30
            if ($info.version -eq $ExpectedVersion -and $health.status -eq 'Healthy') {
                if ($ExpectedMessage) {
                    $root = Invoke-RestMethod "$Url/" -TimeoutSec 30
                    if ($root.message -ne $ExpectedMessage) { throw 'Old source response is still being served.' }
                }
                $info
                return
            }
            $lastProblem = "Expected $ExpectedVersion; received $($info.version)."
        } catch { $lastProblem = $_.Exception.Message }
        Start-Sleep 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Endpoint verification timed out: $lastProblem Inspect revisions, image pull, and console/system logs."
}
function Save-LabEnvironment {
    # Save non-secret settings as JSON, then generate a session loader.
    $settings = [ordered]@{
        SubscriptionId=$SubscriptionId; Location=$Location; ResourceGroup=$ResourceGroup
        ContainerAppName=$ContainerAppName; ImageRepository=$ImageRepository; ImageTag=$ImageTag
        AcrName=$AcrName; AcrLoginServer=$AcrLoginServer
        ContainerAppsEnvironment=$ContainerAppsEnvironment; RegistryImage=$RegistryImage
        ContainerAppFqdn=$ContainerAppFqdn; ContainerAppUrl=$ContainerAppUrl
    }
    $settings | ConvertTo-Json | Set-Content (Join-Path $Root '.lab-settings.json')
    @'
$settings = Get-Content (Join-Path $PSScriptRoot '.lab-settings.json') -Raw | ConvertFrom-Json
foreach ($p in $settings.PSObject.Properties) { Set-Variable -Name $p.Name -Value $p.Value }
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
    param([int]$MinReplicas = 1, [int]$MaxReplicas = 1, [switch]$HttpScaling)
    $environmentId = Invoke-AzTsv -Arguments @('containerapp','env','show','-g',$ResourceGroup,'-n',$ContainerAppsEnvironment,'--query','id')
    $containerName = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.template.containers[0].name')
    if (-not $containerName) { throw 'Cannot determine existing container name.' }
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
    param([int]$MinReplicas = 1, [int]$MaxReplicas = 1, [switch]$HttpScaling)
    Assert-LabSubscription
    $path = Write-AppYaml -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas -HttpScaling:$HttpScaling
    Invoke-Native -File az -Arguments @('containerapp','update','-g',$ResourceGroup,'-n',$ContainerAppName,'--yaml',$path,'--output','table')
    $script:VerifiedRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestRevisionName')
    if (-not $script:VerifiedRevision) { throw 'No latest revision returned after deployment.' }
    Wait-AppRevision -ExpectedRevision $script:VerifiedRevision -ExpectedImage $RegistryImage -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas -HttpScaling:$HttpScaling
}
```

Load it from the repository root:

```powershell
$Root = (Get-Location).Path
. ./scripts/Common.ps1
$ContainerAppFqdn = ''
$ContainerAppUrl = ''
```

### 10.2 Create and verify the environment

```powershell
Invoke-Native -File az -Arguments @('containerapp','env','create','-g',$ResourceGroup,'-n',$ContainerAppsEnvironment,'--location',$Location,'--output','table')
Wait-Environment
```

The environment command provisions monitoring resources unless configured otherwise. Keep this lab in its own resource group and inspect the resulting resources.

### 10.3 Bootstrap with a public image

```powershell
Invoke-Native -File az -Arguments @(
    'containerapp','create','-g',$ResourceGroup,'-n',$ContainerAppName,
    '--environment',$ContainerAppsEnvironment,
    '--image','mcr.microsoft.com/k8se/quickstart:latest',
    '--system-assigned','--ingress','external','--target-port','80',
    '--min-replicas','1','--max-replicas','1','--output','table'
)
$PrincipalId = Invoke-AzTsv -Arguments @('containerapp','identity','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','principalId')
$AcrId = Invoke-AzTsv -Arguments @('acr','show','-g',$ResourceGroup,'-n',$AcrName,'--query','id')
if (-not $PrincipalId) { throw 'System-assigned identity was not created.' }
Invoke-Native -File az -Arguments @('role','assignment','create','--assignee-object-id',$PrincipalId,'--assignee-principal-type','ServicePrincipal','--role','AcrPull','--scope',$AcrId,'--output','table')
```

The public image temporarily listens on port 80. The private application configuration below switches ingress and probes to 8080 together. No registry admin credentials are used.

### 10.4 Check ACR authentication and configure registry access

```powershell
Invoke-Native -File az -Arguments @('acr','config','authentication-as-arm','show','-r',$AcrName)
```

ARM-audience tokens must be enabled for managed-identity image pull. If disabled, obtain approval before changing a policy-controlled registry. For this dedicated lab registry, enable them if needed:

```powershell
Invoke-Native -File az -Arguments @('acr','config','authentication-as-arm','update','-r',$AcrName,'--status','enabled')
Invoke-Native -File az -Arguments @('containerapp','registry','set','-g',$ResourceGroup,'-n',$ContainerAppName,'--server',$AcrLoginServer,'--identity','system')
```

Role propagation is asynchronous. Allow a few minutes before the first private-image deployment. If it fails, inspect the error and role scope, wait for propagation, then rerun the deployment below. Do not recreate the identity or grant broader roles blindly.

### 10.5 Apply private image, resources, ingress, and HTTP probes

```powershell
Publish-AppConfiguration
Get-Content ./artifacts/containerapp.yaml
$ContainerAppFqdn = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.configuration.ingress.fqdn')
$ContainerAppUrl = "https://$ContainerAppFqdn"
Wait-Agent -Url $ContainerAppUrl -ExpectedVersion $ImageTag
Save-LabEnvironment
```

Inspect the generated YAML: it declares the system identity, registry authentication, single-revision traffic, private image, 0.5 vCPU/1 GiB, port 8080, and explicit startup/readiness/liveness HTTP probes against `/health`. Creating the endpoint alone would not configure these probes. The health response is deliberately simple because this mock API has no external dependencies.

The generated YAML is authoritative for this **single-container lab app**, not a safe generic replacement for an existing production app with additional containers, secrets, domains, or settings.

### 10.6 Resume in another terminal

Confirm `.lab-settings.json` is in both `.gitignore` and `.dockerignore` (included in Steps 2 and 5). The generated YAML is already under ignored `artifacts/`.

```powershell
Select-String -Path ./.gitignore, ./.dockerignore -SimpleMatch '.lab-settings.json'
```

In every new terminal, start at the repository root and run:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = (Get-Location).Path
. ./.env.ps1
. ./scripts/Common.ps1
$ActualSubscription = Invoke-AzTsv -Arguments @('account','show','--query','id')
if ($ActualSubscription -ne $SubscriptionId) {
    throw 'Wrong active subscription. Select the saved lab subscription before continuing.'
}
```

The loader restores both ordinary PowerShell variables and the environment-variable aliases. It does not silently switch subscriptions. Settings are non-secret, but still excluded from source control and image context.

### Acceptance criteria

- [ ] The environment reports `Succeeded`.
- [ ] A system-assigned identity exists before private-image deployment.
- [ ] Its registry-scoped `AcrPull` assignment exists and registry authentication uses `system`.
- [ ] Ingress and all three HTTP probes target port 8080.
- [ ] `/api/info` returns `v1`, `/health` succeeds, and the new revision is healthy.
- [ ] A new terminal can restore all lab variables.

---

## Step 11: Configure HTTP autoscaling through CLI and YAML

**Purpose:** Demonstrate both configuration approaches used by the Learn exercise.

### 11.1 Apply the CLI scale rule

```powershell
Invoke-Native -File az -Arguments @(
    'containerapp','update','-g',$ResourceGroup,'-n',$ContainerAppName,
    '--min-replicas','0','--max-replicas','10',
    '--scale-rule-name','http-scaling','--scale-rule-type','http',
    '--scale-rule-http-concurrency','10','--output','table'
)
$VerifiedRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestRevisionName')
Wait-AppRevision -ExpectedRevision $VerifiedRevision -ExpectedImage $RegistryImage -MinReplicas 0 -MaxReplicas 10 -HttpScaling
Invoke-Native -File az -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.template.scale','--output','json')
```

The target is HTTP concurrency, not total lifetime requests or CPU usage. Scaling is sampled and asynchronous; the threshold is not a hard request-admission limit or an instantaneous promise of another replica.

### 11.2 Generate and apply the equivalent YAML

```powershell
$YamlPath = Write-AppYaml -MinReplicas 0 -MaxReplicas 10 -HttpScaling
Get-Content $YamlPath
Invoke-Native -File az -Arguments @('containerapp','update','-g',$ResourceGroup,'-n',$ContainerAppName,'--yaml',$YamlPath,'--output','table')
$VerifiedRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestRevisionName')
Wait-AppRevision -ExpectedRevision $VerifiedRevision -ExpectedImage $RegistryImage -MinReplicas 0 -MaxReplicas 10 -HttpScaling
```

Find this section in the generated file:

```yaml
    scale:
      minReplicas: 0
      maxReplicas: 10
      rules:
        - name: http-scaling
          http:
            metadata:
              concurrentRequests: '10'
```

This is an excerpt, not a standalone deployment file. Use the complete generated YAML, which preserves the lab's image, identity, probes, and ingress. To demonstrate a YAML change, edit `maxReplicas` in the generated file to `5`, apply it, capture `properties.latestRevisionName`, and call `Wait-AppRevision` with `-MinReplicas 0 -MaxReplicas 5 -HttpScaling` and the current image. Then regenerate/apply and verify the intended `0` to `10` configuration using the commands above. Do not leave the test limit in place.

Changing revision-scoped scale settings creates a new revision. Reapplying an identical configuration need not create another revision.

### Acceptance criteria

- [ ] Effective scale JSON has minimum 0, maximum 10, and HTTP target 10.
- [ ] You have applied and verified both CLI and YAML scale configuration.
- [ ] A changed scale configuration produces a new revision.
- [ ] Health probes and registry identity remain configured.

---

## Step 12: Sustain concurrent load and observe the selected revision

### 12.1 Create `scripts/Invoke-AgentLoad.ps1`

```powershell
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$ApiUrl,
    [ValidateRange(30,600)][int]$DurationSeconds = 180,
    [ValidateRange(1,100)][int]$Parallelism = 50,
    [ValidateRange(0,30000)][int]$DelayMilliseconds = 10000
)
$ErrorActionPreference = 'Stop'
$endpoint = "$($ApiUrl.TrimEnd('/'))/api/process"
$deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
$watch = [Diagnostics.Stopwatch]::StartNew()
# A fixed number of workers sustains load; only aggregated results are retained.
$results = 1..$Parallelism | ForEach-Object -Parallel {
    $ok = 0; $failed = 0
    $machines = [Collections.Generic.HashSet[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    while ([DateTime]::UtcNow -lt $using:deadline) {
        try {
            $body = @{prompt='bounded scaling test'; delayMilliseconds=$using:DelayMilliseconds} | ConvertTo-Json
            $response = Invoke-RestMethod -Method Post -Uri $using:endpoint -ContentType 'application/json' -Body $body -TimeoutSec 90
            $ok++
            [void]$machines.Add([string]$response.machine)
        } catch {
            $failed++
            if ($errors.Count -lt 3) { $errors.Add($_.Exception.Message) }
            Start-Sleep -Milliseconds 500
        }
    }
    [pscustomobject]@{Succeeded=$ok; Failed=$failed; Machines=@($machines); Errors=@($errors)}
} -ThrottleLimit $Parallelism
$watch.Stop()
$successes = ($results | Measure-Object Succeeded -Sum).Sum
$failures = ($results | Measure-Object Failed -Sum).Sum
$machines = @($results | ForEach-Object {$_.Machines} | Sort-Object -Unique)
[pscustomobject]@{
    Succeeded=$successes; Failed=$failures; Parallelism=$Parallelism
    RequestedDurationSeconds=$DurationSeconds
    ElapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    MachinesObserved=$machines.Count; Machines=($machines -join ', ')
}
if ($failures -gt 0) {
    $results | ForEach-Object {$_.Errors} | Select-Object -First 5
    throw 'Some load requests failed. Inspect errors before accepting the test.'
}
if ($successes -eq 0) { throw 'No requests succeeded.' }
```

The script starts at most 100 workers for at most 600 seconds. Requests already in progress can finish after the duration deadline, up to their timeout. Use only against your own lab endpoint. The public API is unauthenticated for this exercise; it is not a production security design.

### 12.2 Warm up and select the revision

Before endpoint warm-up, verify the latest intended revision, not merely whichever revision was last ready. A healthy endpoint can still be served by the previous revision during rollout.

```powershell
$VerifiedRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestRevisionName')
Wait-AppRevision -ExpectedRevision $VerifiedRevision -ExpectedImage $RegistryImage -MinReplicas 0 -MaxReplicas 10 -HttpScaling
```


```powershell
Wait-Agent -Url $ContainerAppUrl -ExpectedVersion $ImageTag
$TestRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestReadyRevisionName')
if (-not $TestRevision -or $TestRevision -ne $VerifiedRevision) { throw 'Ready revision differs from the verified intended revision.' }
$TestRevision
```

In a second terminal, restore the session using Step 10.6. Resolve the ready revision there too, then monitor it for a bounded interval:

```powershell
$VerifiedRevision = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.latestRevisionName')
Wait-AppRevision -ExpectedRevision $VerifiedRevision -ExpectedImage $RegistryImage -MinReplicas 0 -MaxReplicas 10 -HttpScaling
$TestRevision = $VerifiedRevision
$MonitorUntil = [DateTime]::UtcNow.AddMinutes(12)
while ([DateTime]::UtcNow -lt $MonitorUntil) {
    $count = Invoke-AzTsv -Arguments @('containerapp','replica','list','-g',$ResourceGroup,'-n',$ContainerAppName,'--revision',$TestRevision,'--query','length(@)')
    Write-Host "$(Get-Date -Format HH:mm:ss) revision=$TestRevision replicas=$count"
    Start-Sleep 5
}
```

Do not deploy configuration changes while this test is running, because they can change which revision receives traffic.

### 12.3 Run the sustained test

In the first terminal:

```powershell
./scripts/Invoke-AgentLoad.ps1 -ApiUrl $ContainerAppUrl -DurationSeconds 180 -Parallelism 50 -DelayMilliseconds 10000
```

Observe replica counts during load, not only after the script finishes. The asynchronous delay keeps requests open without deliberately consuming CPU. Replica startup, routing, and metric evaluation take time; no exact replica count is guaranteed.

### 12.4 Verify scale-out and scale-in separately

```powershell
Invoke-Native -File az -Arguments @('containerapp','revision','list','-g',$ResourceGroup,'-n',$ContainerAppName,'--output','table')
Invoke-Native -File az -Arguments @('containerapp','replica','list','-g',$ResourceGroup,'-n',$ContainerAppName,'--revision',$TestRevision,'--output','table')
Invoke-Native -File az -Arguments @('containerapp','logs','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--type','system','--tail','100')
```

Stop all endpoint tests and browser refreshes after load. Keep the replica monitor running: management-plane queries do not themselves send requests to the app. Allow several minutes for scale-in; if zero is not reached within the monitoring window, inspect active traffic, minimum replicas, rules, and logs rather than assuming failure or waiting indefinitely. Stop the monitor with Ctrl+C if finished early.

Once zero is observed, send one request and note cold-start latency:

```powershell
Measure-Command { Invoke-RestMethod "$ContainerAppUrl/api/info" -TimeoutSec 90 | Out-Host }
```

### Acceptance criteria

- [ ] The load script reports successful requests and no unexplained failures.
- [ ] Platform monitoring shows the selected revision reaching at least two replicas during load.
- [ ] Record the distinct machine values as corroborating evidence. Multiple replicas can exist even if a particular request sample does not reach each one.
- [ ] After traffic stops, the revision scales in and eventually reaches zero.
- [ ] A subsequent request succeeds after cold start.

If scale-out is absent, inspect effective scale JSON, active/ready revision, successful traffic, system logs, and available quota. Repeat the bounded test for up to 300 seconds if necessary; do not raise concurrency indefinitely. Scaling decisions in logs are diagnostic evidence, not a substitute for demonstrating actual additional replicas.

---

## Step 13: Change source, build v2, and verify the release

### 13.1 Make a mandatory source change before building

In `src/Agent.Api/Program.cs`, replace the root endpoint message:

```csharp
message = "C# API running in Azure Container Apps - release v2"
```

Keep all other endpoints unchanged. `APP_VERSION` remains deployment configuration; the changed message is separate evidence that new source reached the image.

### 13.2 Build and push a distinct image

```powershell
$DigestV1 = Invoke-AzTsv -Arguments @('acr','repository','show','-n',$AcrName,'--image',"${ImageRepository}:v1",'--query','digest')
$ImageTag = 'v2'
$RegistryImage = "$AcrLoginServer/${ImageRepository}:$ImageTag"
Invoke-Native -File docker -Arguments @('build','--platform','linux/amd64','--file','./src/Agent.Api/Dockerfile','--tag','agent-api:v2','.')
Invoke-Native -File docker -Arguments @('tag','agent-api:v2',$RegistryImage)
Invoke-Native -File az -Arguments @('acr','login','--name',$AcrName)
Invoke-Native -File docker -Arguments @('push',$RegistryImage)
$DigestV2 = Invoke-AzTsv -Arguments @('acr','repository','show','-n',$AcrName,'--image',"${ImageRepository}:v2",'--query','digest')
if (-not $DigestV2 -or $DigestV1 -eq $DigestV2) { throw 'Expected a different image digest after the mandatory source change.' }
```

### 13.3 Deploy and verify code, configuration, and revision

```powershell
Publish-AppConfiguration -MinReplicas 0 -MaxReplicas 10 -HttpScaling
Wait-Agent -Url $ContainerAppUrl -ExpectedVersion v2 -ExpectedMessage 'C# API running in Azure Container Apps - release v2'
Invoke-Native -File az -Arguments @('containerapp','revision','list','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','[].{name:name,active:properties.active,image:properties.template.containers[0].image}','--output','table')
Save-LabEnvironment
```

Single-revision mode moves traffic when the new revision is ready. No fixed revision suffix is used, avoiding collisions when rerunning the exercise. Preserve `v1` and `v2` as separate lab release tags. Production pipelines should use immutable commit/build tags or digests and promote the same artifact between environments. A mutable tag alone is not an immutable release identity.

### Acceptance criteria

- [ ] `v1` and `v2` exist in ACR and their digests differ.
- [ ] The new revision references `v2`.
- [ ] `/api/info` reports `v2` and `/` returns the changed source message.
- [ ] Scaling, HTTP probes, and managed-identity registry access remain configured.

---

## Step 14: Create the checked PowerShell deployment menu

**Purpose:** Automate resource creation, image building, deployment, revision/configuration verification, and basic endpoint availability using the shared helpers. The menu is not a replacement for Step 13's independent new-release validation.

Create `scripts/Deploy-AcaScale.ps1`:

```powershell
#Requires -Version 7.4
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9][a-z0-9_.-]{0,127}$')][string]$ImageTag = '')
$RequestedTag = $ImageTag
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Common.ps1')
foreach ($command in @('az','docker','dotnet')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Missing tool: $command" }
}
if (-not (Test-Path (Join-Path $Root 'src/Agent.Api/Dockerfile'))) { throw 'Dockerfile missing.' }
$SubscriptionId = Invoke-AzTsv -Arguments @('account','show','--query','id')
$ActiveSubscription = $SubscriptionId
if (Test-Path (Join-Path $Root '.env.ps1')) {
    . (Join-Path $Root '.env.ps1')
    if ($SubscriptionId -ne $ActiveSubscription) { throw 'Active subscription differs from saved lab subscription.' }
} else {
    $Location = 'australiaeast'
    $ResourceGroup = 'rg-aca-scale-csharp'
    $ContainerAppName = 'agent-api'
    $ImageRepository = 'agent-api'
    $ImageTag = 'v1'
    $userId = Invoke-AzTsv -Arguments @('ad','signed-in-user','show','--query','id')
    if (-not $userId) { throw 'Interactive user sign-in is required.' }
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$userId/$SubscriptionId/$ResourceGroup")) }
    finally { $sha.Dispose() }
    $hash = ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant().Substring(0,8)
    $AcrName = "acr$hash"
    $ContainerAppsEnvironment = "aca-env-$hash"
    $AcrLoginServer = ''; $RegistryImage = ''
    $ContainerAppFqdn = ''; $ContainerAppUrl = ''
}
if ($RequestedTag) { $ImageTag = $RequestedTag }
function Resolve-Registry {
    $script:AcrLoginServer = Invoke-AzTsv -Arguments @('acr','show','-g',$ResourceGroup,'-n',$AcrName,'--query','loginServer')
    if (-not $script:AcrLoginServer) { throw 'Registry login server is empty.' }
    $mode = Invoke-AzTsv -Arguments @('acr','show','-g',$ResourceGroup,'-n',$AcrName,'--query','roleAssignmentMode')
    if ($mode -ne 'LegacyRegistryPermissions') { throw 'This lab requires registry RBAC, not repository ABAC.' }
    $script:RegistryImage = "$script:AcrLoginServer/${ImageRepository}:$ImageTag"
}
function New-LabRegistry {
    Invoke-Native -File az -Arguments @('group','create','-n',$ResourceGroup,'-l',$Location,'--output','table')
    $found = Invoke-AzTsv -Arguments @('acr','list','-g',$ResourceGroup,'--query',"[?name=='$AcrName'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @('acr','create','-g',$ResourceGroup,'-n',$AcrName,'--sku','Basic','--role-assignment-mode','rbac','--admin-enabled','false','--output','table')
    }
    Resolve-Registry
    Save-LabEnvironment
}
function Build-LabImage {
    param([switch]$Cloud)
    Resolve-Registry
    Push-Location $Root
    try {
        if ($Cloud) {
            Invoke-Native -File az -Arguments @('acr','build','-g',$ResourceGroup,'-r',$AcrName,'--platform','linux/amd64','--image',"${ImageRepository}:$ImageTag",'--file','./src/Agent.Api/Dockerfile','.')
        } else {
            $localImage = "${ImageRepository}:$ImageTag"
            Invoke-Native -File docker -Arguments @('version')
            Invoke-Native -File docker -Arguments @('build','--platform','linux/amd64','--file','./src/Agent.Api/Dockerfile','--tag',$localImage,'.')
            Invoke-Native -File az -Arguments @('acr','login','-n',$AcrName)
            Invoke-Native -File docker -Arguments @('tag',$localImage,$RegistryImage)
            Invoke-Native -File docker -Arguments @('push',$RegistryImage)
        }
    } finally { Pop-Location }
    Save-LabEnvironment
}
function New-LabEnvironment {
    $found = Invoke-AzTsv -Arguments @('containerapp','env','list','-g',$ResourceGroup,'--query',"[?name=='$ContainerAppsEnvironment'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @('containerapp','env','create','-g',$ResourceGroup,'-n',$ContainerAppsEnvironment,'-l',$Location,'--output','table')
    }
    Wait-Environment
}
function Deploy-LabApp {
    Resolve-Registry
    Wait-Environment
    $found = Invoke-AzTsv -Arguments @('containerapp','list','-g',$ResourceGroup,'--query',"[?name=='$ContainerAppName'].name")
    if (-not $found) {
        Invoke-Native -File az -Arguments @('containerapp','create','-g',$ResourceGroup,'-n',$ContainerAppName,'--environment',$ContainerAppsEnvironment,'--image','mcr.microsoft.com/k8se/quickstart:latest','--system-assigned','--ingress','external','--target-port','80','--min-replicas','1','--max-replicas','1','--output','table')
    }
    $principal = Invoke-AzTsv -Arguments @('containerapp','identity','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','principalId')
    if (-not $principal) { throw 'Existing app has no system identity. Inspect before modifying it.' }
    $acrId = Invoke-AzTsv -Arguments @('acr','show','-g',$ResourceGroup,'-n',$AcrName,'--query','id')
    $assignment = Invoke-AzTsv -Arguments @('role','assignment','list','--scope',$acrId,'--query',"[?principalId=='$principal' && roleDefinitionName=='AcrPull'].id")
    if (-not $assignment) {
        Invoke-Native -File az -Arguments @('role','assignment','create','--assignee-object-id',$principal,'--assignee-principal-type','ServicePrincipal','--role','AcrPull','--scope',$acrId,'--output','table')
        Write-Host 'New role assignment: allowing 60 seconds for initial propagation.'
        Start-Sleep 60
    }
    $auth = Invoke-AzTsv -Arguments @('acr','config','authentication-as-arm','show','-r',$AcrName,'--query','status')
    if ($auth -ne 'enabled') { throw 'ARM-audience tokens are disabled. Review Step 10.4 before enabling them.' }
    Invoke-Native -File az -Arguments @('containerapp','registry','set','-g',$ResourceGroup,'-n',$ContainerAppName,'--server',$AcrLoginServer,'--identity','system')
    # Deliberately deploy with one fixed replica; menu 6 enables autoscaling.
    Publish-AppConfiguration
    $script:ContainerAppFqdn = Invoke-AzTsv -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.configuration.ingress.fqdn')
    $script:ContainerAppUrl = "https://$script:ContainerAppFqdn"
    Wait-Agent -Url $ContainerAppUrl -ExpectedVersion $ImageTag
    Save-LabEnvironment
}
function Show-LabStatus {
    Resolve-Registry
    Invoke-Native -File az -Arguments @('account','show','--query','{name:name,id:id,tenantId:tenantId}','--output','table')
    Invoke-Native -File az -Arguments @('acr','repository','show','-n',$AcrName,'--image',"${ImageRepository}:$ImageTag",'--output','table')
    Invoke-Native -File az -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','{state:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn,ready:properties.latestReadyRevisionName,image:properties.template.containers[0].image}','--output','table')
    Invoke-Native -File az -Arguments @('containerapp','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','properties.template.scale','--output','json')
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
                $active = Invoke-AzTsv -Arguments @('account','show','--query','id')
                if ($active -ne $SubscriptionId) { throw 'Subscription changed. Deletion blocked.' }
                Invoke-Native -File az -Arguments @('resource','list','-g',$ResourceGroup,'--output','table')
                if ((Read-Host "Delete ALL resources in '$ResourceGroup' in '$SubscriptionId'? Type DELETE") -eq 'DELETE') {
                    Invoke-Native -File az -Arguments @('group','delete','-n',$ResourceGroup,'--yes')
                    $exists = Invoke-AzTsv -Arguments @('group','exists','-n',$ResourceGroup)
                    if ($exists -ne 'false') { throw 'Deletion is not yet verified.' }
                    Write-Host 'Resource group deletion verified.'
                }
            }
            '9' { return }
            default { Write-Warning 'Select 1-9.' }
        }
    } catch {
        Write-Warning $_.Exception.Message
        Write-Warning 'Operation failed. No success is implied. Correct the cause before retrying.'
    }
}
```

Run from the repository root:

```powershell
./scripts/Deploy-AcaScale.ps1
```

For a fresh deployment, choose **1, then 2 (or 3), then 4, 5, 6, and 7**. On an existing lab, saved settings are reused and the registry login server is always queried. To select a new release tag, exit and restart with `-ImageTag v2`; make the source change before building. Do not rebuild a previously deployed release tag as a normal release practice.

**Release-validation boundary:** Menu options 5 and 6 verify the exact intended revision, image reference, replica bounds, HTTP rule where enabled, endpoint version, and health. They do not independently prove that a new source change was compiled into the image: `APP_VERSION` is deployment configuration. For every new release, Step 13 remains mandatory, including the source change, pre/post image-digest comparison, and `Wait-Agent -ExpectedMessage` check. A menu-only deployment is a deployment/availability check, not completed new-release validation.

All helper-issued resource commands include the saved `--subscription`. Before each menu operation, the active subscription is also checked; a mismatch blocks the operation rather than silently switching subscriptions.

Menu 5 intentionally restores the initial fixed-replica configuration. Run menu 6 afterwards to enable scaling again. A newly created role assignment gets an initial 60-second propagation allowance, not a guarantee. If deployment fails, inspect the error, allow further propagation if appropriate, and retry menu 5. The script does not loop indefinitely or conceal failed CLI calls. The endpoint wait is bounded at ten minutes.

This is an interactive lab script, not a service-principal CI/CD pipeline. Complete provider registration and permissions setup in Step 1 first. For an existing lab, `.env.ps1` and `.lab-settings.json` must be kept together. If intentionally starting again with different names or region, use a separate repository folder or archive both settings files and update the script's initial defaults before creating resources.

### Acceptance criteria

- [ ] Required tools, login, subscription, and Dockerfile are checked.
- [ ] Local and cloud builds explicitly target `linux/amd64`.
- [ ] Every native command is checked immediately; resource discovery errors are not treated as absence.
- [ ] Existing resources are reused and the registry hostname is queried.
- [ ] Private deployment follows public-image bootstrap, identity authorization, registry configuration, and YAML deployment.
- [ ] Deployment verifies the intended ready revision, image, replica bounds, applicable HTTP rule, expected version, and health before reporting completion.
- [ ] Every Azure resource operation is pinned to the saved subscription, and each menu operation checks active context.
- [ ] New-release validation still completes Step 13; menu availability checks alone are not accepted as proof of new source.
- [ ] Cleanup displays resources, checks subscription, and requires `DELETE`.

---

## Step 15: Troubleshoot common failures

**Purpose:** Diagnose the layer that failed instead of changing unrelated settings.

| Symptom | Likely cause | Check or correction |
|---|---|---|
| `dotnet build` fails | C# or project error | Run `dotnet build` directly and fix the first compiler error |
| Docker cannot find files | Wrong build context or `COPY` path | Run from repository root and keep final `.` |
| Local container starts but endpoint fails | Port mismatch | Confirm `ASPNETCORE_HTTP_PORTS=8080` and `-p 8080:8080` |
| `docker push` returns unauthorized | Missing ACR login or push permission | Run `az acr login`; verify ACR role assignment |
| ACR cloud build fails | ACR Tasks unavailable or Dockerfile error | Review build logs; use local build/push if tasks are restricted |
| Revision reports image-pull failure | Identity or `AcrPull` missing/propagating | Verify principal, role scope, registry identity; wait and update |
| Revision fails readiness/startup | Application crash or target-port error | Review console/system logs; confirm target port `8080` |
| Wrong local port | Generated launch profile overrides shell URL | Run with `--no-launch-profile`; inspect startup logs |
| Image architecture error | ARM or Windows image | Build `--platform linux/amd64`; use Linux containers |
| Managed-identity pull still fails | ARM-audience tokens disabled or registry permission mode mismatch | Inspect authentication-as-arm and registry RBAC mode |
| App does not scale out | Insufficient concurrency or wrong rule | Verify effective scale JSON; increase delay and parallel requests |
| App does not scale to zero immediately | Scale-in cooldown | Stop requests and wait; inspect running state and system logs |
| `$env:*` variables are empty in a new terminal | `.env.ps1` not loaded | Run `. ./.env.ps1` |

Useful commands:

```powershell
az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --type system --tail 100 --subscription $SubscriptionId
az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --type console --tail 100 --subscription $SubscriptionId
az containerapp revision list --name $ContainerAppName --resource-group $ResourceGroup --output table --subscription $SubscriptionId
az containerapp show --name $ContainerAppName --resource-group $ResourceGroup --query properties.template --output json --subscription $SubscriptionId
$PrincipalId = Invoke-AzTsv -Arguments @('containerapp','identity','show','-g',$ResourceGroup,'-n',$ContainerAppName,'--query','principalId')
$AcrId = Invoke-AzTsv -Arguments @('acr','show','-g',$ResourceGroup,'-n',$AcrName,'--query','id')
az role assignment list --scope $AcrId --query "[?principalId=='$PrincipalId']" --output table --subscription $SubscriptionId
```

### Acceptance criteria

- [ ] You can identify whether a failure occurred in C# build, publish, image build, registry push, image pull, startup, ingress, or scaling.
- [ ] You can retrieve Container Apps system and console logs.
- [ ] You can verify the deployed image reference, effective scale rule, revision state, and ACR role assignment.

---

## Step 16: Clean up

**Purpose:** Stop ongoing Azure charges after completing the lab.

Restore the session using Step 10.6 if necessary. This deletes **all** resources in the group, not just the app. Use a dedicated lab group. Confirm the active subscription and target resource group:

```powershell
az account show --query "{subscription:name,id:id}" --output table
az resource list --resource-group $ResourceGroup --output table --subscription $SubscriptionId
```

Check that the displayed subscription matches `$SubscriptionId` and that every listed resource belongs to this lab. Then delete the resource group:

```powershell
az group delete --subscription $SubscriptionId `
    --name $ResourceGroup `
    --yes
```

Verify deletion:

```powershell
az group exists --name $ResourceGroup --subscription $SubscriptionId
```

Expected result: `false`.

Optionally remove local containers and images:

```powershell
# Missing local containers/images are harmless only in this optional cleanup block.
$PSNativeCommandUseErrorActionPreference = $false
docker rm -f agent-api 2>$null
docker image rm agent-api:v1 agent-api:v2 "${AcrLoginServer}/${ImageRepository}:v1" "${AcrLoginServer}/${ImageRepository}:v2" 2>$null
$PSNativeCommandUseErrorActionPreference = $true
```

### Acceptance criteria

- [ ] `az group exists --name $ResourceGroup` returns `false`.
- [ ] The ACR, Container Apps environment, Container App, and associated monitoring resources no longer exist in the resource group.
- [ ] Unneeded local containers and images are removed.

---

# Final tutorial acceptance criteria

You have completed the tutorial when all of the following are true:

- [ ] A .NET 10 Minimal API runs directly from source and published output.
- [ ] A multi-stage Dockerfile restores, publishes, and packages the API.
- [ ] The final image uses the ASP.NET Core runtime image, excludes the SDK, and runs as non-root.
- [ ] `agent-api:v1` runs locally and responds on host port `8080`.
- [ ] You can inspect image layers, metadata, tags, and the ACR manifest digest.
- [ ] The image is pushed manually to ACR and, where available, built with ACR Tasks for comparison.
- [ ] ACA pulls the private image through managed identity rather than registry admin credentials.
- [ ] The application is reachable through external HTTPS ingress.
- [ ] CLI and YAML configuration demonstrate HTTP scaling from 0 to 10 replicas at target 10.
- [ ] Explicit HTTP startup, readiness, and liveness probes target `/health` on port 8080.
- [ ] Saved settings restore both ordinary and environment variables in a new terminal.
- [ ] Sustained bounded load produces at least two platform-observed replicas and the app later scales to zero.
- [ ] A mandatory source change produces a different `v2` image digest, a new revision, version `v2`, and the changed root message.
- [ ] The PowerShell deployment script automates deployment and availability checks; Step 13 independently validates each new release.
- [ ] Scaling tests monitor the verified intended revision, not a previously ready revision.
- [ ] Resource commands use the saved subscription, and registry creation explicitly selects RBAC mode.
- [ ] All Azure lab resources are deleted after completion.

# Image lifecycle summary

```text
Program.cs
  -> dotnet restore/build/publish
  -> published DLLs and configuration
  -> docker build reads Dockerfile and build context
  -> local OCI image agent-api:v1
  -> docker run creates a local container
  -> docker tag adds registry-qualified name
  -> docker push stores layers and manifest in ACR
  -> ACA authenticates and pulls the image
  -> ACA creates an immutable revision
  -> ACA starts one or more replicas
  -> KEDA-backed HTTP rule changes replica count
```

# Reference material

- [Scale containers in Azure Container Apps](https://learn.microsoft.com/en-gb/training/modules/scale-containers-azure-container-apps/)
- [Microsoft exercise: Configure autoscaling using KEDA triggers](https://microsoftlearning.github.io/mslearn-azure-ai/instructions/azure-container-apps/03-aca-scale-containers.html)
- [Set scaling rules in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/scale-app?pivots=azure-cli)
- [Tutorial: Scale an Azure Container Apps application](https://learn.microsoft.com/en-us/azure/container-apps/tutorial-scaling?tabs=bash)
- [Azure Container Apps revisions](https://learn.microsoft.com/en-us/azure/container-apps/revisions)
- [Azure Container Apps image pull with managed identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity-image-pull)
- [Azure Container Registry documentation](https://learn.microsoft.com/en-us/azure/container-registry/)
- [Azure CLI registry creation and permission-mode options](https://learn.microsoft.com/en-us/cli/azure/acr?view=azure-cli-latest)
- [Registry RBAC and ABAC repository permissions](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [KEDA](https://keda.sh/)
- [.NET releases and support](https://learn.microsoft.com/en-us/dotnet/core/releases-and-support)

- [Container image requirements](https://learn.microsoft.com/en-us/azure/container-apps/containers)
- [Container Apps health probes](https://learn.microsoft.com/en-us/azure/container-apps/health-probes)
- [Container Apps ARM and YAML specifications](https://learn.microsoft.com/en-us/azure/container-apps/azure-resource-manager-api-spec)
- [.NET 10 solution format change](https://learn.microsoft.com/en-us/dotnet/core/compatibility/sdk/10.0/dotnet-new-sln-slnx-default)
- [dotnet run and launch profiles](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-run)
- [global.json SDK selection](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json)
- [Docker multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [PowerShell preference variables and native-command errors](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables?view=powershell-7.6)

## Revision history and validation scope

| Version | Changes |
|---|---|
| 1.0 | Original C#/.NET and PowerShell image-lifecycle tutorial. |
| 1.1 | Explicit `.sln` creation; launch-profile correction; Linux/amd64 builds; shared SDK policy; deterministic system-identity bootstrap; checked native commands; bounded readiness waits; queried registry hostname; complete session restoration; explicit HTTP probes; CLI/YAML scaling; sustained revision-specific load; mandatory v2 source and digest verification; corrected final-image history explanation. |
| 1.2 | Added bounded intended-revision readiness and image/scale validation; pinned resource commands to the saved subscription and checked every menu operation; explicitly selected and enforced registry RBAC mode; clarified mandatory independent release validation and the menu verification boundary. |

Version 1.2 incorporates a static code and document review against the referenced documentation. It has not been executed end to end against an Azure subscription. Acceptance criteria are checks for the learner to perform, not claims of a completed deployment. Quotas, organizational policies, regional capacity, and RBAC propagation can affect provisioning and scaling.
