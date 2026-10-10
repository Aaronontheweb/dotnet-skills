---
name: sdk-container-publishing-ci-cd
description: Patterns for publishing SDK-built container images in CI / CD, including tag-driven release workflows, registry auth, and the explicit-tag footgun.
---

# CI / CD Container Publishing

## Tag-Driven Release Workflow

Publish images off a git tag. Tag the workflow with the release name, not `latest`, because the .NET SDK defaults the image tag to `latest` on .NET 10.

```yaml
name: Publish Container Images

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

      - name: Build and push
        run: |
          dotnet publish src/MyService/MyService.csproj \
            -p:VersionPrefix=${{ github.ref_name }} \
            -p:ContainerRegistry=docker.example.internal \
            -p:ContainerImageTag=${{ github.ref_name }} \
            -c Release /t:PublishContainer
```

Two things to keep in mind:
- **`ContainerImageTag` is explicit.** These `-p:` flags are MSBuild container properties passed on the command line; `ContainerImageTag` is what controls the produced image tag. Without it the image lands on `latest` and a release can never be pulled by version.
- **A daemon step is required** because the default output mode pushes to the local Docker daemon, which depends on the `ContainerArchiveOutputPath` / `ContainerRegistry` properties you set here. If you do not want a daemon, set `ContainerArchiveOutputPath` and push the tarball yourself.

## Registry Auth

The SDK reads Docker / Podman config to decide HTTP vs HTTPS and to authenticate. In CI, log into the registry first:

```bash
docker login <registry> -u $USER -p ${{ secrets.REGISTRY_TOKEN }}
```

For insecure (HTTP) registries, set `DOTNET_CONTAINER_INSECURE_REGISTRIES` to a comma-separated list of domains. See the [registry configuration docs](https://learn.microsoft.com/en-us/dotnet/core/containers/registry-authentication) on Microsoft Learn.

## Centralizing Settings in Directory.Build.props

When a repo has many container projects, centralize the image settings with CI conditionals. This is the pattern we use for version tags, labels, and parallel-build safety:

```xml
<PropertyGroup Label="ContainerSettings" Condition=" '$(CI)' == 'true' ">
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
  <ContainerImageTags>github-$(GITHUB_RUN_NUMBER);latest;$(VersionPrefix)</ContainerImageTags>
  <ContainerVendor>$(GITHUB_REPOSITORY_OWNER)</ContainerVendor>
  <ContainerVersion>$(GITHUB_SHA)</ContainerVersion>
</PropertyGroup>

<PropertyGroup>
  <!-- Remove parallel builds to avoid race conditions -->
  <ContainerPublishInParallel>false</ContainerPublishInParallel>
</PropertyGroup>

<ItemGroup Condition=" '$(CI)' == 'true' ">
  <ContainerLabel Include="com.example.commit" Value="$(GITHUB_SERVER_URL)/$(GITHUB_REPOSITORY)/commit/$(GITHUB_SHA)" />
</ItemGroup>
```

Key points:
- `ContainerImageTags` dual or triple tags: floating `latest`, the version, and a run number for CI.
- `ContainerPublishInParallel=false` avoids race conditions when multiple projects publish in one build.
- `ContainerVendor` / `ContainerVersion` become OCI labels from CI values.

## Tarball Output for Scanning or Air-Gapped Transfer

If the build host has no daemon or you need a portable file, write a tarball and load it elsewhere:

```bash
dotnet publish /t:PublishContainer -c Release \
  -p:ContainerArchiveOutputPath=./images/my-service.tar.gz

# Elsewhere, no daemon needed on the build host:
docker load -i ./images/my-service.tar.gz   # or podman load -i
```

This fits security scanning and air-gapped loading workflows.

## Multi-Architecture and Multi-Image Builds

Building for more than one OS / arch (for example `linux-x64`, `linux-arm64` for Apple Silicon) needs no special CI setup beyond the container properties. Set `ContainerRuntimeIdentifiers` to a semicolon-delimited list of RIDs that is a subset of `RuntimeIdentifiers`, and the SDK emits a single multi-arch OCI image index:

```bash
dotnet publish src/MyService/MyService.csproj \
  -p:RuntimeIdentifiers=linux-x64;linux-arm64 \
  -p:ContainerRuntimeIdentifiers=linux-x64;linux-arm64 \
  /t:PublishContainer
```

Key points:
- The RIDs must be a subset of `RuntimeIdentifiers`, or the publish fails.
- Multi-arch output is always an OCI image index (Docker format is unavailable for it).
- Multi-arch support requires SDK 8.0.405, 9.0.102, or 9.0.2xx or later.
- If you instead need several *separate* images (for example an API and an MCP server in one release), keep them as distinct publish steps or projects with their own `ContainerRepository` — the SDK builds one image per project per publish invocation.

See [references/property-reference.md](property-reference.md) for the full `ContainerRuntimeIdentifiers` details.
