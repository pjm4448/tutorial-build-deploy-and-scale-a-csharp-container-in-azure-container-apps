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