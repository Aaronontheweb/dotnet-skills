---
name: sdk-container-publishing-self-contained-aot
description: How self-contained and AOT projects affect SDK container publishing - base image inference, chiseled images, and multi-arch output.
---

# Self-Contained and AOT Container Publishing

## Base Image Inference

When `ContainerBaseImage` is unset, the SDK picks a base image from the deployment mode:

| Scenario | Base image |
|----------|------------|
| Self-contained | `mcr.microsoft.com/dotnet/runtime-deps` |
| ASP.NET Core | `mcr.microsoft.com/dotnet/aspnet` |
| Framework-dependent / other | `mcr.microsoft.com/dotnet/runtime` |

Tagged for the TFM. Since SDK 8.0.200 the inference is size and security aware:
- musl RIDs auto-select Alpine variants
- `PublishAot=true` selects the chiseled AOT runtime-deps variant
- `InvariantGlobalization=false` selects `-extra` variants

See [the containerize a .NET app reference](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration).

## Chiseled Images

Chiseled images strip the distro down to only what the runtime needs, shrinking attack surface and image size. The SDK picks the chiseled AOT runtime-deps variant automatically when `PublishAot=true` is set. This pairs well with trimming - see the `aot-trimming` skill in this marketplace.

## Multi-Architecture Images

To build one image spanning multiple platforms, set `ContainerRuntimeIdentifiers` (semicolon-delimited) as a subset of `RuntimeIdentifiers`:

```xml
<PropertyGroup>
  <RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>
  <ContainerRuntimeIdentifiers>linux-x64;linux-arm64</ContainerRuntimeIdentifiers>
</PropertyGroup>
```

The output is an OCI image index combining per-RID images. Supported from SDK 8.0.405, 9.0.102, and 9.0.2xx onward. Multi-arch output is always OCI format.

## Windows Targets

Microsoft no longer includes Windows variants in the manifest list for .NET 8+. To target Windows, set an explicit `ContainerBaseImage`, for example `mcr.microsoft.com/dotnet/aspnet:8.0-nanoserver-ltsc2022`. `ContainerRuntimeIdentifier` selects the OS / arch when the base image supports multiple platforms.
