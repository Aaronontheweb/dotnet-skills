---
name: sdk-container-publishing
description: Publish .NET services as container images with the built-in SDK tooling (dotnet publish /t:PublishContainer, Microsoft.NET.Build.Containers) - no Dockerfile required. Covers the MSBuild property surface, base-image inference, self-contained and AOT implications, and CI/CD publishing.
invocable: false
---

# .NET SDK Container Publishing

## When to Use This Skill

Use this skill when:
- You want a container image for a .NET service and do not want to hand-write a Dockerfile
- You want to know how to tag, name, or expose ports on an SDK-built image without a Dockerfile
- You are wiring container publishing into CI / CD or a release pipeline
- An SDK-built image pushes to the wrong registry, gets the wrong tag, or picks the wrong base image
- You need a tarball of an image for scanning or air-gapped loading

Do not use it when:
- You need a `RUN` step or arbitrary layer customization in the image. The SDK tooling cannot emulate `RUN`; write a Dockerfile instead.

## What This Is

Since .NET 7, `dotnet publish` builds a container image natively. The `Microsoft.NET.Build.Containers` tooling ships with the SDK, so no Dockerfile is required and no Docker install is needed to produce an image. Docker or Podman is only required to run the image locally. This is documented in the [containerize with dotnet publish tutorial](https://learn.microsoft.com/en-us/dotnet/core/containers/sdk-publish).

The quickest path is one command:

```bash
dotnet publish /t:PublishContainer -c Release
```

That compiles the app and emits an image in one step. The image name defaults to the project's `AssemblyName`. Override it with `ContainerRepository` (renamed from `ContainerImageName` in earlier versions - see the [sdk-container-builds customization notes](https://github.com/dotnet/sdk-container-builds/blob/main/docs/ContainerCustomization.md)).

## The Three Output Modes

The tooling writes the image in one of three ways. Pick based on where the image ends up.

| Mode | When to use |
|------|-------------|
| Local daemon (default) | Local dev. Pushes to the running Docker or Podman daemon with no extra config. |
| Tarball | You want a file to scan, transfer, or load later. Set `ContainerArchiveOutputPath` to a `.tar.gz` path, then `docker load -i` or `podman load -i`. Useful in security scanning workflows. |
| Registry push | Shipping. Set `ContainerRegistry` (for example `ghcr.io` or an internal registry) and the image is pushed directly. |

See the [containerize a .NET app reference](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration) for the full property surface.

## Key Facts

- **No Docker required to build.** The SDK creates the image itself; a runtime is only needed to run it. See the [SDK publish tutorial](https://learn.microsoft.com/en-us/dotnet/core/containers/sdk-publish).
- **Image name defaults to `AssemblyName`.** Set `ContainerRepository` to override.
- **Base image is inferred.** Self-contained projects get `mcr.microsoft.com/dotnet/runtime-deps`, ASP.NET Core gets `dotnet/aspnet`, other apps get `dotnet/runtime`, tagged for the TFM. Since SDK 8.0.200 the inference is size and security aware: musl RIDs pick Alpine variants, `PublishAot=true` picks the chiseled AOT runtime-deps variant. See the [base image inference notes](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration).
- **The .NET 10 SDK tags images `latest`, not the version.** If your publish relies on the version tag you must set `ContainerImageTag` explicitly. This is a real footgun in CI - see the [pitfalls section below](#tag-drift).
- **Windows images need an explicit base image.** Microsoft no longer includes Windows variants in the manifest list. To target Windows, set `ContainerBaseImage` to a specific nanoserver tag (for example `mcr.microsoft.com/dotnet/aspnet:8.0-nanoserver-ltsc2022`). See the [Windows note](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration).
- **Multi-architecture images** come from `ContainerRuntimeIdentifiers` (semicolon-delimited, a subset of `RuntimeIdentifiers`). The output is an OCI image index. Supported from SDK 8.0.405, 9.0.102, and 9.0.2xx onward.
- **Insecure registries** are passed via the `DOTNET_CONTAINER_INSECURE_REGISTRIES` env var (comma-separated) starting in SDK 9.0.100. Since .NET 8.0.400 the SDK reads standard Docker / Podman config to decide HTTP vs HTTPS.

## The Minimal Property Set (the pattern we use)

Most of our services only override what they need and let the SDK infer the rest. A minimal csproj looks like this:

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ContainerRepository>my-service</ContainerRepository>
    <ContainerImageTags>$(VersionPrefix);latest</ContainerImageTags>
  </PropertyGroup>

  <ItemGroup>
    <ContainerPort Include="8080" Type="tcp" />
  </ItemGroup>
</Project>
```

Notes:
- No `ContainerRegistry`, no `ContainerBaseImage`, no `ContainerUser`. The SDK defaults these correctly for most ASP.NET services.
- `ContainerPort` items expose ports without a Dockerfile.
- Tags follow semver: the package version plus a floating `latest`.

For the full property catalog, see [references/property-reference.md](references/property-reference.md).

## CI / CD Publishing

In CI, publish against a registry and tag with the release name. The tag-driven pattern we use:

```bash
dotnet publish src/MyService/MyService.csproj \
  -p:VersionPrefix=${{ github.ref_name }} \
  -p:ContainerRegistry=docker.example.internal \
  -p:ContainerImageTag=${{ github.ref_name }} \
  -c Release /t:PublishContainer
```

Note `ContainerImageTag` is set explicitly because the SDK defaults to `latest`, not the version. See [references/ci-cd.md](references/ci-cd.md) for the full workflow and registry auth notes.

If you centralize image settings across a repo, put them in a `Directory.Build.props` with CI conditionals. We do this for version tags, labels, and the `ContainerPublishInParallel=false` anti-race flag. See [references/real-world-examples.md](references/real-world-examples.md).

## Troubleshooting

### Tag drift

**Symptom:** Your pipeline publishes an image but you cannot find the version you expect, only `latest`.

**Cause:** The .NET 10 SDK defaults the image tag to `latest`, not to `$(Version)`. `VersionPrefix` stamps the assembly version but not the image tag.

**Fix:** Pass `ContainerImageTag` explicitly in the publish step.

### Wrong image name or registry

**Symptom:** The image pushes somewhere unexpected.

**Cause:** The SDK derives the repository name from `AssemblyName` and pushes to the local daemon by default.

**Fix:** Set `ContainerRepository` and `ContainerRegistry` explicitly.

### `RUN` unavailable

**Symptom:** You need to run a command inside the image and the SDK will not do it.

**Cause:** The SDK tooling cannot execute `RUN` steps without a Dockerfile.

**Fix:** Use a custom base image via `ContainerBaseImage`, or write a Dockerfile.

### No daemon on the build host

**Symptom:** Publishing fails because no Docker / Podman daemon is reachable.

**Cause:** The default output mode pushes to a local daemon, which must be present.

**Fix:** Set `ContainerArchiveOutputPath` to write a tarball instead. No daemon needed.

For more, see [references/troubleshooting.md](references/troubleshooting.md).

## Self-Contained and AOT

Self-contained projects default to the `runtime-deps` base image. AOT projects get a chiseled AOT runtime-deps variant for smaller, more secure images. See [references/self-contained-and-aot.md](references/self-contained-and-aot.md).

## Verification

Confirm the image built and exists:

```bash
# Image in the local daemon
docker images | grep <repository>

# Tarball produced
ls -la <ContainerArchiveOutputPath>

# Push succeeded (registry mode)
docker pull <ContainerRegistry>/<ContainerRepository>:<tag>
```

## Related Skills

- `dotnet-skills:testcontainers` - running containers in tests
- `dotnet-skills:aot-trimming` - AOT and trimming, relevant to base-image selection
