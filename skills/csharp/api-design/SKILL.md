---
name: api-design
description: Design stable, compatible public APIs using extend-only design principles. Manage API compatibility, wire compatibility, and versioning for NuGet packages and distributed systems.
invocable: false
---

# Public API Design and Compatibility

## When to Use This Skill

Use this skill when:
- Designing public APIs for NuGet packages or libraries
- Making changes to existing public APIs
- Planning wire format changes for distributed systems
- Implementing versioning strategies
- Reviewing pull requests for breaking changes

---

## The Three Types of Compatibility

| Type | Definition | Scope |
|------|------------|-------|
| **API/Source** | Code compiles against newer version | Public method signatures, types |
| **Binary** | Compiled code runs against newer version | Assembly layout, method tokens |
| **Wire** | Serialized data readable by other versions | Network protocols, persistence formats |

Breaking any of these creates upgrade friction for users.

---

## Extend-Only Design

The foundation of stable APIs: **never remove or modify, only extend**.

### Three Pillars

1. **Previous functionality is immutable** - Once released, behavior and signatures are locked
2. **New functionality through new constructs** - Add overloads, new types, opt-in features
3. **Removal only after deprecation period** - Years, not releases

### Benefits

- Old code continues working in new versions
- New and old pathways coexist
- Upgrades are non-breaking by default
- Users upgrade on their schedule

**Resources:**
- [Extend-Only Design](https://aaronstannard.com/extend-only-design/)
- [OSS Compatibility Standards](https://aaronstannard.com/oss-compatibility-standards/)

---

## API Change Guidelines

### Safe Changes (Any Release)

```csharp
// ADD new overloads with default parameters
public void Process(Order order, CancellationToken ct = default);

// ADD new optional parameters to existing methods
public void Send(Message msg, Priority priority = Priority.Normal);

// ADD new types, interfaces, enums
public interface IOrderValidator { }
public enum OrderStatus { Pending, Complete, Cancelled }

// ADD new members to existing types
public class Order
{
    public DateTimeOffset? ShippedAt { get; init; }  // NEW
}
```

### Unsafe Changes (Never or Major Version Only)

```csharp
// REMOVE or RENAME public members
public void ProcessOrder(Order order);  // Was: Process()

// CHANGE parameter types or order
public void Process(int orderId);  // Was: Process(Order order)

// CHANGE return types
public Order? GetOrder(string id);  // Was: public Order GetOrder()

// CHANGE access modifiers
internal class OrderProcessor { }  // Was: public

// ADD required parameters without defaults
public void Process(Order order, ILogger logger);  // Breaks callers!
```

### Deprecation Pattern

```csharp
// Step 1: Mark as obsolete with version (any release)
[Obsolete("Obsolete since v1.5.0. Use ProcessAsync instead.")]
public void Process(Order order) { }

// Step 2: Add new recommended API (same release)
public Task ProcessAsync(Order order, CancellationToken ct = default);

// Step 3: Remove in next major version (v2.0+)
// Only after users have had time to migrate
```

---

## API Approval Testing

Prevent accidental breaking changes with automated API surface testing.

### Using ApiApprover + Verify

```bash
dotnet add package PublicApiGenerator
dotnet add package Verify.Xunit
```

```csharp
[Fact]
public Task ApprovePublicApi()
{
    var api = typeof(MyLibrary.PublicClass).Assembly.GeneratePublicApi();
    return Verify(api);
}
```

Creates `ApprovePublicApi.verified.txt`:

```csharp
namespace MyLibrary
{
    public class OrderProcessor
    {
        public OrderProcessor() { }
        public void Process(Order order) { }
        public Task ProcessAsync(Order order, CancellationToken ct = default) { }
    }
}
```

**Any API change fails the test** - reviewer must explicitly approve changes.

### PR Review Process

1. PR includes changes to `*.verified.txt` files
2. Reviewers see exact API surface changes in diff
3. Breaking changes are immediately visible
4. Conscious decision required to approve

---

## Wire Compatibility

For distributed systems, serialized data must be readable across versions.

### Requirements

| Direction | Requirement |
|-----------|-------------|
| **Backward** | Old writers → New readers (current version reads old data) |
| **Forward** | New writers → Old readers (old version reads new data) |

Both are required for zero-downtime rolling upgrades.

### Safely Evolving Wire Formats

**Phase 1: Add read-side support (opt-in)**

```csharp
// New message type - readers deployed first
public sealed record HeartbeatV2(
    Address From,
    long SequenceNr,
    long CreationTimeMs);  // NEW field

// Deserializer handles both old and new
public object Deserialize(byte[] data, string manifest) => manifest switch
{
    "Heartbeat" => DeserializeHeartbeatV1(data),   // Old format
    "HeartbeatV2" => DeserializeHeartbeatV2(data), // New format
    _ => throw new NotSupportedException()
};
```

**Phase 2: Enable write-side (opt-out, next minor version)**

```csharp
// Config to enable new format (off by default initially)
akka.cluster.use-heartbeat-v2 = on
```

**Phase 3: Make default (future version)**

After install base has absorbed read-side code.

### Schema-Based Serialization

Prefer schema-based formats over reflection-based:

| Format | Type | Wire Compatibility |
|--------|------|-------------------|
| **Protocol Buffers** | Schema-based | Excellent - explicit field numbers |
| **MessagePack** | Schema-based | Good - with contracts |
| **System.Text.Json** | Schema-based (with source gen) | Good - explicit properties |
| Newtonsoft.Json | Reflection-based | Poor - type names in payload |
| BinaryFormatter | Reflection-based | Terrible - never use |

See `dotnet/serialization` skill for details.

---

## Encapsulation Patterns

### Internal APIs

Mark non-public APIs explicitly:

```csharp
// Attribute for documentation
[InternalApi]
public class ActorSystemImpl { }

// Namespace convention
namespace MyLibrary.Internal
{
    public class InternalHelper { }  // Public for extensibility, not for users
}
```

Document clearly:

> Types in `.Internal` namespaces or marked with `[InternalApi]` may change between any releases without notice.

### Sealing Classes

```csharp
// DO: Seal classes not designed for inheritance
public sealed class OrderProcessor { }

// DON'T: Leave unsealed by accident
public class OrderProcessor { }  // Users might inherit, blocking changes
```

### Interface Segregation

```csharp
// DO: Small, focused interfaces
public interface IOrderReader
{
    Order? GetById(OrderId id);
}

public interface IOrderWriter
{
    Task SaveAsync(Order order);
}

// DON'T: Monolithic interfaces (can't add methods without breaking)
public interface IOrderRepository
{
    Order? GetById(OrderId id);
    Task SaveAsync(Order order);
    // Adding new methods breaks all implementations!
}
```

---

## Versioning Strategy

### Semantic Versioning (Practical)

| Version | Changes Allowed |
|---------|----------------|
| **Patch** (1.0.x) | Bug fixes, security patches |
| **Minor** (1.x.0) | New features, deprecations, obsolete removal |
| **Major** (x.0.0) | Breaking changes, old API removal |

### Key Principles

1. **No surprise breaks** - Even major versions should be announced and planned
2. **Extensions anytime** - New APIs can ship in any release
3. **Deprecate before remove** - `[Obsolete]` for at least one minor version
4. **Communicate timelines** - Users need to plan upgrades

### Chesterton's Fence

> Before removing or changing something, understand why it exists.

Assume every public API is used by someone. If you want to change it:
1. Socialize the proposal on GitHub
2. Document migration path
3. Provide deprecation period
4. Ship in planned release

---

## Pull Request Checklist

When reviewing PRs that touch public APIs:

- [ ] **No removed public members** (use `[Obsolete]` instead)
- [ ] **No changed signatures** (add overloads instead)
- [ ] **No new required parameters** (use defaults)
- [ ] **API approval test updated** (`.verified.txt` changes reviewed)
- [ ] **Wire format changes are opt-in** (read-side first)
- [ ] **Breaking changes documented** (release notes, migration guide)

---

## Anti-Patterns

### Breaking Changes Disguised as Fixes

```csharp
// "Bug fix" that breaks users
public async Task<Order> GetOrderAsync(OrderId id)  // Was sync!
{
    // "Fixed" to be async - but breaks all callers
}

// Correct: Add new method, deprecate old
[Obsolete("Use GetOrderAsync instead")]
public Order GetOrder(OrderId id) => GetOrderAsync(id).Result;

public async Task<Order> GetOrderAsync(OrderId id) { }
```

### Silent Behavior Changes

```csharp
// Changing defaults breaks users who relied on old behavior
public void Configure(bool enableCaching = true)  // Was: false!

// Correct: New parameter with new name
public void Configure(
    bool enableCaching = false,  // Original default preserved
    bool enableNewCaching = true)  // New behavior opt-in
```

### Polymorphic Serialization

```csharp
// AVOID: Type names in wire format
{ "$type": "MyApp.Order, MyApp", "Id": 123 }

// Renaming Order class = wire break!

// PREFER: Explicit discriminators
{ "type": "order", "id": 123 }
```

---

## Resources

- [Making Public API Changes](https://getakka.net/community/contributing/api-changes-compatibility.html)
- [Wire Format Changes](https://getakka.net/community/contributing/wire-compatibility.html)
- [Extend-Only Design](https://aaronstannard.com/extend-only-design/)
- [OSS Compatibility Standards](https://aaronstannard.com/oss-compatibility-standards/)
- [Semantic Versioning](https://semver.org/)
- [PublicApiGenerator](https://github.com/PublicApiGenerator/PublicApiGenerator)
