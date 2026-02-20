# Anti-Patterns and Reference

## Contents

- [Anti-Patterns to Avoid](#anti-patterns-to-avoid)
- [Traditional Akka.TestKit (Legacy/Core Development)](#traditional-akkatestkit-legacycore-development)
- [CI/CD Integration](#cicd-integration)
- [Additional Resources](#additional-resources)

## Anti-Patterns to Avoid

### DON'T: Create Custom Test Base Classes

```csharp
// BAD: Custom base class for "DRY" setup
public abstract class BaseAkkaTest : TestKit
{
    protected IActorRef OrderActor { get; private set; }
    protected FakeOrderRepository FakeRepository { get; private set; }

    protected override void ConfigureAkka(...)
    {
        // Setup shared across all tests
    }
}

public class OrderActorTests : BaseAkkaTest
{
    // Now coupled to BaseAkkaTest setup
}
```

**Why it's bad:**
- Tight coupling between tests
- Hidden dependencies (what services are registered?)
- Difficult to customize per-test
- Violates principle of test isolation

**DO: Use Method Overrides**

Each test class overrides `ConfigureServices()` and `ConfigureAkka()` with exactly what it needs.

### DON'T: Share State Between Tests

```csharp
// BAD: Reusing same actor instance across tests
public class OrderActorTests : TestKit
{
    private readonly IActorRef _orderActor;

    public OrderActorTests()
    {
        _orderActor = /* create once */;
    }

    [Fact] public void Test1() { /* uses _orderActor */ }
    [Fact] public void Test2() { /* uses _orderActor */ }
}
```

**Why it's bad:**
- Test1 and Test2 share state
- Test execution order matters
- Flaky tests due to side effects

**DO: Use xUnit Class Fixtures or Get Fresh Actors**

```csharp
// GOOD: Each test gets clean ActorSystem
public class OrderActorTests : TestKit
{
    [Fact]
    public async Task Test1()
    {
        var actor = ActorRegistry.Get<OrderActor>(); // Fresh system
        // Test
    }

    [Fact]
    public async Task Test2()
    {
        var actor = ActorRegistry.Get<OrderActor>(); // Fresh system
        // Test
    }
}
```

### DON'T: Use Real External Dependencies

```csharp
// BAD: Using real database in tests
protected override void ConfigureServices(...)
{
    services.AddDbContext<OrderDbContext>(options =>
        options.UseSqlServer(connectionString)); // Real DB!
}
```

**DO: Use Fakes or In-Memory Alternatives**

```csharp
// GOOD: Fake repository
protected override void ConfigureServices(...)
{
    services.AddSingleton<IOrderRepository>(_fakeRepository);
}
```

## Traditional Akka.TestKit (Legacy/Core Development)

For completeness, here's the traditional TestKit approach (use only when you can't use Microsoft.Extensions):

```csharp
using Akka.Actor;
using Akka.TestKit.Xunit2;
using Xunit;

public class OrderActorTests_Traditional : TestKit
{
    public OrderActorTests_Traditional()
        : base(@"akka.loglevel = DEBUG")
    {
    }

    [Fact]
    public void CreateOrder_SendsConfirmation()
    {
        // Arrange - Create actor manually with Props
        var orderActor = Sys.ActorOf(Props.Create<OrderActor>(), "order-actor");

        // Act
        orderActor.Tell(new CreateOrder("ORDER-001", 100m));

        // Assert
        var confirmation = ExpectMsg<OrderCreated>();
        Assert.Equal("ORDER-001", confirmation.OrderId);
    }

    [Fact]
    public void OrderActor_RespondsToQuery()
    {
        // Arrange
        var orderActor = Sys.ActorOf(Props.Create<OrderActor>());

        // Act
        orderActor.Tell(new CreateOrder("ORDER-002", 200m));
        ExpectMsg<OrderCreated>(); // Drain creation message

        // Query
        orderActor.Tell(new GetOrderState("ORDER-002"));

        // Assert
        var state = ExpectMsg<OrderState>();
        Assert.Equal("ORDER-002", state.OrderId);
        Assert.Equal(200m, state.Amount);
    }
}
```

**Key Differences:**
- Manual `Props.Create<T>()` instead of DI
- No service injection (actors must create dependencies internally or use `Context`)
- `ExpectMsg<T>()` instead of `Ask` patterns
- Constructor takes HOCON config string

**When to use:**
- Contributing to Akka.NET core
- Legacy projects without Microsoft.Extensions
- Console applications that don't use DI

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Akka.NET Tests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Setup .NET
      uses: actions/setup-dotnet@v3
      with:
        dotnet-version: 9.0.x

    - name: Restore dependencies
      run: dotnet restore

    - name: Build
      run: dotnet build --no-restore -c Release

    - name: Run Akka.NET tests
      run: |
        dotnet test tests/MyApp.Domain.Tests \
          --no-build \
          -c Release \
          --logger trx \
          --collect:"XPlat Code Coverage"

    - name: Publish test results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: test-results
        path: "**/TestResults/*.trx"
```

## Additional Resources

- **Akka.NET Documentation**: https://getakka.net/
- **Akka.Hosting Documentation**: https://github.com/akkadotnet/Akka.Hosting
- **Petabridge Bootcamp**: https://petabridge.com/bootcamp/ (comprehensive Akka.NET training)
- **Akka.TestKit Guide**: https://getakka.net/articles/testing/testing-actor-systems.html
