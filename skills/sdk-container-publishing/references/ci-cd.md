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
- **`ContainerImageTag` is explicit.** Without it the image lands on `latest` and a release can never be pulled by version.
- **A daemon step is required** because the default output mode pushes to the local Docker daemon. If you do not want a daemon, use `ContainerArchiveOutputPath` and push the tarball yourself.

## Registry Auth

The SDK reads Docker / Podman config to decide HTTP vs HTTPS and to authenticate. In CI, log into the registry first:

```bash
docker login <registry> -u $USER -p ${{ secrets.REGISTRY_TOKEN }}
```

For insecure (HTTP) registries, set `DOTNET_CONTAINER_INSECURE_REGISTRIES` to a comma-separated list of domains.

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
