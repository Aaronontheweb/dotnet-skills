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
builder.Services.AddScoped<IOrderService, OrderService>();
builder.Services.AddScoped<IEmailSender, SmtpEmailSender>();
builder.Services.AddScoped<IEmailComposer, MjmlEmailComposer>();
builder.Services.AddSingleton<IEmailLinkGenerator, EmailLinkGenerator>();
builder.Services.AddScoped<IPaymentProcessor, StripePaymentProcessor>();
builder.Services.AddScoped<IInvoiceGenerator, InvoiceGenerator>();
// ... 150 more lines ...
```

Problems:
- Hard to find related registrations
- No clear boundaries between subsystems
- Can't reuse configuration in tests
- Merge conflicts in team settings
- No encapsulation of internal dependencies

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

Each `Add*` method encapsulates a cohesive set of registrations.

---

## Extension Method Pattern

### Basic Structure

```csharp
namespace MyApp.Users;

public static class UserServiceCollectionExtensions
{
    public static IServiceCollection AddUserServices(this IServiceCollection services)
    {
        // Repositories
        services.AddScoped<IUserRepository, UserRepository>();
        services.AddScoped<IUserReadStore, UserReadStore>();
        services.AddScoped<IUserWriteStore, UserWriteStore>();

        // Services
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<IUserValidationService, UserValidationService>();

        // Return for chaining
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
        // Bind configuration
        services.AddOptions<EmailOptions>()
            .BindConfiguration(configSectionName)
            .ValidateDataAnnotations()
            .ValidateOnStart();

        // Register services
        services.AddSingleton<IMjmlTemplateRenderer, MjmlTemplateRenderer>();
        services.AddSingleton<IEmailLinkGenerator, EmailLinkGenerator>();
        services.AddScoped<IUserEmailComposer, UserEmailComposer>();
        services.AddScoped<IOrderEmailComposer, OrderEmailComposer>();

        // SMTP client depends on environment
        services.AddScoped<IEmailSender, SmtpEmailSender>();

        return services;
    }
}
```

### With Dependencies on Other Extensions

```csharp
namespace MyApp.Orders;

public static class OrderServiceCollectionExtensions
{
    public static IServiceCollection AddOrderServices(this IServiceCollection services)
    {
        // This subsystem depends on email services
        // Caller is responsible for calling AddEmailServices() first
        // Or we can call it here if it's idempotent

        services.AddScoped<IOrderRepository, OrderRepository>();
        services.AddScoped<IOrderService, OrderService>();
        services.AddScoped<IOrderEmailNotifier, OrderEmailNotifier>();

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
      IUserService.cs
    Repositories/
      UserRepository.cs
    UserServiceCollectionExtensions.cs   # AddUserServices()
  MyApp.Orders/
    Services/
      OrderService.cs
    OrderServiceCollectionExtensions.cs  # AddOrderServices()
  MyApp.Email/
    Composers/
      UserEmailComposer.cs
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

```csharp
// Feature services
services.AddUserServices();
services.AddEmailServices();
services.AddPaymentServices();

// Third-party integrations
services.AddStripePayments();
services.AddSendGridEmail();

// Configuration-heavy
services.ConfigureAuthentication();
services.ConfigureAuthorization();
```

---

## Testing Benefits

The main advantage: **reuse production configuration in tests**.

### WebApplicationFactory

```csharp
public class ApiTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public ApiTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureServices(services =>
            {
                // Production services already registered via Add* methods
                // Only override what's different for testing

                // Replace email sender with test double
                services.RemoveAll<IEmailSender>();
                services.AddSingleton<IEmailSender, TestEmailSender>();

                // Replace external payment processor
                services.RemoveAll<IPaymentProcessor>();
                services.AddSingleton<IPaymentProcessor, FakePaymentProcessor>();
            });
        });
    }

    [Fact]
    public async Task CreateOrder_SendsConfirmationEmail()
    {
        var client = _factory.CreateClient();
        var emailSender = _factory.Services.GetRequiredService<IEmailSender>() as TestEmailSender;

        await client.PostAsJsonAsync("/api/orders", new CreateOrderRequest(...));

        Assert.Single(emailSender!.SentEmails);
    }
}
```

### Akka.Hosting.TestKit

```csharp
public class OrderActorSpecs : Akka.Hosting.TestKit.TestKit
{
    protected override void ConfigureAkka(AkkaConfigurationBuilder builder, IServiceProvider provider)
    {
        // Reuse production Akka configuration
        builder.AddOrderActors();
    }

    protected override void ConfigureServices(IServiceCollection services)
    {
        // Reuse production service configuration
        services.AddOrderServices();

        // Override only external dependencies
        services.RemoveAll<IPaymentProcessor>();
        services.AddSingleton<IPaymentProcessor, FakePaymentProcessor>();
    }

    [Fact]
    public async Task OrderActor_ProcessesPayment()
    {
        var orderActor = ActorRegistry.Get<OrderActor>();
        orderActor.Tell(new ProcessOrder(orderId));

        ExpectMsg<OrderProcessed>();
    }
}
```

### Standalone Unit Tests

```csharp
public class UserServiceTests
{
    private readonly ServiceProvider _provider;

    public UserServiceTests()
    {
        var services = new ServiceCollection();

        // Reuse production registrations
        services.AddUserServices();

        // Add test infrastructure
        services.AddSingleton<IUserRepository, InMemoryUserRepository>();

        _provider = services.BuildServiceProvider();
    }

    [Fact]
    public async Task CreateUser_ValidData_Succeeds()
    {
        var service = _provider.GetRequiredService<IUserService>();
        var result = await service.CreateUserAsync(new CreateUserRequest(...));

        Assert.True(result.IsSuccess);
    }
}
```

---

## Layered Extensions

For larger applications, compose extensions hierarchically:

```csharp
// Top-level: Everything the app needs
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

// Domain layer
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

// Infrastructure layer
public static class InfrastructureServiceCollectionExtensions
{
    public static IServiceCollection AddInfrastructureServices(this IServiceCollection services)
    {
        return services
            .AddEmailServices()
            .AddPaymentServices()
            .AddStorageServices();
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
            })
            .WithShardRegion<OrderShardActor>(
                typeName: "order-shard",
                (system, registry, resolver) =>
                    entityId => resolver.Props<OrderShardActor>(entityId),
                new OrderMessageExtractor(),
                ShardOptions.Create());
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

See `akka/hosting-actor-patterns` skill for complete Akka.Hosting patterns.

---

## Common Patterns

### Conditional Registration

```csharp
public static IServiceCollection AddEmailServices(
    this IServiceCollection services,
    IHostEnvironment environment)
{
    services.AddSingleton<IEmailComposer, MjmlEmailComposer>();

    if (environment.IsDevelopment())
    {
        // Use Mailpit in development
        services.AddSingleton<IEmailSender, MailpitEmailSender>();
    }
    else
    {
        // Use real SMTP in production
        services.AddSingleton<IEmailSender, SmtpEmailSender>();
    }

    return services;
}
```

### Factory-Based Registration

```csharp
public static IServiceCollection AddPaymentServices(
    this IServiceCollection services,
    string configSection = "Stripe")
{
    services.AddOptions<StripeOptions>()
        .BindConfiguration(configSection)
        .ValidateOnStart();

    // Factory for complex initialization
    services.AddSingleton<IPaymentProcessor>(sp =>
    {
        var options = sp.GetRequiredService<IOptions<StripeOptions>>().Value;
        var logger = sp.GetRequiredService<ILogger<StripePaymentProcessor>>();

        return new StripePaymentProcessor(options.ApiKey, options.WebhookSecret, logger);
    });

    return services;
}
```

### Keyed Services (.NET 8+)

```csharp
public static IServiceCollection AddNotificationServices(this IServiceCollection services)
{
    // Register multiple implementations with keys
    services.AddKeyedSingleton<INotificationSender, EmailNotificationSender>("email");
    services.AddKeyedSingleton<INotificationSender, SmsNotificationSender>("sms");
    services.AddKeyedSingleton<INotificationSender, PushNotificationSender>("push");

    // Resolver that picks the right one
    services.AddScoped<INotificationDispatcher, NotificationDispatcher>();

    return services;
}
```

---

## Anti-Patterns

### Don't: Register Everything in Program.cs

```csharp
// BAD: Massive Program.cs
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IOrderRepository, OrderRepository>();
// ... 200 more lines ...
```

### Don't: Create Overly Generic Extensions

```csharp
// BAD: Too vague, doesn't communicate what's registered
public static IServiceCollection AddServices(this IServiceCollection services)
{
    // Registers 50 random things
}
```

### Don't: Hide Important Configuration

```csharp
// BAD: Buried important settings
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

Choose the right lifetime based on state:

| Lifetime | Use When | Examples |
|----------|----------|----------|
| **Singleton** | Stateless, thread-safe, expensive to create | Configuration, HttpClient factories, caches |
| **Scoped** | Stateful per-request, database contexts | DbContext, repositories, user context |
| **Transient** | Lightweight, stateful, cheap to create | Validators, short-lived helpers |

### Rules of Thumb

```csharp
// SINGLETON: Stateless services, shared safely
services.AddSingleton<IMjmlTemplateRenderer, MjmlTemplateRenderer>();
services.AddSingleton<IEmailLinkGenerator, EmailLinkGenerator>();

// SCOPED: Database access, per-request state
services.AddScoped<IUserRepository, UserRepository>();  // DbContext dependency
services.AddScoped<IOrderService, OrderService>();       // Uses scoped repos

// TRANSIENT: Cheap, short-lived
services.AddTransient<CreateUserRequestValidator>();
```

### Scope Requirements

**Scoped services require a scope to exist.** In ASP.NET Core, each HTTP request creates a scope automatically. But in other contexts (background services, actors), you must create scopes manually.

```csharp
// ASP.NET Controller - scope exists automatically
public class OrdersController : ControllerBase
{
    private readonly IOrderService _orderService;  // Scoped - works!

    public OrdersController(IOrderService orderService)
    {
        _orderService = orderService;
    }
}

// Background Service - no automatic scope!
public class OrderProcessingService : BackgroundService
{
    private readonly IServiceProvider _serviceProvider;

    public OrderProcessingService(IServiceProvider serviceProvider)
    {
        // Inject IServiceProvider, NOT scoped services directly
        _serviceProvider = serviceProvider;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            // Create scope manually for each unit of work
            using var scope = _serviceProvider.CreateScope();
            var orderService = scope.ServiceProvider.GetRequiredService<IOrderService>();

            await orderService.ProcessPendingOrdersAsync(ct);
            await Task.Delay(TimeSpan.FromMinutes(1), ct);
        }
    }
}
```

---

## Akka.NET Actor Scope Management

**Actors don't have automatic DI scopes.** If you need scoped services inside an actor, inject `IServiceProvider` and create scopes manually.

### Pattern: Scope Per Message

```csharp
public sealed class AccountProvisionActor : ReceiveActor
{
    private readonly IServiceProvider _serviceProvider;
    private readonly IActorRef _mailingActor;

    public AccountProvisionActor(
        IServiceProvider serviceProvider,
        IRequiredActor<MailingActor> mailingActor)
    {
        _serviceProvider = serviceProvider;
        _mailingActor = mailingActor.ActorRef;

        ReceiveAsync<ProvisionAccount>(HandleProvisionAccount);
    }

    private async Task HandleProvisionAccount(ProvisionAccount msg)
    {
        // Create scope for this message processing
        using var scope = _serviceProvider.CreateScope();

        // Resolve scoped services
        var userManager = scope.ServiceProvider.GetRequiredService<UserManager<User>>();
        var orderRepository = scope.ServiceProvider.GetRequiredService<IOrderRepository>();
        var emailComposer = scope.ServiceProvider.GetRequiredService<IPaymentEmailComposer>();

        // Do work with scoped services
        var user = await userManager.FindByIdAsync(msg.UserId);
        var order = await orderRepository.CreateAsync(msg.Order);

        // DbContext commits when scope disposes
    }
}
```

### Why This Pattern Works

1. **Each message gets fresh DbContext** - No stale entity tracking
2. **Proper disposal** - Connections released after each message
3. **Isolation** - One message's errors don't affect others
4. **Testable** - Can inject mock IServiceProvider

### Singleton Services in Actors

For stateless services, inject directly (no scope needed):

```csharp
public sealed class NotificationActor : ReceiveActor
{
    private readonly IEmailLinkGenerator _linkGenerator;  // Singleton - OK!
    private readonly IActorRef _mailingActor;

    public NotificationActor(
        IEmailLinkGenerator linkGenerator,  // Direct injection
        IRequiredActor<MailingActor> mailingActor)
    {
        _linkGenerator = linkGenerator;
        _mailingActor = mailingActor.ActorRef;

        Receive<SendWelcomeEmail>(Handle);
    }
}
```

### Akka.DependencyInjection Reference

Akka.NET's DI integration is documented at:
- **Akka.DependencyInjection**: https://getakka.net/articles/actors/dependency-injection.html
- **Akka.Hosting**: https://github.com/akkadotnet/Akka.Hosting

---

## Common Mistakes

### Injecting Scoped into Singleton

```csharp
// BAD: Singleton captures scoped service - stale DbContext!
public class CacheService  // Registered as Singleton
{
    private readonly IUserRepository _repo;  // Scoped!

    public CacheService(IUserRepository repo)  // Captured at startup!
    {
        _repo = repo;  // This DbContext lives forever - BAD
    }
}

// GOOD: Inject factory or IServiceProvider
public class CacheService
{
    private readonly IServiceProvider _serviceProvider;

    public CacheService(IServiceProvider serviceProvider)
    {
        _serviceProvider = serviceProvider;
    }

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
    private readonly IOrderService _orderService;  // Scoped!

    public BadBackgroundService(IOrderService orderService)
    {
        _orderService = orderService;  // Will throw or behave unexpectedly
    }
}

// GOOD: Create scope for each unit of work
public class GoodBackgroundService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;

    public GoodBackgroundService(IServiceScopeFactory scopeFactory)
    {
        _scopeFactory = scopeFactory;
    }

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
- **Options Pattern**: See `microsoft-extensions/configuration` skill
