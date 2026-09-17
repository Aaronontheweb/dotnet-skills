---
name: sdk-container-publishing-real-world-examples
description: Structural code examples of SDK container publishing drawn from Petabridge internal repositories - the minimal csproj pattern, tag-driven CI, and centralized settings.
---

# Real-World Examples

Structural examples drawn from internal Petabridge repos. Repo names are shown because they are public and safe; no secrets, credentials, or registry auth appear here by design. Registry hostnames are interior infra and shown only as placeholders.

## Minimal Project Override

Most services override only what they need and let the SDK infer the base image, user, working directory, and self-contained mode. The comment below explains the reasoning in a real project:

```xml
<PropertyGroup>
  <!-- The lab registry expects docker.example.internal/my-service:<tag>. Without this,
       the SDK derives the image name from the assembly name (my-service-api). Everything
       else the SDK defaults to is correct: the ASP.NET base image and port 8080. -->
  <ContainerRepository>my-service</ContainerRepository>
</PropertyGroup>

<ItemGroup>
  <PackageReference Include="Akka.Hosting" />
</ItemGroup>
```

Takeaway: only set `ContainerRepository` when the assembly name is not the image name you want. Leave everything else to the SDK defaults.

## Tag-Driven CI Publishing

A release pipeline that publishes on a git tag, using the explicit-tag pattern:

```yaml
on:
  push:
    tags:
      - '*'

jobs:
  publish-containers:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          global-json-file: global.json
      - name: Set up Docker daemon
        uses: docker/setup-docker-action@v4
      - name: Build and push Api
        run: |
          dotnet publish src/MyService.Api/MyService.Api.csproj \
            -p:VersionPrefix=${{ github.ref_name }} \
            -p:ContainerRegistry=docker.example.internal \
            -p:ContainerImageTag=${{ github.ref_name }} \
            -c Release /t:PublishContainer
```

Separate deployables (for example an API and an MCP server) each get their own publish step and their own `ContainerRepository`.

## Centralized Settings in Directory.Build.props

A monorepo centralizes image settings. The props file keys off `CI` and `AGENT_ID` so the same repo builds correctly in GitHub Actions and on build agents:

```xml
<PropertyGroup Label="ContainerSettings" Condition=" '$(CI)' == 'true' ">
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
  <ContainerImageTags>github-$(GITHUB_RUN_NUMBER);latest;$(VersionPrefix)</ContainerImageTags>
  <ContainerVendor>$(GITHUB_REPOSITORY_OWNER)</ContainerVendor>
  <ContainerVersion>$(GITHUB_SHA)</ContainerVersion>
</PropertyGroup>

<PropertyGroup>
  <!-- Remove parallel builds, to avoid race conditions -->
  <ContainerPublishInParallel>false</ContainerPublishInParallel>
</PropertyGroup>

<ItemGroup Condition=" '$(CI)' == 'true' ">
  <ContainerLabel Include="com.example.changelog" Value="$(GITHUB_SERVER_URL)/$(GITHUB_REPOSITORY)/commit/$(GITHUB_SHA)" />
</ItemGroup>
```

Takeaway: `ContainerImageTags` allows multi-tagging, `ContainerPublishInParallel=false` avoids races, and `ContainerLabel` items bake CI metadata into the image.

## Tarball Output for No-Daemon Builds

When the build host has no daemon, write a tarball and load it elsewhere:

```bash
dotnet publish /t:PublishContainer -c Release \
  -p:ContainerArchiveOutputPath=./images/my-service.tar.gz

docker load -i ./images/my-service.tar.gz   # or podman load -i
```
