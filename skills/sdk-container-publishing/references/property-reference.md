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
| `ContainerImageTag` | `latest` (since .NET 8, when neither tag property is set) | Single image tag. Set explicitly in CI. |
| `ContainerImageTags` | - | Semicolon-delimited list of tags. Use for `$(VersionPrefix);latest` dual-tagging. |
| `ContainerRuntimeIdentifier` | - | OS / arch for the image when multiple are supported. |
| `ContainerRuntimeIdentifiers` | - | Semicolon-delimited list producing a multi-arch OCI image index. Must be a subset of `RuntimeIdentifiers`. |

`ContainerImageTag` and `ContainerImageTags` are mutually exclusive — the SDK rejects a publish that sets both (`CONTAINER2008`). Pick one.

## Base Image

| Property | What it does |
|----------|--------------|
| `ContainerBaseImage` | Pin an explicit base image instead of the inferred default. Required for Windows containers, because Microsoft stopped shipping Windows variants in the manifest list for .NET 8+. See the [Windows container note](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration). |
| `ContainerFamily` | Base image family. |

## Image Contents and Metadata

| Property | What it does |
|----------|--------------|
| `ContainerUser` | User the container runs as. |
| `ContainerWorkingDirectory` | Working directory inside the container. |
| `ContainerPort` (item) | Exposed ports: `<ContainerPort Include="8080" Type="tcp" />`. |
| `ContainerLabel` (item) | Image labels: `<ContainerLabel Include="key" Value="value" />`. |
| `ContainerEnvironmentVariable` | Environment variables baked into the image. |
| `ContainerAppCommand` / `ContainerAppCommandArgs` / `ContainerAppCommandInstruction` | Override the entrypoint command and its instruction (`DefaultArgs`, `Entrypoint`, `None`). |
| `ContainerDefaultArgs` (item) | Default arguments for the app command: `<ContainerDefaultArgs Include="database" />`. |
| `ContainerEntrypoint` / `ContainerEntrypointArgs` | **Deprecated since .NET 8.** Use `ContainerAppCommand` with `ContainerAppCommandInstruction` instead. |

## Output Format

| Property | What it does |
|----------|--------------|
| `ContainerImageFormat` | `Docker` or `OCI`. Multi-arch output is always OCI. |
| `ContainerArchiveOutputPath` | When set, writes a `.tar.gz` tarball instead of pushing to a daemon. No daemon required. |
| `ContainerPublishInParallel` | Parallelism for the per-RID inner publishes of a single multi-RID publish (`ContainerRuntimeIdentifiers`). Default `true`; set `false` to serialize those inner builds. It does **not** serialize publishes across separate projects. |
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

The SDK picks a base image when `ContainerBaseImage` is unset. See the [base image inference docs](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration):

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
- Direct-push auth without `docker login`: `DOTNET_CONTAINER_REGISTRY_UNAME` / `DOTNET_CONTAINER_REGISTRY_PWORD`. See the [registry authentication docs](https://aka.ms/dotnet/containers/auth).
