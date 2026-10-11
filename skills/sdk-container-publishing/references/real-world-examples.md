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

  <!-- The version tag comes from $(VersionPrefix), which CI passes on the command line. -->
  <ContainerImageTags>$(VersionPrefix);latest</ContainerImageTags>
</PropertyGroup>

<ItemGroup>
  <PackageReference Include="Akka.Hosting" />
</ItemGroup>
```

Takeaways:
- Only set `ContainerRepository` when the assembly name is not the image name you want. Leave everything else to the SDK defaults.
- `ContainerImageTags=$(VersionPrefix);latest` dual-tags the image, but only when `$(VersionPrefix)` is set before the project body (command line or `Directory.Build.props`). Locally, without it, the image is tagged `latest` only.

## Tag-Driven CI Publishing

A release pipeline that publishes on a git tag. The tag list comes from `$(VersionPrefix)` (set on the command line) feeding the `ContainerImageTags` already in the project:

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
      - name: Build and push Api
        run: |
          dotnet publish src/MyService.Api/MyService.Api.csproj \
            -p:VersionPrefix=${{ github.ref_name }} \
            -p:ContainerRegistry=docker.example.internal \
            -c Release /t:PublishContainer
```

Separate deployables (for example an API and an MCP server) each get their own publish step and their own `ContainerRepository`.

## Registries That Need a Daemon

A few registries reject the SDK's direct push (their auth or API differs from what `Microsoft.NET.Build.Containers` speaks). In that case, build to the local daemon, then tag and push the image yourself:

```bash
dotnet publish src/MyService/MyService.csproj \
  -p:VersionPrefix=${{ github.ref_name }} \
  -c Release /t:PublishContainer

docker tag my-service:${{ github.ref_name }} registry.example.com/petabridge/my-service:${{ github.ref_name }}
docker tag my-service:${{ github.ref_name }} registry.example.com/petabridge/my-service:latest
docker push registry.example.com/petabridge/my-service:${{ github.ref_name }}
docker push registry.example.com/petabridge/my-service:latest
```

## Centralized Settings in Directory.Build.props

A monorepo centralizes image settings. The props file keys off `CI` and `AGENT_ID` so the same repo builds correctly in GitHub Actions and on build agents.

The `CI` environment variable is a de-facto convention set to `true` by default on GitHub Actions, Azure DevOps, GitLab CI, CircleCI, and Buildkite (among others). Set `Condition=" '$(CI)' == 'true' "` on the container settings group and those settings only apply on a CI runner, never during a developer's local build — which is why the `AGENT_ID`-style triggers are guarded the same way. If your runner does not define `CI`, pass it explicitly as a build input.

```xml
<PropertyGroup Label="ContainerSettings" Condition=" '$(CI)' == 'true' ">
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
  <ContainerImageTags>github-$(GITHUB_RUN_NUMBER);latest;$(VersionPrefix)</ContainerImageTags>
  <ContainerVendor>$(GITHUB_REPOSITORY_OWNER)</ContainerVendor>
  <ContainerVersion>$(GITHUB_SHA)</ContainerVersion>
</PropertyGroup>

<ItemGroup Condition=" '$(CI)' == 'true' ">
  <ContainerLabel Include="com.example.changelog" Value="$(GITHUB_SERVER_URL)/$(GITHUB_REPOSITORY)/commit/$(GITHUB_SHA)" />
</ItemGroup>
```

Takeaway: `ContainerImageTags` allows multi-tagging (floating `latest`, the version, and a CI run number), and `ContainerLabel` items bake CI metadata into the image. A centralized `ContainerImageTags` list and a CLI `-p:ContainerImageTag` are mutually exclusive — do not pass both.

## Tarball Output for No-Daemon Builds

When the build host has no daemon, write a tarball and load it elsewhere:

```bash
dotnet publish /t:PublishContainer -c Release \
  -p:ContainerArchiveOutputPath=./images/my-service.tar.gz

docker load -i ./images/my-service.tar.gz   # or podman load -i
```
