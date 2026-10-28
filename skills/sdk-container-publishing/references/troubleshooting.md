---
name: sdk-container-publishing-troubleshooting
description: Common failures when publishing SDK-built container images and how to fix them.
---

# Troubleshooting SDK Container Publishing

## Tag Drift

**Symptom:** Your pipeline publishes an image but you cannot find the version you expect, only `latest`.

**Cause:** Since .NET 8, when neither `ContainerImageTag` nor `ContainerImageTags` is set, the SDK tags the image `latest` instead of `$(Version)`. `VersionPrefix` stamps the assembly version but not the image tag.

**Fix:** Set `ContainerImageTag` (single tag) or `ContainerImageTags` (list) explicitly in the publish step. Never set both.

## VersionPrefix Ordering

**Symptom:** Your project sets `<ContainerImageTags>$(VersionPrefix);latest</ContainerImageTags>`, but the image is tagged `latest` only — the version tag is missing.

**Cause:** `$(VersionPrefix)` is still empty when the project body evaluates, so the list becomes `;latest`. The SDK applies its `1.0.0` default in targets imported *after* the project body.

**Fix:** Provide `VersionPrefix` before the project body: on the command line (`-p:VersionPrefix=...`), in `Directory.Build.props`, or earlier in the project file. A plain local publish without any of those tags the image `latest` only.

## Wrong Image Name or Registry

**Symptom:** The image pushes somewhere unexpected.

**Cause:** The SDK derives the repository name from `AssemblyName` and pushes to the local daemon by default.

**Fix:** Set `ContainerRepository` and `ContainerRegistry` explicitly.

## RUN Unavailable

**Symptom:** You need to run a command inside the image and the SDK will not do it.

**Cause:** The SDK tooling cannot execute `RUN` steps without a Dockerfile.

**Fix:** Use a custom base image via `ContainerBaseImage`, or write a Dockerfile.

## No Daemon on the Build Host

**Symptom:** Publishing fails because no Docker / Podman daemon is reachable.

**Cause:** The default output mode pushes to a local daemon, which must be present. A registry push (`ContainerRegistry`) does not need a daemon.

**Fix:** Set `ContainerArchiveOutputPath` to write a tarball instead, or push to a registry. No daemon needed for either.

## Property Name Confusion

**Symptom:** You used `ContainerImageName` and it does nothing.

**Cause:** `ContainerImageName` was the early name. It was renamed to `ContainerRepository`.

**Fix:** Use `ContainerRepository`. See the [sdk-container-builds customization notes](https://github.com/dotnet/sdk-container-builds/blob/main/docs/ContainerCustomization.md).

## Insecure Registry Rejected

**Symptom:** Pushing to an internal HTTP registry fails.

**Cause:** The SDK defaults to HTTPS.

**Fix:** Set `DOTNET_CONTAINER_INSECURE_REGISTRIES` to a comma-separated list of domains (SDK 9.0.100+), or configure the registry in Docker / Podman config (SDK 8.0.400+ reads it to decide HTTP vs HTTPS).

## Multi-RID Publish Race

**Symptom:** A multi-arch publish (`ContainerRuntimeIdentifiers`) with several RIDs occasionally fails or steps on itself.

**Cause:** The SDK publishes the per-RID images in parallel by default, which can race for some project types (for example Blazor WebAssembly).

**Fix:** Set `ContainerPublishInParallel=false`. Note this only serializes the inner per-RID publishes of one multi-RID build; it does not serialize publishes across separate projects.

## Multi-Target Publishing

**Symptom:** You run `dotnet publish /t:PublishContainer` on a project with `<TargetFrameworks>` and it fails before any container work.

**Cause:** The SDK cannot publish containers for multiple target frameworks at once. A project with several TFMs fails with `NETSDK1129` (Publish needs a target framework), and the container targets add their own guard (`CONTAINERS0666`). The SDK does not emit one image per TFM.

**Fix:** Pick a single framework for the publish:

```bash
dotnet publish src/MyService/MyService.csproj \
  -p:TargetFramework=net10.0 \
  /t:PublishContainer
```

One publish builds one image. For multi-arch (not multi-TFM) output you want `ContainerRuntimeIdentifiers`, not multiple TFMs — see [references/ci-cd.md](ci-cd.md).
