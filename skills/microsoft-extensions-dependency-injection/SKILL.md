---
name: dependency-injection-patterns
description: Organize DI registrations using IServiceCollection extension methods. Group related services into composable Add* methods for clean Program.cs and reusable configuration in tests.
invocable: false
---

# Dependency Injection Patterns

## When to Use This Skill

Use this skill when:
- Organizing service registrations in ASP.NET Core applications
- Avoiding massive Program.cs/Startup.cs files with hundreds of registrations
- Making service configuration reusable between production and tests
- Designing libraries that integrate with Microsoft.Extensions.DependencyInjection

## Reference Files

- [advanced-patterns.md](advanced-patterns.md): Testing with DI extensions, Akka.NET actor scope management, conditional/factory/keyed registration patterns

---

## The Problem

Without organization, Program.cs becomes unmanageable:

```csharp
// BAD: 200+ lines of unorganized registrations
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IOrderRepository, OrderRepository>();
builder.Services.AddScoped<IProductRepository, ProductRepository>();
builder.Services.AddScoped<IUserService, UserService>();
// ... 150 more lines ...
```

Problems: hard to find related registrations, no clear boundaries, can't reuse in tests, merge conflicts.

---

## The Solution: Extension Method Composition

Group related registrations into extension methods:

```csharp
// GOOD: Clean, composable Program.cs
var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddUserServices()
    .AddOrderServices()
    .AddEmailServices()
    .AddPaymentServices()
    .AddValidators();

var app = builder.Build();
```

---

## Extension Method Pattern

### Basic Structure

```csharp
namespace MyApp.Users;

public static class UserServiceCollectionExtensions
{
    public static IServiceCollection AddUserServices(this IServiceCollection services)
    {
        services.AddScoped<IUserRepository, UserRepository>();
        services.AddScoped<IUserReadStore, UserReadStore>();
        services.AddScoped<IUserWriteStore, UserWriteStore>();
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<IUserValidationService, UserValidationService>();

        return services;
    }
}
```

### With Configuration

```csharp
namespace MyApp.Email;

public static class EmailServiceCollectionExtensions
{
    public static IServiceCollection AddEmailServices(
        this IServiceCollection services,
        string configSectionName = "EmailSettings")
    {
        services.AddOptions<EmailOptions>()
            .BindConfiguration(configSectionName)
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddSingleton<IMjmlTemplateRenderer, MjmlTemplateRenderer>();
        services.AddSingleton<IEmailLinkGenerator, EmailLinkGenerator>();
        services.AddScoped<IUserEmailComposer, UserEmailComposer>();
        services.AddScoped<IEmailSender, SmtpEmailSender>();

        return services;
    }
}
```

---

## File Organization

Place extension methods near the services they register:

```
src/
  MyApp.Api/
    Program.cs                    # Composes all Add* methods
  MyApp.Users/
    Services/
      UserService.cs
    UserServiceCollectionExtensions.cs   # AddUserServices()
  MyApp.Orders/
    OrderServiceCollectionExtensions.cs  # AddOrderServices()
  MyApp.Email/
    EmailServiceCollectionExtensions.cs  # AddEmailServices()
```

**Convention**: `{Feature}ServiceCollectionExtensions.cs` next to the feature's services.

---

## Naming Conventions

| Pattern | Use For |
|---------|---------|
| `Add{Feature}Services()` | General feature registration |
| `Add{Feature}()` | Short form when unambiguous |
| `Configure{Feature}()` | When primarily setting options |
| `Use{Feature}()` | Middleware (on IApplicationBuilder) |

---

## Testing Benefits

The `Add*` pattern lets you **reuse production configuration in tests** and only override what's different. Works with WebApplicationFactory, Akka.Hosting.TestKit, and standalone ServiceCollection.

See [advanced-patterns.md](advanced-patterns.md) for complete testing examples.

---

## Layered Extensions

For larger applications, compose extensions hierarchically:

```csharp
public static class AppServiceCollectionExtensions
{
    public static IServiceCollection AddAppServices(this IServiceCollection services)
    {
        return services
            .AddDomainServices()
            .AddInfrastructureServices()
            .AddApiServices();
    }
}

public static class DomainServiceCollectionExtensions
{
    public static IServiceCollection AddDomainServices(this IServiceCollection services)
    {
        return services
            .AddUserServices()
            .AddOrderServices()
            .AddProductServices();
    }
}
```

---

## Akka.Hosting Integration

The same pattern works for Akka.NET actor configuration:

```csharp
public static class OrderActorExtensions
{
    public static AkkaConfigurationBuilder AddOrderActors(
        this AkkaConfigurationBuilder builder)
    {
        return builder
            .WithActors((system, registry, resolver) =>
            {
                var orderProps = resolver.Props<OrderActor>();
                var orderRef = system.ActorOf(orderProps, "orders");
                registry.Register<OrderActor>(orderRef);
            });
    }
}

// Usage in Program.cs
builder.Services.AddAkka("MySystem", (builder, sp) =>
{
    builder
        .AddOrderActors()
        .AddInventoryActors()
        .AddNotificationActors();
});
```

See `akka-hosting-actor-patterns` skill for complete Akka.Hosting patterns.

---

## Anti-Patterns

### Don't: Register Everything in Program.cs

```csharp
// BAD: Massive Program.cs with 200+ lines of registrations
```

### Don't: Create Overly Generic Extensions

```csharp
// BAD: Too vague, doesn't communicate what's registered
public static IServiceCollection AddServices(this IServiceCollection services) { ... }
```

### Don't: Hide Important Configuration

```csharp
// BAD: Buried settings
public static IServiceCollection AddDatabase(this IServiceCollection services)
{
    services.AddDbContext<AppDbContext>(options =>
        options.UseSqlServer("hardcoded-connection-string"));  // Hidden!
}

// GOOD: Accept configuration explicitly
public static IServiceCollection AddDatabase(
    this IServiceCollection services,
    string connectionString)
{
    services.AddDbContext<AppDbContext>(options =>
        options.UseSqlServer(connectionString));
}
```

---

## Best Practices Summary

| Practice | Benefit |
|----------|---------|
| Group related services into `Add*` methods | Clean Program.cs, clear boundaries |
| Place extensions near the services they register | Easy to find and maintain |
| Return `IServiceCollection` for chaining | Fluent API |
| Accept configuration parameters | Flexibility |
| Use consistent naming (`Add{Feature}Services`) | Discoverability |
| Test by reusing production extensions | Confidence, less duplication |

---

## Lifetime Management

| Lifetime | Use When | Examples |
|----------|----------|----------|
| **Singleton** | Stateless, thread-safe, expensive to create | Configuration, HttpClient factories, caches |
| **Scoped** | Stateful per-request, database contexts | DbContext, repositories, user context |
| **Transient** | Lightweight, stateful, cheap to create | Validators, short-lived helpers |

```csharp
// SINGLETON: Stateless services, shared safely
services.AddSingleton<IMjmlTemplateRenderer, MjmlTemplateRenderer>();

// SCOPED: Database access, per-request state
services.AddScoped<IUserRepository, UserRepository>();

// TRANSIENT: Cheap, short-lived
services.AddTransient<CreateUserRequestValidator>();
```

**Scoped services require a scope.** ASP.NET Core creates one per HTTP request. In background services and actors, create scopes manually.

See [advanced-patterns.md](advanced-patterns.md) for actor scope management patterns.

---

## Common Mistakes

### Injecting Scoped into Singleton

```csharp
// BAD: Singleton captures scoped service - stale DbContext!
public class CacheService  // Registered as Singleton
{
    private readonly IUserRepository _repo;  // Scoped - captured at startup!
}

// GOOD: Inject IServiceProvider, create scope per operation
public class CacheService
{
    private readonly IServiceProvider _serviceProvider;

    public async Task<User> GetUserAsync(string id)
    {
        using var scope = _serviceProvider.CreateScope();
        var repo = scope.ServiceProvider.GetRequiredService<IUserRepository>();
        return await repo.GetByIdAsync(id);
    }
}
```

### No Scope in Background Work

```csharp
// BAD: No scope for scoped services
public class BadBackgroundService : BackgroundService
{
    private readonly IOrderService _orderService;  // Scoped - will throw!
}

// GOOD: Create scope for each unit of work
public class GoodBackgroundService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var scope = _scopeFactory.CreateScope();
        var orderService = scope.ServiceProvider.GetRequiredService<IOrderService>();
        // ...
    }
}
```

---

## Resources

- **Microsoft.Extensions.DependencyInjection**: https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection
- **Akka.Hosting**: https://github.com/akkadotnet/Akka.Hosting
- **Akka.DependencyInjection**: https://getakka.net/articles/actors/dependency-injection.html
- **Options Pattern**: See `microsoft-extensions-configuration` skill
