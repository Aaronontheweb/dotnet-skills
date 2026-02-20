# Advanced DI Patterns

Testing with DI extensions, Akka.NET actor scope management, and advanced registration patterns.

## Contents

- [Testing Benefits](#testing-benefits)
- [Akka.NET Actor Scope Management](#akkanet-actor-scope-management)
- [Common Patterns](#common-patterns)

## Testing Benefits

The main advantage of `Add*` extension methods: **reuse production configuration in tests**.

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

- **Akka.DependencyInjection**: https://getakka.net/articles/actors/dependency-injection.html
- **Akka.Hosting**: https://github.com/akkadotnet/Akka.Hosting

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
        services.AddSingleton<IEmailSender, MailpitEmailSender>();
    }
    else
    {
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
    services.AddKeyedSingleton<INotificationSender, EmailNotificationSender>("email");
    services.AddKeyedSingleton<INotificationSender, SmsNotificationSender>("sms");
    services.AddKeyedSingleton<INotificationSender, PushNotificationSender>("push");

    services.AddScoped<INotificationDispatcher, NotificationDispatcher>();

    return services;
}
```
