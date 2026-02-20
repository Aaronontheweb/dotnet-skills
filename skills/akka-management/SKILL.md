---
name: akka-net-management
description: Akka.Management for cluster bootstrapping, service discovery (Kubernetes, Azure, Config), health checks, and dynamic cluster formation without static seed nodes.
invocable: false
---

# Akka.NET Management and Service Discovery

## When to Use This Skill

Use this skill when:
- Deploying Akka.NET clusters to Kubernetes or cloud environments
- Replacing static seed nodes with dynamic service discovery
- Configuring cluster bootstrap for auto-formation
- Setting up health endpoints for load balancers
- Integrating with Azure Table Storage, Kubernetes API, or config-based discovery

## Reference Files

- [discovery-providers.md](discovery-providers.md): Config, Kubernetes, and Azure discovery setup with full code and deployment YAML
- [configuration-reference.md](configuration-reference.md): Strongly-typed configuration model classes

## Overview

**Akka.Management** provides HTTP endpoints for cluster management and integrates with **Akka.Cluster.Bootstrap** to enable dynamic cluster formation using service discovery instead of static seed nodes.

### Why Use Akka.Management?

| Approach | Pros | Cons |
|----------|------|------|
| Static Seed Nodes | Simple, no dependencies | Doesn't scale, requires known IPs |
| Akka.Management | Dynamic discovery, scales to N nodes | More configuration, external dependencies |

**Use static seed nodes** for: Development, single-node deployments, fixed infrastructure.

**Use Akka.Management** for: Kubernetes, auto-scaling groups, dynamic environments, production clusters.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cluster Bootstrap                         │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  Node 1     │    │  Node 2     │    │  Node 3     │     │
│  │             │    │             │    │             │     │
│  │ Management  │◄──►│ Management  │◄──►│ Management  │     │
│  │ HTTP :8558  │    │ HTTP :8558  │    │ HTTP :8558  │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            │                                │
│                    ┌───────▼───────┐                        │
│                    │   Discovery   │                        │
│                    │   Provider    │                        │
│                    └───────────────┘                        │
│                            │                                │
└────────────────────────────┼────────────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
        ┌─────▼─────┐ ┌──────▼─────┐ ┌─────▼──────┐
        │ Kubernetes│ │   Azure    │ │   Config   │
        │    API    │ │   Tables   │ │   (HOCON)  │
        └───────────┘ └────────────┘ └────────────┘
```

---

## Required NuGet Packages

```xml
<ItemGroup>
  <!-- Core management -->
  <PackageReference Include="Akka.Management" />
  <PackageReference Include="Akka.Management.Cluster.Bootstrap" />

  <!-- Choose ONE discovery provider -->
  <PackageReference Include="Akka.Discovery.KubernetesApi" />    <!-- For Kubernetes -->
  <PackageReference Include="Akka.Discovery.Azure" />            <!-- For Azure -->
  <PackageReference Include="Akka.Discovery.Config.Hosting" />   <!-- For static config -->
</ItemGroup>
```

---

## Akka.Hosting Configuration

### Basic Setup with Mode Selection

```csharp
public static class AkkaConfiguration
{
    public static IServiceCollection ConfigureAkka(
        this IServiceCollection services,
        Action<AkkaConfigurationBuilder, IServiceProvider>? additionalConfig = null)
    {
        services.AddOptions<AkkaSettings>()
            .BindConfiguration("AkkaSettings")
            .ValidateDataAnnotations()
            .ValidateOnStart();

        return services.AddAkka("MySystem", (builder, sp) =>
        {
            var settings = sp.GetRequiredService<IOptions<AkkaSettings>>().Value;
            var configuration = sp.GetRequiredService<IConfiguration>();

            ConfigureNetwork(builder, settings, configuration);
            ConfigureHealthChecks(builder);

            additionalConfig?.Invoke(builder, sp);
        });
    }

    private static void ConfigureNetwork(
        AkkaConfigurationBuilder builder,
        AkkaSettings settings,
        IConfiguration configuration)
    {
        if (settings.ExecutionMode == AkkaExecutionMode.LocalTest)
            return;

        builder.WithRemoting(settings.RemoteOptions);

        if (settings.ClusterBootstrapOptions.Enabled)
            ConfigureAkkaManagement(builder, settings, configuration);
        else
            builder.WithClustering(settings.ClusterOptions);
    }
}
```

### Akka.Management Configuration

```csharp
private static void ConfigureAkkaManagement(
    AkkaConfigurationBuilder builder,
    AkkaSettings settings,
    IConfiguration configuration)
{
    var mgmtOptions = settings.AkkaManagementOptions;
    var bootstrapOptions = settings.ClusterBootstrapOptions;

    // IMPORTANT: Clear seed nodes when using Akka.Management
    settings.ClusterOptions.SeedNodes = [];

    builder
        .WithClustering(settings.ClusterOptions)
        .WithAkkaManagement(setup =>
        {
            setup.Http.HostName = mgmtOptions.HostName;
            setup.Http.Port = mgmtOptions.Port;
            setup.Http.BindHostName = "0.0.0.0";
            setup.Http.BindPort = mgmtOptions.Port;
        })
        .WithClusterBootstrap(options =>
        {
            options.ContactPointDiscovery.ServiceName = bootstrapOptions.ServiceName;
            options.ContactPointDiscovery.PortName = bootstrapOptions.PortName;
            options.ContactPointDiscovery.RequiredContactPointsNr = bootstrapOptions.RequiredContactPointsNr;
            options.ContactPointDiscovery.Interval = bootstrapOptions.ContactPointProbingInterval;
            options.ContactPointDiscovery.StableMargin = bootstrapOptions.StableMargin;
            options.ContactPointDiscovery.ContactWithAllContactPoints = bootstrapOptions.ContactWithAllContactPoints;
            options.ContactPoint.FilterOnFallbackPort = bootstrapOptions.FilterOnFallbackPort;
            options.ContactPoint.ProbeInterval = bootstrapOptions.BootstrapperDiscoveryPingInterval;
        });

    // Configure the discovery provider
    ConfigureDiscovery(builder, settings, configuration);
}
```

See [discovery-providers.md](discovery-providers.md) for complete Config, Kubernetes, and Azure discovery setup code.

See [configuration-reference.md](configuration-reference.md) for the full strongly-typed configuration model classes.

---

## Health Endpoints

Akka.Management exposes health endpoints for load balancers and orchestrators:

| Endpoint | Purpose | Returns 200 When |
|----------|---------|------------------|
| `/alive` | Liveness | ActorSystem is running |
| `/ready` | Readiness | Cluster member is Up |
| `/cluster/members` | Debug | Returns cluster membership |

### ASP.NET Core Health Check Integration

```csharp
// Register Akka health checks
builder.Services.AddHealthChecks();

// In Akka configuration
builder
    .WithActorSystemLivenessCheck()     // Adds "akka-liveness" health check
    .WithAkkaClusterReadinessCheck();   // Adds "akka-cluster-readiness" health check

// Map endpoints
app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("liveness")
});

app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("readiness")
});
```

---

## Troubleshooting

### Cluster Won't Form

**Symptoms:** Nodes stay as separate single-node clusters.

**Checklist:**
1. All nodes use same `ServiceName`
2. `RequiredContactPointsNr` matches actual replica count
3. Discovery provider is configured correctly
4. Network allows traffic on management port (8558)
5. For Kubernetes: RBAC permissions are set

### Split Brain

**Symptoms:** Multiple clusters form instead of one.

**Solutions:**
1. Set `ContactWithAllContactPoints = true`
2. Increase `StableMargin` for slower environments
3. For Aspire: Set `FilterOnFallbackPort = false` (dynamic ports)
4. For Kubernetes: Set `FilterOnFallbackPort = true` (fixed ports)

### Azure Discovery Issues

**Symptoms:** Nodes can't find each other via Azure Tables.

**Checklist:**
1. Connection string is valid
2. Storage account allows table operations
3. All nodes use same `ServiceName`
4. Firewall allows access to Azure Storage

---

## Aspire Integration

For detailed Aspire-specific patterns, see the `akka-net-aspire-configuration` skill.

Quick reference for Aspire:

```csharp
// In AppHost
appBuilder
    .WithEndpoint(name: "remote", protocol: ProtocolType.Tcp,
        env: "AkkaSettings__RemoteOptions__Port")
    .WithEndpoint(name: "management", protocol: ProtocolType.Tcp,
        env: "AkkaSettings__AkkaManagementOptions__Port")
    .WithEnvironment("AkkaSettings__ClusterBootstrapOptions__Enabled", "true")
    .WithEnvironment("AkkaSettings__ClusterBootstrapOptions__DiscoveryMethod", "AzureTableStorage")
    .WithEnvironment("AkkaSettings__ClusterBootstrapOptions__FilterOnFallbackPort", "false");
```

---

## Summary: When to Use What

| Scenario | Discovery Method | FilterOnFallbackPort |
|----------|------------------|---------------------|
| Local development (single node) | None (use seed nodes) | N/A |
| Aspire multi-node | AzureTableStorage | `false` |
| Kubernetes | Kubernetes | `true` |
| Azure VMs/VMSS | AzureTableStorage | `true` |
| Fixed infrastructure | Config | `true` |
| AWS ECS/EC2 | AWS discovery plugins | `true` |
