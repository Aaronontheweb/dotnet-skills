# Configuration Reference

Strongly-typed configuration model classes for Akka.Management.

## Contents

- [AkkaManagementOptions](#akkamanagementoptions)
- [ClusterBootstrapOptions](#clusterbootstrapoptions)
- [Discovery-Specific Options](#discovery-specific-options)

## AkkaManagementOptions

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

## ClusterBootstrapOptions

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

## Discovery-Specific Options

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
