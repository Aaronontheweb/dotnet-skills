---
name: sdk-container-publishing-property-reference
description: Full catalog of the MSBuild Container* properties used by the .NET SDK container publishing tooling, mapped to Microsoft Learn.
---

# Container MSBuild Property Reference

Grouped by what each property controls. The authoritative source is the [containerize a .NET app reference](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration) on Microsoft Learn.

## Identity and Location

| Property | Default | What it does |
|----------|---------|--------------|
| `ContainerRepository` | project `AssemblyName` | Image repository name. Renamed from `ContainerImageName` in earlier versions. |
| `ContainerRegistry` | (empty - local daemon) | Registry to push to, for example `ghcr.io` or an internal registry. |
| `ContainerImageTag` | `latest` (as of .NET 10) | Single image tag. Set explicitly in CI. |
| `ContainerImageTags` | - | Semicolon-delimited list of tags. Use for `$(VersionPrefix);latest` dual-tagging. |
| `ContainerRuntimeIdentifier` | - | OS / arch for the image when multiple are supported. |
| `ContainerRuntimeIdentifiers` | - | Semicolon-delimited list producing a multi-arch OCI image index. Must be a subset of `RuntimeIdentifiers`. |

## Base Image

| Property | What it does |
|----------|--------------|
| `ContainerBaseImage` | Pin an explicit base image instead of the inferred default. Required for Windows targets. |
| `ContainerFamily` | Base image family. |
| `ContainerRuntimeIdentifiers` | Selects OS / arch variants from the base image manifest list. |

## Image Contents and Metadata

| Property | What it does |
|----------|--------------|
| `ContainerUser` | User the container runs as. |
| `ContainerWorkingDirectory` | Working directory inside the container. |
| `ContainerPort` (item) | Exposed ports: `<ContainerPort Include="8080" Type="tcp" />`. |
| `ContainerLabel` (item) | Image labels: `<ContainerLabel Include="key" Value="value" />`. |
| `ContainerEnvironmentVariable` | Environment variables baked into the image. |
| `ContainerAppCommand` / `ContainerAppCommandArgs` / `ContainerAppCommandInstruction` | Override the entrypoint command. |
| `ContainerEntrypoint` / `ContainerEntrypointArgs` | Override the entrypoint when needed. |

## Output Format

| Property | What it does |
|----------|--------------|
| `ContainerImageFormat` | `Docker` or `OCI`. Multi-arch output is always OCI. |
| `ContainerArchiveOutputPath` | When set, writes a `.tar.gz` tarball instead of pushing to a daemon. No daemon required. |
| `LocalRegistry` | Local output backend: `Docker`, `Podman`, `Wslc`, `MacOSContainer`. Unset lets the SDK pick. |

## OCI Labels and Metadata

| Property | What it does |
|----------|--------------|
| `ContainerGenerateLabels*` | Toggle the generated OCI labels. |
| `ContainerTitle` | Image title label. |
| `ContainerAuthors` | Image author label. |
| `ContainerDescription` | Image description label. |
| `ContainerVendor` | Vendor label. |
| `ContainerVersion` | Version label. |

## Base Image Inference

The SDK picks a base image when `ContainerBaseImage` is unset:

| Scenario | Base image |
|----------|------------|
| Self-contained | `mcr.microsoft.com/dotnet/runtime-deps` |
| ASP.NET Core | `mcr.microsoft.com/dotnet/aspnet` |
| Other | `mcr.microsoft.com/dotnet/runtime` |

Tagged by TFM. Since SDK 8.0.200 the inference is size and security aware:
- musl RIDs auto-select Alpine variants
- `PublishAot=true` selects the chiseled AOT runtime-deps variant
- `InvariantGlobalization=false` selects `-extra` variants

## Windows Targets

Microsoft no longer ships Windows variants in the manifest list for .NET 8+. To target Windows, set an explicit `ContainerBaseImage`, for example `mcr.microsoft.com/dotnet/aspnet:8.0-nanoserver-ltsc2022`.

## Registry Security

- Insecure registries: `DOTNET_CONTAINER_INSECURE_REGISTRIES` env var (comma-separated), SDK 9.0.100+.
- HTTP vs HTTPS: since .NET 8.0.400 the SDK reads standard Docker / Podman config files.
