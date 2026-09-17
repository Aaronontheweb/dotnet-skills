---
name: sdk-container-publishing-troubleshooting
description: Common failures when publishing SDK-built container images and how to fix them.
---

# Troubleshooting SDK Container Publishing

## Tag Drift

**Symptom:** Your pipeline publishes an image but you cannot find the version you expect, only `latest`.

**Cause:** The .NET 10 SDK defaults the image tag to `latest`, not to `$(Version)`. `VersionPrefix` stamps the assembly version but not the image tag.

**Fix:** Pass `ContainerImageTag` explicitly in the publish step:

```bash
dotnet publish ... -p:ContainerImageTag=${{ github.ref_name }} /t:PublishContainer
```

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

**Cause:** The default output mode pushes to a local daemon, which must be present.

**Fix:** Set `ContainerArchiveOutputPath` to write a tarball instead. No daemon needed.

## Property Name Confusion

**Symptom:** You used `ContainerImageName` and it does nothing.

**Cause:** `ContainerImageName` was the early name. It was renamed to `ContainerRepository`.

**Fix:** Use `ContainerRepository`. See the [sdk-container-builds customization notes](https://github.com/dotnet/sdk-container-builds/blob/main/docs/ContainerCustomization.md).

## Insecure Registry Rejected

**Symptom:** Pushing to an internal HTTP registry fails.

**Cause:** The SDK defaults to HTTPS.

**Fix:** Set `DOTNET_CONTAINER_INSECURE_REGISTRIES` to a comma-separated list of domains (SDK 9.0.100+), or configure the registry in Docker / Podman config (SDK 8.0.400+ reads it to decide HTTP vs HTTPS).

## Parallel Publish Race

**Symptom:** Multiple projects publishing containers in one build occasionally fail or step on each other.

**Cause:** Concurrent container publishes race on shared state.

**Fix:** Set `ContainerPublishInParallel=false`.
