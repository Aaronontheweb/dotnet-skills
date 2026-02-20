# Discovery Providers

Detailed configuration and deployment examples for each Akka.Management discovery provider.

## Contents

- [1. Config Discovery (Development/Fixed Infrastructure)](#1-config-discovery-developmentfixed-infrastructure)
- [2. Kubernetes Discovery (Production K8s)](#2-kubernetes-discovery-production-k8s)
- [3. Azure Table Storage Discovery (Azure/Aspire)](#3-azure-table-storage-discovery-azureaspire)
- [Complete Discovery Configuration Switch](#complete-discovery-configuration-switch)

## 1. Config Discovery (Development/Fixed Infrastructure)

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

## 2. Kubernetes Discovery (Production K8s)

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

## 3. Azure Table Storage Discovery (Azure/Aspire)

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

## Complete Discovery Configuration Switch

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
