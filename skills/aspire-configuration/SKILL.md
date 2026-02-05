---
name: aspire-configuration
description: Configure Aspire AppHost to emit explicit app config via environment variables; keep app code free of Aspire clients and service discovery.
invocable: false
---

# Aspire Configuration

## When to Use This Skill

Use this skill when:
- Wiring AppHost resources to application configuration in Aspire-based repos
- Ensuring production configuration is transparent and portable outside of Aspire
- Avoiding Aspire client/service-discovery packages inside application code
- Designing feature toggles for dev/test without changing app code paths

---

## Core Principles

1. **AppHost owns Aspire infrastructure packages**
   - Aspire Hosting packages belong in AppHost only.
   - App projects should not reference Aspire client/service-discovery packages.

2. **Explicit configuration only**
   - AppHost must translate resource outputs into explicit config keys (env vars).
   - App code binds to `IOptions<T>` or `Configuration` only.

3. **Production parity and transparency**
   - Every value injected by AppHost must be representable in production as env vars
     or config files without Aspire.
   - Avoid opaque service discovery and implicit configuration.

---

## Configuration Flow

```
AppHost resource -> WithEnvironment(...) -> app config keys -> IOptions<T> in app
```

The AppHost is responsible for turning Aspire resources into explicit app settings.
The application never consumes Aspire clients or service discovery directly.

---

## AppHost Patterns (Explicit Mapping)

### Example: Database + Blob Storage

```csharp
// AppHost/Program.cs
var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddPostgres("postgres");
var db = postgres.AddDatabase("appdb");

var minio = builder.AddContainer("minio", "minio/minio")
    .WithArgs("server", "/data")
    .WithHttpEndpoint(targetPort: 9000, name: "http")
    .WithHttpEndpoint(targetPort: 9001, name: "console")
    .WithEnvironment("MINIO_ROOT_USER", "minioadmin")
    .WithEnvironment("MINIO_ROOT_PASSWORD", "minioadmin");

var api = builder.AddProject<Projects.MyApp_Api>("api")
    .WithReference(db, "Postgres")
    .WithEnvironment("BlobStorage__Enabled", "true")
    .WithEnvironment("BlobStorage__ServiceUrl", minio.GetEndpoint("http"))
    .WithEnvironment("BlobStorage__AccessKey", "minioadmin")
    .WithEnvironment("BlobStorage__SecretKey", "minioadmin")
    .WithEnvironment("BlobStorage__Bucket", "attachments")
    .WithEnvironment("BlobStorage__ForcePathStyle", "true");

builder.Build().Run();
```

**Key points**
- `WithReference(db, "Postgres")` sets `ConnectionStrings__Postgres` explicitly.
- Every external dependency is represented via explicit config keys.
- The API project only reads `Configuration` values.

---

## App Code Pattern (No Aspire Clients)

Application code binds to options and initializes SDKs directly. It never depends
on Aspire client packages or service discovery.

```csharp
// Api/Program.cs
builder.Services
    .AddOptions<BlobStorageOptions>()
    .BindConfiguration("BlobStorage")
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton<IBlobStorageService>(sp =>
{
    var options = sp.GetRequiredService<IOptions<BlobStorageOptions>>().Value;
    return new S3BlobStorageService(options); // uses explicit options only
});
```

**Do not** add Aspire client packages (or `AddServiceDiscovery`) to the app.
Those are orchestration concerns and should stay in AppHost.

---

## Feature Toggles and Test Overrides

Keep toggles in config and drive them through AppHost and test fixtures. This
maintains parity between dev/test and production configuration.

```csharp
// AppHost: disable persistence in tests via config overrides
var config = builder.Configuration.GetSection("App")
    .Get<AppHostConfiguration>() ?? new AppHostConfiguration();

if (!config.UseVolumes)
{
    postgres.WithDataVolume(false);
}

api.WithEnvironment("BlobStorage__Enabled", config.EnableBlobStorage.ToString());
```

See `skills/aspire/integration-testing/SKILL.md` for patterns on passing
configuration overrides into `DistributedApplicationTestingBuilder`.

---

## Do / Don’t Checklist

**Do**
- Map every Aspire resource output to explicit configuration keys
- Use `IOptions<T>` with validation for all infrastructure settings
- Keep AppHost as the only place that references Aspire hosting packages
- Ensure any AppHost-injected value can be set in production env vars

**Don’t**
- Reference Aspire client/service-discovery packages in application projects
- Rely on opaque service discovery that cannot be mirrored in production
- Hide configuration behind Aspire-only abstractions

---

## Related Skills

- `skills/aspire/service-defaults/SKILL.md`
- `skills/aspire/integration-testing/SKILL.md`
- `skills/akka/aspire-configuration/SKILL.md`

---

## Resources

- Aspire AppHost environment configuration: https://learn.microsoft.com/en-us/dotnet/aspire/fundamentals/app-host
- Configuration in .NET: https://learn.microsoft.com/en-us/dotnet/core/extensions/configuration
