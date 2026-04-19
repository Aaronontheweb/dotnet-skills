---
name: hotchocolate-schema
description: >
  Design Hot Chocolate v15 GraphQL schemas and C# files following framework best practices.
  Use this skill whenever the user asks to: add a GraphQL query or mutation, create a resolver, design a GraphQL type, set up filtering/sorting/pagination, wire up a new feature's API layer, add error handling to mutations, or any task involving Hot Chocolate schema design — even if they just say "add a graphql endpoint" or "wire up the API". This skill covers the full lifecycle: GraphQL schema design, C# resolver and mutation classes, read models, type registrations, and feature module wiring.
---

# Hot Chocolate v15 GraphQL Schema Design

## Architecture Overview

Hot Chocolate schemas in this project follow a vertical-slice structure where each feature owns its GraphQL layer:

```
Features/
  MyFeature/
    API/
      MyFeatureResolvers.cs    ← query resolvers
      MyFeatureMutations.cs    ← mutation resolvers
      MyFeatureGraphQLExtensions.cs  ← IRequestExecutorBuilder extension
    Application/
      ReadModel/
        MyReadModel.cs         ← GraphQL return types (never domain entities)
    Domain/
      MyAggregate.cs
```

---

## Core Principles

### 1. Never Expose Domain Entities
Always create a read model in `Application/ReadModel/`. The GraphQL layer returns read models, not domain aggregates.

```csharp
// ✅ Return a read model
public class ProjectReadModel
{
    public required Guid Id { get; init; }
    public required string Name { get; init; }

    public static ProjectReadModel FromAggregate(ProjectAggregate project) =>
        new() { Id = project.Id, Name = project.Name };
}

// ❌ Never return domain entities
public Task<ProjectAggregate> GetProject(...) { }
```

### 2. One Resolvers File, One Mutations File Per Feature
- `{Feature}Resolvers.cs` — extends `Query` with `[ExtendObjectType<Query>]`
- `{Feature}Mutations.cs` — extends `Mutation` with `[ExtendObjectType<Mutation>]` or `[ExtendObjectType("Mutation")]`

### 3. Mutation Conventions Are Enabled Globally
`AddMutationConventions(true)` is registered in Program.cs. Hot Chocolate automatically wraps each mutation in an `Input`/`Payload` envelope. **Do not** create input or payload classes manually — they're auto-generated.

---

## Resolver Pattern

```csharp
[ExtendObjectType<Query>]
public class OrderResolvers
{
    [Authorize]
    public async Task<OrderReadModel?> GetOrder(
        [Service] IOrderDbContext context,
        Guid orderId)
    {
        var order = await context.Orders.FindAsync(orderId);
        return order is null ? null : OrderReadModel.FromAggregate(order);
    }

    [Authorize]
    public async Task<List<OrderReadModel>> GetOrders(
        [Service] IOrderDbContext context,
        [Service] IUserContext userContext)
    {
        return await context.Orders
            .Where(o => o.OrgId == userContext.OrganizationId)
            .OrderBy(o => o.CreatedAt)
            .Select(o => OrderReadModel.FromAggregate(o))
            .ToListAsync();
    }
}
```

Key conventions:
- Use `[Authorize]` on each resolver method (not the class)
- Inject services with `[Service]` parameters (not constructor injection)
- Return `T?` for single-item lookups, `List<T>` for collections
- `CancellationToken cancellationToken` as the last parameter for async operations

---

## Mutation Pattern

```csharp
[ExtendObjectType<Mutation>]
public class OrderMutations
{
    [Authorize]
    public async Task<OrderReadModel> CreateOrder(
        string title,
        string? notes,
        [Service] IOrderDbContext context,
        [Service] IUserContext userContext,
        [Service] IGuidProvider guidProvider,
        CancellationToken cancellationToken)
    {
        var order = OrderAggregate.Create(title, notes, userContext.OrganizationId, guidProvider);
        context.Orders.Add(order);
        await context.SaveChangesAsync(cancellationToken);
        return OrderReadModel.FromAggregate(order);
    }

    [Authorize]
    [Error<OrderNotFoundException>]
    public async Task<OrderReadModel> UpdateOrder(
        Guid orderId,
        string title,
        string? notes,
        [Service] IOrderDbContext context,
        CancellationToken cancellationToken)
    {
        var order = await context.Orders.FindAsync(orderId, cancellationToken)
            ?? throw new OrderNotFoundException(orderId);

        order.Update(title, notes);
        await context.SaveChangesAsync(cancellationToken);
        return OrderReadModel.FromAggregate(order);
    }

    [Authorize]
    public async Task<bool> DeleteOrder(
        Guid orderId,
        [Service] IOrderDbContext context,
        CancellationToken cancellationToken)
    {
        var order = await context.Orders.FindAsync(orderId, cancellationToken);
        if (order is null) return false;

        context.Orders.Remove(order);
        await context.SaveChangesAsync(cancellationToken);
        return true;
    }
}
```

---

## Error Handling

For domain errors that should appear in the GraphQL payload (not as HTTP errors), use `[Error<TException>]`:

```csharp
[Error<OrderNotFoundException>]
[Error<InsufficientInventoryException>]
public async Task<OrderReadModel> PlaceOrder(...) { }
```

For authorization/validation errors that should fail the whole operation, throw directly:

```csharp
throw new GraphQLException(
    ErrorBuilder.New()
        .SetMessage("Only the order owner can cancel this order.")
        .SetCode("OrderOwnerRequired")
        .Build());
```

---

## Extending Read Model Types

Add computed fields (relationships, derived values) to read models without polluting the read model class:

```csharp
[ExtendObjectType(typeof(OrderReadModel))]
public class OrderExtensions
{
    public async Task<List<LineItemReadModel>> GetLineItems(
        [Parent] OrderReadModel order,
        [Service] IOrderDbContext context) =>
        await context.LineItems
            .Where(li => li.OrderId == order.Id)
            .Select(li => LineItemReadModel.FromEntity(li))
            .ToListAsync();

    public bool GetIsOwner(
        [Parent] OrderReadModel order,
        [Service] IUserContext userContext) =>
        order.CreatedByUserId == userContext.UserId;
}
```

The `[Parent]` attribute injects the resolved parent object. Register it in the feature's extension method.

---

## Pagination

Prefer cursor-based pagination (`[UsePaging]`) for large or frequently-changing datasets:

```csharp
[UsePaging]
[UseFiltering]
[UseSorting]
public IQueryable<OrderReadModel> GetOrders([Service] IOrderDbContext context) =>
    context.Orders.Select(o => OrderReadModel.FromAggregate(o));
```

For simple admin lists, offset pagination is fine:

```csharp
[UseOffsetPaging(MaxPageSize = 100)]
public IQueryable<OrderReadModel> GetOrdersPage([Service] IOrderDbContext context) =>
    context.Orders.AsQueryable();
```

**Middleware order always matters:** `[UsePaging] > [UseProjections] > [UseFiltering] > [UseSorting]`

---

## Filtering and Sorting

Hot Chocolate infers filters from the C# model automatically. To restrict which fields are filterable:

```csharp
public class OrderFilterType : FilterInputType<Order>
{
    protected override void Configure(IFilterInputTypeDescriptor<Order> descriptor)
    {
        descriptor.BindFieldsExplicitly();
        descriptor.Field(f => f.Status);
        descriptor.Field(f => f.CreatedAt);
    }
}

// Reference in resolver:
[UseFiltering(typeof(OrderFilterType))]
public IQueryable<Order> GetOrders([Service] IOrderDbContext context) =>
    context.Orders.AsQueryable();
```

---

## Feature Registration

Each feature registers its GraphQL types via an extension method:

```csharp
public static class OrderGraphQLExtensions
{
    public static IRequestExecutorBuilder AddOrderTypes(
        this IRequestExecutorBuilder builder) =>
        builder
            .AddType<OrderReadModel>()
            .AddTypeExtension<OrderExtensions>()
            .AddTypeExtension<OrderResolvers>()
            .AddTypeExtension<OrderMutations>();
}
```

Then wire it in `Program.cs`:

```csharp
builder.Services
    .AddGraphQLServer()
    .AddMutationConventions(true)
    .AddQueryType<Query>()
    .AddMutationType<Mutation>()
    .AddOrderTypes();   // ← add feature module
```

---

## Read Model Conventions

```csharp
public class OrderReadModel
{
    public required Guid Id { get; init; }
    public required string Title { get; init; }
    public string? Notes { get; init; }
    public required string OrganizationId { get; init; }

    [GraphQLIgnore]  // hide internal tracking fields from the schema
    public required string CreatedByUserId { get; init; }

    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; init; }

    public static OrderReadModel FromAggregate(OrderAggregate order) => new()
    {
        Id = order.Id,
        Title = order.Title,
        Notes = order.Notes,
        OrganizationId = order.OrganizationId,
        CreatedByUserId = order.CreatedByUserId,
        CreatedAt = order.CreatedAt,
        UpdatedAt = order.UpdatedAt,
    };
}
```

Rules:
- Use `required` + `init` for non-nullable fields
- Use `?` for nullable fields
- `[GraphQLIgnore]` for fields internal to the application but present on the read model
- Static `FromAggregate()` (or `FromEntity()`, `FromValueObject()`) factory method — no AutoMapper

---

## GraphQL Type Naming

Hot Chocolate auto-transforms names:
- Strips `Get` prefix and `Async` suffix from method names
- Lowercases the first letter of field names

If you need an explicit name: `[GraphQLName("myCustomName")]`

To hide a method from the schema: `[GraphQLIgnore]`

---

## Subscriptions

For real-time fields, add to the `Subscriptions` root type:

```csharp
[ExtendObjectType<Subscriptions>]
public class OrderSubscriptions
{
    [Subscribe]
    [Topic("{orderId}")]
    public OrderReadModel OnOrderUpdated(
        Guid orderId,
        [EventMessage] OrderReadModel order) => order;
}
```

---

## Common Mistakes to Avoid

| ❌ Avoid | ✅ Do Instead |
|----------|--------------|
| Returning domain entities from resolvers | Return a read model with `FromAggregate()` |
| Creating `Input`/`Payload` classes | Let mutation conventions auto-generate them |
| Constructor DI in resolver/mutation classes | Use `[Service]` parameters |
| `[ExtendObjectType]` without registering | Always call `AddTypeExtension<T>()` in the feature module |
| Mixing query and mutation logic in one file | Separate `{Feature}Resolvers.cs` and `{Feature}Mutations.cs` |
| Skipping `CancellationToken` on async methods | Add `CancellationToken cancellationToken` as last arg |
