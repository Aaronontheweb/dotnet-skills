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

## Configuration Model

Create strongly-typed settings for all management options. See the `microsoft-extensions-configuration` skill for validation patterns.

### AkkaManagementOptions

```csharp
using System.Net;

public class AkkaManagementOptions
{
    /// <summary>
    /// The hostname for the management HTTP endpoint.
    /// Used by other nodes to contact this node's management endpoint.
    /// </summary>
    public string HostName { get; set; } = Dns.GetHostName();

    /// <summary>
    /// The port for the management HTTP endpoint.
    /// Standard port is 8558.
    /// </summary>
    public int Port { get; set; } = 8558;
}
```

### ClusterBootstrapOptions

```csharp
public class ClusterBootstrapOptions
{
    /// <summary>
    /// Enable/disable Akka.Management cluster bootstrap.
    /// When disabled, use traditional seed nodes.
    /// </summary>
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// Service name used for discovery.
    /// All nodes in the same cluster must use the same service name.
    /// </summary>
    public string ServiceName { get; set; } = "my-service";

    /// <summary>
    /// Name of the port used for management HTTP endpoint.
    /// Used by Kubernetes discovery to find the correct port.
    /// </summary>
    public string PortName { get; set; } = "management";

    /// <summary>
    /// Minimum number of contact points required to form a cluster.
    /// Should match your minimum replica count.
    /// </summary>
    /// <remarks>
    /// Set to 1 for development, 3+ for production.
    /// </remarks>
    public int RequiredContactPointsNr { get; set; } = 3;

    /// <summary>
    /// Which discovery mechanism to use.
    /// </summary>
    public DiscoveryMethod DiscoveryMethod { get; set; } = DiscoveryMethod.Config;

    /// <summary>
    /// How often to probe discovered contact points.
    /// </summary>
    public TimeSpan ContactPointProbingInterval { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// How often to query the discovery provider.
    /// </summary>
    public TimeSpan BootstrapperDiscoveryPingInterval { get; set; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Time to wait for stable contact points before forming cluster.
    /// Increase for slower environments.
    /// </summary>
    public TimeSpan StableMargin { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>
    /// Whether to contact all discovered nodes or just the required number.
    /// Set to true for better cluster formation reliability.
    /// </summary>
    public bool ContactWithAllContactPoints { get; set; } = true;

    /// <summary>
    /// Filter contact points by management port.
    /// Set to true for Kubernetes (fixed ports), false for Aspire (dynamic ports).
    /// </summary>
    public bool FilterOnFallbackPort { get; set; } = true;

    // Discovery-specific options
    public string[]? ConfigServiceEndpoints { get; set; }
    public AzureDiscoveryOptions? AzureDiscoveryOptions { get; set; }
    public KubernetesDiscoveryOptions? KubernetesDiscoveryOptions { get; set; }
}

public enum DiscoveryMethod
{
    /// <summary>
    /// Static configuration - endpoints defined in HOCON/appsettings.
    /// Good for development and fixed infrastructure.
    /// </summary>
    Config,

    /// <summary>
    /// Kubernetes API discovery - queries K8s API for pod endpoints.
    /// Best for Kubernetes deployments.
    /// </summary>
    Kubernetes,

    /// <summary>
    /// Azure Table Storage - nodes register themselves in a shared table.
    /// Good for Azure deployments and Aspire local development.
    /// </summary>
    AzureTableStorage
}
```

### Discovery-Specific Options

```csharp
public class AzureDiscoveryOptions
{
    public string? ConnectionString { get; set; }
    public string TableName { get; set; } = "AkkaDiscovery";
}

public class KubernetesDiscoveryOptions
{
    /// <summary>
    /// Kubernetes namespace to search for pods.
    /// If null, uses the namespace of the current pod.
    /// </summary>
    public string? PodNamespace { get; set; }

    /// <summary>
    /// Label selector to filter pods (e.g., "app=my-service").
    /// </summary>
    public string? PodLabelSelector { get; set; }

    /// <summary>
    /// Name of the port in the pod spec for management endpoint.
    /// </summary>
    public string PodPortName { get; set; } = "management";
}
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
        // Bind and validate settings (see microsoft-extensions-configuration skill)
        services.AddOptions<AkkaSettings>()
            .BindConfiguration("AkkaSettings")
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddSingleton<IValidateOptions<AkkaSettings>, AkkaSettingsValidator>();

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
        // LocalTest mode = no networking
        if (settings.ExecutionMode == AkkaExecutionMode.LocalTest)
            return;

        // Configure remoting
        builder.WithRemoting(settings.RemoteOptions);

        if (settings.ClusterBootstrapOptions.Enabled)
        {
            // Dynamic cluster formation with Akka.Management
            ConfigureAkkaManagement(builder, settings, configuration);
        }
        else
        {
            // Traditional seed-node clustering
            builder.WithClustering(settings.ClusterOptions);
        }
    }

    private static void ConfigureHealthChecks(AkkaConfigurationBuilder builder)
    {
        builder
            .WithActorSystemLivenessCheck()
            .WithAkkaClusterReadinessCheck();
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
        // Configure clustering (without seed nodes)
        .WithClustering(settings.ClusterOptions)

        // Configure Akka.Management HTTP endpoint
        .WithAkkaManagement(setup =>
        {
            setup.Http.HostName = mgmtOptions.HostName;
            setup.Http.Port = mgmtOptions.Port;
            setup.Http.BindHostName = "0.0.0.0";  // Listen on all interfaces
            setup.Http.BindPort = mgmtOptions.Port;
        })

        // Configure Cluster Bootstrap
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

---

## Discovery Providers

### 1. Config Discovery (Development/Fixed Infrastructure)

Use when endpoints are known ahead of time:

```csharp
private static void ConfigureConfigDiscovery(
    AkkaConfigurationBuilder builder,
    ClusterBootstrapOptions options)
{
    if (options.ConfigServiceEndpoints == null || options.ConfigServiceEndpoints.Length == 0)
        throw new InvalidOperationException("ConfigServiceEndpoints required for Config discovery");

    var endpoints = string.Join(", ", options.ConfigServiceEndpoints.Select(ep => $"\"{ep}\""));

    var hocon = $@"
        akka.discovery {{
            method = config
            config {{
                services {{
                    {options.ServiceName} {{
                        endpoints = [{endpoints}]
                    }}
                }}
            }}
        }}";

    builder.AddHocon(hocon, HoconAddMode.Prepend);
}
```

**appsettings.json:**
```json
{
  "AkkaSettings": {
    "ClusterBootstrapOptions": {
      "Enabled": true,
      "DiscoveryMethod": "Config",
      "ServiceName": "my-service",
      "ConfigServiceEndpoints": [
        "node1.local:8558",
        "node2.local:8558",
        "node3.local:8558"
      ]
    }
  }
}
```

### 2. Kubernetes Discovery (Production K8s)

Queries the Kubernetes API for pod endpoints:

```csharp
private static void ConfigureKubernetesDiscovery(
    AkkaConfigurationBuilder builder,
    KubernetesDiscoveryOptions? options)
{
    if (options != null)
    {
        builder.WithKubernetesDiscovery(k8sOptions =>
        {
            if (!string.IsNullOrEmpty(options.PodNamespace))
                k8sOptions.PodNamespace = options.PodNamespace;

            if (!string.IsNullOrEmpty(options.PodLabelSelector))
                k8sOptions.PodLabelSelector = options.PodLabelSelector;
        });
    }
    else
    {
        // Use defaults - auto-detect namespace and use all pods
        builder.WithKubernetesDiscovery();
    }
}
```

**Kubernetes Deployment:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-akka-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-akka-service
  template:
    metadata:
      labels:
        app: my-akka-service
    spec:
      containers:
      - name: app
        image: my-app:latest
        ports:
        - name: http
          containerPort: 8080
        - name: remote
          containerPort: 8081
        - name: management     # Must match PortName in config
          containerPort: 8558
        env:
        - name: AkkaSettings__ClusterBootstrapOptions__Enabled
          value: "true"
        - name: AkkaSettings__ClusterBootstrapOptions__DiscoveryMethod
          value: "Kubernetes"
        - name: AkkaSettings__ClusterBootstrapOptions__ServiceName
          value: "my-akka-service"
        - name: AkkaSettings__RemoteOptions__PublicHostName
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
---
apiVersion: v1
kind: Service
metadata:
  name: my-akka-service
spec:
  clusterIP: None  # Headless service for direct pod discovery
  selector:
    app: my-akka-service
  ports:
  - name: management
    port: 8558
```

**Required RBAC:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: akka-discovery
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: akka-discovery
subjects:
- kind: ServiceAccount
  name: default
roleRef:
  kind: Role
  name: akka-discovery
  apiGroup: rbac.authorization.k8s.io
```

### 3. Azure Table Storage Discovery (Azure/Aspire)

Nodes register themselves in a shared Azure Table:

```csharp
private static void ConfigureAzureDiscovery(
    AkkaConfigurationBuilder builder,
    ClusterBootstrapOptions bootstrapOptions,
    AkkaManagementOptions mgmtOptions,
    IConfiguration configuration)
{
    var connectionString = configuration.GetConnectionString("AkkaManagementAzure");
    if (string.IsNullOrEmpty(connectionString))
        throw new InvalidOperationException("AkkaManagementAzure connection string required");

    builder.WithAzureDiscovery(options =>
    {
        options.ServiceName = bootstrapOptions.ServiceName;
        options.ConnectionString = connectionString;
        options.HostName = mgmtOptions.HostName;
        options.Port = mgmtOptions.Port;
    });
}
```

**appsettings.json:**
```json
{
  "ConnectionStrings": {
    "AkkaManagementAzure": "DefaultEndpointsProtocol=https;AccountName=...;AccountKey=..."
  },
  "AkkaSettings": {
    "ClusterBootstrapOptions": {
      "Enabled": true,
      "DiscoveryMethod": "AzureTableStorage",
      "ServiceName": "my-service",
      "AzureDiscoveryOptions": {
        "TableName": "AkkaDiscovery"
      }
    }
  }
}
```

---

## Complete Discovery Configuration

```csharp
private static void ConfigureDiscovery(
    AkkaConfigurationBuilder builder,
    AkkaSettings settings,
    IConfiguration configuration)
{
    var bootstrapOptions = settings.ClusterBootstrapOptions;
    var mgmtOptions = settings.AkkaManagementOptions;

    switch (bootstrapOptions.DiscoveryMethod)
    {
        case DiscoveryMethod.Config:
            ConfigureConfigDiscovery(builder, bootstrapOptions);
            break;

        case DiscoveryMethod.Kubernetes:
            ConfigureKubernetesDiscovery(builder, bootstrapOptions.KubernetesDiscoveryOptions);
            break;

        case DiscoveryMethod.AzureTableStorage:
            ConfigureAzureDiscovery(builder, bootstrapOptions, mgmtOptions, configuration);
            break;

        default:
            throw new ArgumentOutOfRangeException(
                nameof(bootstrapOptions.DiscoveryMethod),
                $"Unknown discovery method: {bootstrapOptions.DiscoveryMethod}");
    }
}
```

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

**Debug:**
```csharp
// Enable verbose logging
"AkkaSettings": {
  "LogConfigOnStart": true
}
```

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
