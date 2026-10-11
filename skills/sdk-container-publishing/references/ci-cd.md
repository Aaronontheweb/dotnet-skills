---
name: sdk-container-publishing-ci-cd
description: Patterns for publishing SDK-built container images in CI / CD, including tag-driven release workflows, registry auth, and the explicit-tag footgun.
---

# CI / CD Container Publishing

## Tag-Driven Release Workflow

Publish images off a git tag. Tag the workflow with the release name, not `latest`, because since .NET 8 the SDK defaults the image tag to `latest` when you do not set one.

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

      - name: Build and push
        run: |
          dotnet publish src/MyService/MyService.csproj \
            -p:VersionPrefix=${{ github.ref_name }} \
            -p:ContainerRegistry=docker.example.internal \
            -c Release /t:PublishContainer
```

Three things to keep in mind:
- **Set one tag property, never both.** `ContainerImageTag` is the single-tag form and `ContainerImageTags` is the semicolon-delimited list. The SDK rejects both together with `CONTAINER2008`. The command above relies on a project that already sets `ContainerImageTags=$(VersionPrefix);latest`; `-p:VersionPrefix` feeds that list.
- **No daemon is required for a registry push.** With `ContainerRegistry` set, the SDK pushes directly to the registry without a container runtime. The default local-daemon output is the only mode that needs a daemon.
- **`VersionPrefix` must be set before the project body is evaluated** (command line, `Directory.Build.props`, or earlier in the file). Without it, `ContainerImageTags=$(VersionPrefix);latest` resolves to `;latest` and the image is tagged `latest` only.

## Registry Auth

The SDK reads Docker / Podman config to decide HTTP vs HTTPS and to authenticate. See the [registry authentication docs](https://aka.ms/dotnet/containers/auth) (which redirects to the sdk-container-builds `RegistryAuthentication.md`).

To authenticate a direct SDK push without `docker login`, set these environment variables:

```bash
export DOTNET_CONTAINER_REGISTRY_UNAME=<username-or-token>
export DOTNET_CONTAINER_REGISTRY_PWORD=<password-or-token>
```

If you authenticate through `docker login` instead, use `--password-stdin` so the token never lands on the command line or in shell history:

```bash
echo "$REGISTRY_TOKEN" | docker login <registry> -u <user> --password-stdin
```

For insecure (HTTP) registries, set `DOTNET_CONTAINER_INSECURE_REGISTRIES` to a comma-separated list of domains.

## Centralizing Settings in Directory.Build.props

When a repo has many container projects, centralize the image settings with CI conditionals. This is the pattern we use for version tags and labels:

```xml
<PropertyGroup Label="ContainerSettings" Condition=" '$(CI)' == 'true' ">
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
  <ContainerImageTags>github-$(GITHUB_RUN_NUMBER);latest;$(VersionPrefix)</ContainerImageTags>
  <ContainerVendor>$(GITHUB_REPOSITORY_OWNER)</ContainerVendor>
  <ContainerVersion>$(GITHUB_SHA)</ContainerVersion>
</PropertyGroup>

<ItemGroup Condition=" '$(CI)' == 'true' ">
  <ContainerLabel Include="com.example.commit" Value="$(GITHUB_SERVER_URL)/$(GITHUB_REPOSITORY)/commit/$(GITHUB_SHA)" />
</ItemGroup>
```

Key points:
- `ContainerImageTags` dual or triple tags: floating `latest`, the version, and a run number for CI.
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
  -p:RuntimeIdentifiers='"linux-x64;linux-arm64"' \
  -p:ContainerRuntimeIdentifiers='"linux-x64;linux-arm64"' \
  /t:PublishContainer
```

The single quotes wrap each semicolon-delimited value so the shell does not split it on `;`. In Bash only the `"` characters need escaping; in PowerShell both `;` and `"` need escaping.

Key points:
- The RIDs must be a subset of `RuntimeIdentifiers`, or the publish fails.
- Multi-arch output is always an OCI image index (Docker format is unavailable for it).
- Multi-arch support requires SDK 8.0.405, 9.0.102, or 9.0.2xx or later.
- If you instead need several *separate* images (for example an API and an MCP server in one release), keep them as distinct publish steps or projects with their own `ContainerRepository` — the SDK builds one image per project per publish invocation.

See [references/property-reference.md](property-reference.md) for the full `ContainerRuntimeIdentifiers` details.
