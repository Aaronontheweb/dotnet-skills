---
name: akka-net-aspire-configuration
description: Configure Akka.NET with .NET Aspire for local development and production deployments. Covers actor system setup, clustering, persistence, Akka.Management integration, and Aspire orchestration patterns.
invocable: false
---

# Configuring Akka.NET with .NET Aspire

## When to Use This Skill

Use this skill when:
- Setting up a new Akka.NET project with .NET Aspire orchestration
- Configuring Akka.Cluster with cluster bootstrapping and discovery
- Integrating Akka.Persistence with SQL Server
- Setting up Akka.Management for cluster management
- Configuring multi-replica actor systems in local development
- Deploying Akka.NET applications to Kubernetes with Aspire

## Related Skills

- **`akka-net-management`** - Deep dive into Akka.Management, Cluster Bootstrap, and discovery providers (Kubernetes, Azure, Config)
- **`microsoft-extensions-configuration`** - IValidateOptions patterns for configuration validation
- **`akka-net-best-practices`** - Cluster/local mode abstractions for testable actor systems
- **`aspire-integration-testing`** - Testing Aspire applications with real infrastructure

## Core Principles

1. **Configuration via Microsoft.Extensions.Configuration** - Use strongly-typed settings classes bound from appsettings.json (see `microsoft-extensions-configuration` skill)
2. **Akka.Hosting for DI Integration** - Use the Akka.Hosting library for seamless ASP.NET Core integration
3. **Aspire for Orchestration** - Let Aspire manage service dependencies, networking, and environment configuration
4. **Health Checks** - Always configure health checks for clustering, persistence, and readiness
5. **Separate Concerns** - Keep actor definitions, configuration, and Aspire orchestration in separate layers
6. **Validate Configuration at Startup** - Use `IValidateOptions<T>` and `.ValidateOnStart()` to fail fast on misconfiguration

## Project Structure

```
YourSolution/
├── src/
│   ├── YourApp.Actors/              # Actor definitions and business logic
│   │   ├── YourActor.cs
│   │   └── YourApp.Actors.csproj
│   ├── YourApp/                     # ASP.NET Core web application
│   │   ├── Config/
│   │   │   ├── AkkaConfiguration.cs  # Akka setup extension methods
│   │   │   └── AkkaSettings.cs       # Configuration model
│   │   ├── Program.cs
│   │   ├── appsettings.json
│   │   └── YourApp.csproj
│   └── YourApp.AppHost/             # Aspire orchestration
│       ├── Program.cs
│       ├── AkkaManagementExtensions.cs
│       └── YourApp.AppHost.csproj
```

## Required NuGet Packages

### For Actor Project (YourApp.Actors.csproj)
```xml
<ItemGroup>
  <PackageReference Include="Akka.Cluster.Hosting" />
  <PackageReference Include="Akka.Streams" />
</ItemGroup>
```

### For Web Application (YourApp.csproj)
```xml
<ItemGroup>
  <PackageReference Include="Akka.Hosting" />
  <PackageReference Include="Akka.Cluster.Hosting" />
  <PackageReference Include="Akka.Persistence.Sql.Hosting" />
  <PackageReference Include="Akka.Management" />
  <PackageReference Include="Akka.Management.Cluster.Bootstrap" />
  <PackageReference Include="Akka.Discovery.KubernetesApi" />
  <PackageReference Include="Akka.Discovery.Azure" />
  <PackageReference Include="Akka.Discovery.Config.Hosting" />
  <PackageReference Include="Petabridge.Cmd.Host" />
  <PackageReference Include="Petabridge.Cmd.Cluster" />
</ItemGroup>
```

### For AppHost (YourApp.AppHost.csproj)
```xml
<Sdk Name="Aspire.AppHost.Sdk" Version="$(AspireVersion)" />

<ItemGroup>
  <PackageReference Include="Aspire.Hosting.AppHost" />
  <PackageReference Include="Aspire.Hosting.Azure.Storage" />
  <PackageReference Include="Aspire.Hosting.SqlServer" />
</ItemGroup>
```

## Configuration Model (AkkaSettings.cs)

Create a strongly-typed configuration class:

```csharp
using System.Net;
using System.Security.Cryptography.X509Certificates;
using Akka.Cluster.Hosting;
using Akka.Remote.Hosting;
using Petabridge.Cmd.Host;

namespace YourApp.Config;

public class AkkaSettings
{
    public string ActorSystemName { get; set; } = "YourSystem";

    public bool LogConfigOnStart { get; set; } = false;

    public RemoteOptions RemoteOptions { get; set; } = new()
    {
        PublicHostName = Dns.GetHostName(),
        HostName = "0.0.0.0",
        Port = 8081
    };

    public ClusterOptions ClusterOptions { get; set; } = new()
    {
        SeedNodes = [$"akka.tcp://YourSystem@{Dns.GetHostName()}:8081"],
        Roles = ["your-role"]
    };

    public ShardOptions ShardOptions { get; set; } = new();

    public AkkaManagementOptions? AkkaManagementOptions { get; set; }

    public PetabridgeCmdOptions PbmOptions { get; set; } = new()
    {
        Host = "0.0.0.0",
        Port = 9110
    };

    public TlsSettings? TlsSettings { get; set; }
}

public class TlsSettings
{
    public bool Enabled { get; set; } = false;
    public string? CertificatePath { get; set; }
    public string? CertificatePassword { get; set; }
    public bool ValidateCertificates { get; set; } = true;

    public X509Certificate2? LoadCertificate()
    {
        if (string.IsNullOrWhiteSpace(CertificatePath))
            return null;

        if (!File.Exists(CertificatePath))
            throw new FileNotFoundException($"Certificate file not found at: {CertificatePath}");

        return !string.IsNullOrWhiteSpace(CertificatePassword)
            ? X509CertificateLoader.LoadPkcs12FromFile(CertificatePath, CertificatePassword)
            : X509CertificateLoader.LoadCertificateFromFile(CertificatePath);
    }
}

public class AkkaManagementOptions
{
    public bool Enabled { get; set; }
    public string? Hostname { get; set; }
    public int Port { get; set; } = 8558;
    public string ServiceName { get; set; } = "your-service";
    public string PortName { get; set; } = "management";
    public int RequiredContactPointsNr { get; set; } = 1;
    public bool FilterOnFallbackPort { get; set; } = true;
    public DiscoveryMethod DiscoveryMethod { get; set; } = DiscoveryMethod.Config;
}

public enum DiscoveryMethod
{
    Config,
    Kubernetes,
    AzureTableStorage,
    AwsEcsTagBased,
    AwsEc2TagBased
}
```

## Akka Configuration Extension Methods (AkkaConfiguration.cs)

```csharp
using Akka.Cluster.Hosting;
using Akka.Discovery.Azure;
using Akka.Discovery.Config.Hosting;
using Akka.Discovery.KubernetesApi;
using Akka.Hosting;
using Akka.Management;
using Akka.Management.Cluster.Bootstrap;
using Akka.Persistence.Sql.Config;
using Akka.Persistence.Sql.Hosting;
using Akka.Remote.Hosting;
using LinqToDB;

namespace YourApp.Config;

public static class AkkaConfiguration
{
    public static IServiceCollection ConfigureAkka(
        this IServiceCollection services,
        IConfiguration configuration,
        Action<AkkaConfigurationBuilder, IServiceProvider> additionalConfig)
    {
        var akkaSettings = BindAkkaSettings(services, configuration);

        var connectionString = configuration.GetConnectionString("DefaultConnection");
        if (connectionString is null)
            throw new Exception("DefaultConnection ConnectionString is missing");

        const string roleName = "your-role";

        services.AddAkka(akkaSettings.ActorSystemName, (builder, provider) =>
        {
            builder.ConfigureNetwork(provider)
                .WithAkkaClusterReadinessCheck()
                .WithActorSystemLivenessCheck()
                .WithSqlPersistence(
                    connectionString: connectionString,
                    providerName: ProviderName.SqlServer2022,
                    databaseMapping: DatabaseMapping.SqlServer,
                    tagStorageMode: TagMode.TagTable,
                    deleteCompatibilityMode: true,
                    useWriterUuidColumn: true,
                    autoInitialize: true,
                    journalBuilder: journalBuilder =>
                    {
                        journalBuilder.WithHealthCheck(name: "Akka.Persistence.Sql.Journal[default]");
                    },
                    snapshotBuilder: snapshotBuilder =>
                    {
                        snapshotBuilder.WithHealthCheck(name: "Akka.Persistence.Sql.SnapshotStore[default]");
                    });

            // Add your actors here
            // Example: builder.WithActors((system, registry) => { ... });

            additionalConfig(builder, provider);
        });

        return services;
    }

    public static AkkaSettings BindAkkaSettings(IServiceCollection services, IConfiguration configuration)
    {
        var akkaSettings = new AkkaSettings();
        configuration.GetSection(nameof(AkkaSettings)).Bind(akkaSettings);
        services.AddSingleton(akkaSettings);
        return akkaSettings;
    }

    public static AkkaConfigurationBuilder ConfigureNetwork(
        this AkkaConfigurationBuilder builder,
        IServiceProvider serviceProvider)
    {
        var settings = serviceProvider.GetRequiredService<AkkaSettings>();
        var configuration = serviceProvider.GetRequiredService<IConfiguration>();

        // Apply TLS configuration if enabled
        if (settings.TlsSettings is { Enabled: true })
        {
            ConfigureRemoteOptionsWithTls(settings);
        }

        builder.WithRemoting(settings.RemoteOptions);

        if (settings.AkkaManagementOptions is { Enabled: true })
        {
            // Clear seed nodes when using Akka.Management
            var clusterOptions = settings.ClusterOptions;
            clusterOptions.SeedNodes = [];

            builder
                .WithClustering(clusterOptions)
                .WithAkkaManagement(setup =>
                {
                    setup.Http.HostName = settings.AkkaManagementOptions.Hostname?.ToLower();
                    setup.Http.Port = settings.AkkaManagementOptions.Port;
                    setup.Http.BindHostName = "0.0.0.0";
                    setup.Http.BindPort = settings.AkkaManagementOptions.Port;
                })
                .WithClusterBootstrap(options =>
                {
                    options.ContactPointDiscovery.ServiceName = settings.AkkaManagementOptions.ServiceName;
                    options.ContactPointDiscovery.PortName = settings.AkkaManagementOptions.PortName;
                    options.ContactPointDiscovery.RequiredContactPointsNr =
                        settings.AkkaManagementOptions.RequiredContactPointsNr;
                    options.ContactPointDiscovery.ContactWithAllContactPoints = true;
                    options.ContactPointDiscovery.StableMargin = TimeSpan.FromSeconds(5);
                    options.ContactPoint.FilterOnFallbackPort =
                        settings.AkkaManagementOptions.FilterOnFallbackPort;
                }, autoStart: true);

            ConfigureDiscovery(builder, settings, configuration);
        }
        else
        {
            builder.WithClustering(settings.ClusterOptions);
        }

        return builder;
    }

    private static void ConfigureDiscovery(
        AkkaConfigurationBuilder builder,
        AkkaSettings settings,
        IConfiguration configuration)
    {
        switch (settings.AkkaManagementOptions!.DiscoveryMethod)
        {
            case DiscoveryMethod.Kubernetes:
                builder.WithKubernetesDiscovery();
                break;

            case DiscoveryMethod.AzureTableStorage:
                var connectionString = configuration.GetConnectionString("AkkaManagementAzure");
                if (connectionString is null)
                    throw new Exception("AkkaManagement table storage connection string [AkkaManagementAzure] is missing");

                builder
                    .WithAzureDiscovery(options =>
                    {
                        options.ServiceName = settings.AkkaManagementOptions.ServiceName;
                        options.ConnectionString = connectionString;
                        options.HostName = settings.RemoteOptions.PublicHostName?.ToLower() ?? "localhost";
                        options.Port = settings.AkkaManagementOptions.Port;
                    })
                    .AddHocon(AzureDiscovery.DefaultConfiguration(), HoconAddMode.Append);
                break;

            case DiscoveryMethod.Config:
                builder.WithConfigDiscovery(options =>
                {
                    options.Services.Add(new Service
                    {
                        Name = settings.AkkaManagementOptions.ServiceName,
                        Endpoints =
                        [
                            $"{settings.AkkaManagementOptions.Hostname}:{settings.AkkaManagementOptions.Port}"
                        ]
                    });
                });
                break;

            default:
                throw new ArgumentOutOfRangeException();
        }
    }

    private static void ConfigureRemoteOptionsWithTls(AkkaSettings settings)
    {
        var tlsSettings = settings.TlsSettings!;
        var remoteOptions = settings.RemoteOptions;

        var certificate = tlsSettings.LoadCertificate();
        if (certificate is null)
            throw new InvalidOperationException("TLS is enabled but no certificate could be loaded");

        remoteOptions.EnableSsl = true;
        remoteOptions.Ssl = new SslOptions
        {
            X509Certificate = certificate,
            SuppressValidation = !tlsSettings.ValidateCertificates
        };

        // Update seed nodes to use akka.ssl.tcp:// protocol
        if (settings.ClusterOptions.SeedNodes?.Length > 0)
        {
            settings.ClusterOptions.SeedNodes = settings.ClusterOptions.SeedNodes
                .Select(node => node.Replace("akka.tcp://", "akka.ssl.tcp://"))
                .ToArray();
        }
    }
}
```

## Program.cs Integration

```csharp
using YourApp.Config;
using Petabridge.Cmd.Host;
using Petabridge.Cmd.Cluster;

var builder = WebApplication.CreateBuilder(args);

// Add services
builder.Services.AddRazorPages(); // or whatever your app needs

// Configure Akka.NET
builder.Services.ConfigureAkka(builder.Configuration,
    (configurationBuilder, provider) =>
    {
        var options = provider.GetRequiredService<AkkaSettings>();

        // Add Petabridge.Cmd for cluster management
        configurationBuilder.AddPetabridgeCmd(
            options: options.PbmOptions,
            hostConfiguration: cmd =>
            {
                cmd.RegisterCommandPalette(ClusterCommands.Instance);
            });
    });

var app = builder.Build();

// Configure middleware
app.MapRazorPages();
app.Run();
```

## Aspire AppHost Configuration (Program.cs)

```csharp
using System.Net.Sockets;

var builder = DistributedApplication.CreateBuilder(args);

var config = builder.Configuration.GetSection("YourApp")
    .Get<YourAppConfiguration>() ?? new YourAppConfiguration();

var saPassword = builder.AddParameter(
    "sql-sa-password",
    () => "YourStrong!Passw0rd",
    secret: true);

var sqlServer = builder.AddSqlServer("sql", saPassword);

if (config.UseVolumes)
{
    sqlServer.WithDataVolume();
}

var db = sqlServer.AddDatabase("YourDb");

var app = builder.AddProject<Projects.YourApp>("yourapp")
    .WithReplicas(config.Replicas)
    .WithReference(db, "DefaultConnection")
    .ConfigureAkkaManagementForApp(config);

builder.Build().Run();

public class YourAppConfiguration
{
    public int Replicas { get; set; } = 1;
    public bool UseVolumes { get; set; } = false;
    public bool UseAkkaManagement { get; set; } = false;
}
```

## Aspire Akka.Management Extensions (AkkaManagementExtensions.cs)

```csharp
using System.Net.Sockets;
using Aspire.Hosting.Azure;

namespace YourApp.AppHost;

public static class AkkaManagementExtensions
{
    public static IResourceBuilder<ProjectResource> ConfigureAkkaManagementForApp(
        this IResourceBuilder<ProjectResource> appBuilder,
        YourAppConfiguration config)
    {
        if (!config.UseAkkaManagement) return appBuilder;

        var builder = appBuilder.ApplicationBuilder;

        // Setup Azure Table Storage for discovery
        var azureStorage = builder.AddAzureStorage("storage")
            .RunAsEmulator();

        var tableStorage = azureStorage.AddTables("akka-discovery");

        appBuilder.WaitFor(tableStorage)
            .WithReference(tableStorage, "AkkaManagementAzure");

        // Setup network endpoint ports
        appBuilder
            .WithEndpoint(name: "remote", protocol: ProtocolType.Tcp,
                env: "AkkaSettings__RemoteOptions__Port")
            .WithEndpoint(name: "management", protocol: ProtocolType.Tcp,
                env: "AkkaSettings__AkkaManagementOptions__Port")
            .WithEndpoint(name: "pbm", protocol: ProtocolType.Tcp,
                env: "AkkaSettings__PbmOptions__Port");

        // Configure Akka.Management settings via environment variables
        appBuilder
            .WithEnvironment("AkkaSettings__RemoteOptions__PublicHostName", "localhost")
            .WithEnvironment("AkkaSettings__AkkaManagementOptions__Enabled", "true")
            .WithEnvironment("AkkaSettings__AkkaManagementOptions__Hostname", "localhost")
            .WithEnvironment("AkkaSettings__AkkaManagementOptions__DiscoveryMethod", "AzureTableStorage")
            .WithEnvironment("AkkaSettings__AkkaManagementOptions__RequiredContactPointsNr",
                config.Replicas.ToString())
            .WithEnvironment("AkkaSettings__AkkaManagementOptions__FilterOnFallbackPort", "false");

        return appBuilder;
    }
}
```

## appsettings.json Configuration

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost;Database=YourDb;User Id=sa;Password=YourStrong!Passw0rd;"
  },
  "AkkaSettings": {
    "ActorSystemName": "YourSystem",
    "LogConfigOnStart": false,
    "RemoteOptions": {
      "PublicHostName": null,
      "HostName": "0.0.0.0",
      "Port": 8081
    },
    "ClusterOptions": {
      "Roles": ["your-role"],
      "SeedNodes": []
    },
    "PbmOptions": {
      "Host": "0.0.0.0",
      "Port": 9110
    }
  }
}
```

## Common Patterns

### Pattern 1: Actor Registration with Dependency Injection

```csharp
// In your actor project
public static class ActorRegistration
{
    public static AkkaConfigurationBuilder AddYourActor(
        this AkkaConfigurationBuilder builder,
        string roleName)
    {
        builder.WithActors((system, registry, resolver) =>
        {
            var props = resolver.Props<YourActor>();
            var actor = system.ActorOf(props, "your-actor");
            registry.Register<YourActor>(actor);
        });

        return builder;
    }
}

// In AkkaConfiguration.cs
builder
    .ConfigureNetwork(provider)
    .WithSqlPersistence(...)
    .AddYourActor(roleName);  // Register your actor
```

### Pattern 2: Cluster Sharding Setup

```csharp
builder.WithShardRegion<YourEntityActor>(
    typeName: "your-entity",
    entityPropsFactory: (_, _, resolver) => resolver.Props<YourEntityActor>(),
    extractEntityId: ExtractEntityId,
    extractShardId: ExtractShardId,
    shardOptions: new ShardOptions
    {
        Role = "your-role",
        StateStoreMode = StateStoreMode.Persistence
    });

private static string ExtractEntityId(object message)
{
    return message switch
    {
        IEntityMessage msg => msg.EntityId,
        _ => null
    };
}

private static string ExtractShardId(object message)
{
    return message switch
    {
        IEntityMessage msg => (msg.EntityId.GetHashCode() % 10).ToString(),
        _ => null
    };
}
```

### Pattern 3: Health Checks

Always configure health checks in Program.cs:

```csharp
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy("Application is running"),
        tags: new[] { "liveness" });

// Akka health checks are added automatically by:
// - .WithAkkaClusterReadinessCheck()
// - .WithActorSystemLivenessCheck()
// - journalBuilder.WithHealthCheck()
// - snapshotBuilder.WithHealthCheck()
```

## Common Issues and Solutions

### Issue 1: Cluster Nodes Can't Discover Each Other

**Symptoms:** Nodes stay as "Unreachable" in cluster status

**Solution:**
1. Verify `RequiredContactPointsNr` matches the number of replicas
2. Check that all nodes use the same `ServiceName` in AkkaManagementOptions
3. Ensure Azure Table Storage connection string is correct
4. Verify firewall/network allows TCP on remote and management ports

### Issue 2: Persistence Initialization Fails

**Symptoms:** Application fails to start with SQL connection errors

**Solution:**
1. Ensure SQL Server is running (check Aspire dashboard)
2. Verify connection string is correctly configured
3. Set `autoInitialize: true` in WithSqlPersistence
4. Check that database exists and is accessible

### Issue 3: Split Brain in Development

**Symptoms:** Multiple separate clusters form instead of one unified cluster

**Solution:**
1. Use `FilterOnFallbackPort = false` in local development
2. Ensure all replicas use the same discovery configuration
3. Set `ContactWithAllContactPoints = true`
4. Increase `StableMargin` for slower dev machines

## Testing Akka.NET Actors

For comprehensive Akka.NET testing patterns using **Akka.Hosting.TestKit**, see the `akka-net-testing-patterns` skill.

That skill covers:
- Modern testing with Akka.Hosting.TestKit and dependency injection
- TestProbe patterns for verifying actor interactions
- Testing persistent actors and event sourcing
- Local cluster sharding tests with `AkkaExecutionMode.LocalTest`
- Scenario-based integration tests
- Best practices and anti-patterns

### Quick Example: Testing Akka + Aspire Integration

When testing Aspire applications with Akka.NET actors, combine `aspire-integration-testing` patterns with `akka-net-testing-patterns`:

```csharp
// Use Aspire's DistributedApplicationTestingBuilder for infrastructure
// Use Akka.Hosting.TestKit for actor testing
public class AkkaAspireIntegrationTests : IAsyncLifetime
{
    private DistributedApplication? _app;

    public async Task InitializeAsync()
    {
        var appHost = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.YourApp_AppHost>();

        _app = await appHost.BuildAsync();
        await _app.StartAsync();
    }

    [Fact]
    public async Task ActorSystem_WithRealDatabase_ShouldPersistEvents()
    {
        // Get SQL connection string from Aspire
        var dbResource = _app!.GetResource("yourdb");
        var connectionString = await dbResource.GetConnectionStringAsync();

        // Create HttpClient to test actor endpoints
        var httpClient = _app.CreateHttpClient("yourapp");

        // Test actor behavior through HTTP API
        var response = await httpClient.PostAsJsonAsync("/orders", new
        {
            OrderId = "ORDER-001",
            Amount = 100.00m
        });

        response.Should().BeSuccessStatusCode();

        // Verify data was persisted to real database
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();

        var events = await connection.QueryAsync<string>(
            "SELECT EventType FROM EventJournal WHERE PersistenceId = 'order-ORDER-001'");

        events.Should().Contain("OrderCreated");
    }

    public async Task DisposeAsync()
    {
        if (_app is not null)
            await _app.DisposeAsync();
    }
}
```

**For unit testing individual actors**, use `akka-net-testing-patterns` with in-memory persistence (no Aspire needed).

## Best Practices Summary

1. **Always use health checks** - Configure readiness and liveness checks for all components
2. **Bind settings from configuration** - Never hard-code hostnames, ports, or connection strings
3. **Use Akka.Management for multi-node** - Don't use static seed nodes for clusters with >1 replica
4. **Configure TLS for production** - Always use TLS in production environments
5. **Separate actor logic from configuration** - Keep actors pure and configuration in extension methods
6. **Use Petabridge.Cmd** - Essential for debugging and managing clusters
7. **Test with multiple replicas** - Always test with `Replicas > 1` to catch clustering issues
8. **Monitor persistence health** - Configure health checks for journal and snapshot stores
