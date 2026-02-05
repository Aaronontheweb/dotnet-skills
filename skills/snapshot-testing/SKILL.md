---
name: snapshot-testing
description: Use Verify for snapshot testing in .NET. Approve API surfaces, HTTP responses, rendered emails, and serialized outputs. Detect unintended changes through human-reviewed baseline files.
invocable: false
---

# Snapshot Testing with Verify

## When to Use This Skill

Use snapshot testing when:
- Verifying rendered output (HTML emails, reports, generated code)
- Approving public API surfaces for breaking change detection
- Testing HTTP response bodies and headers
- Validating serialization output
- Catching unintended changes in complex objects

---

## What is Snapshot Testing?

Snapshot testing captures output and compares it against a human-approved baseline:

1. **First run**: Test generates a `.received.` file with actual output
2. **Human review**: Developer approves it, creating a `.verified.` file
3. **Subsequent runs**: Test compares output against `.verified.` file
4. **Changes detected**: Test fails, diff tool shows differences for review

This catches **unintended changes** while allowing **intentional changes** through explicit approval.

---

## Installation

### Add Verify Package

```bash
dotnet add package Verify.Xunit
# or for other test frameworks:
dotnet add package Verify.NUnit
dotnet add package Verify.MSTest
```

### Configure ModuleInitializer

Create a `ModuleInitializer.cs` in your test project:

```csharp
using System.Runtime.CompilerServices;

public static class ModuleInitializer
{
    [ModuleInitializer]
    public static void Init()
    {
        // Use source-file-relative paths for verified files
        VerifyBase.UseProjectRelativeDirectory("Snapshots");

        // Configure diff tool (optional - auto-detected)
        // DiffTools.UseOrder(DiffTool.Rider, DiffTool.VisualStudioCode);
    }
}
```

---

## Basic Usage

### Simple Object Verification

```csharp
[Fact]
public Task VerifyUserDto()
{
    var user = new UserDto(
        Id: "user-123",
        Name: "John Doe",
        Email: "john@example.com",
        CreatedAt: new DateTime(2025, 1, 15));

    return Verify(user);
}
```

Creates `VerifyUserDto.verified.txt`:
```json
{
  Id: user-123,
  Name: John Doe,
  Email: john@example.com,
  CreatedAt: 2025-01-15T00:00:00
}
```

### String/HTML Verification

```csharp
[Fact]
public async Task VerifyRenderedEmail()
{
    var html = await _emailRenderer.RenderAsync("Welcome", new { Name = "John" });

    // Use extension parameter for proper file naming
    await Verify(html, extension: "html");
}
```

Creates `VerifyRenderedEmail.verified.html` - viewable in browser.

---

## Email Template Testing

Use Verify to catch unintended changes in rendered email templates:

```csharp
[Fact]
public async Task UserSignupInvitation_RendersCorrectly()
{
    var renderer = _services.GetRequiredService<IMjmlTemplateRenderer>();

    var variables = new Dictionary<string, string>
    {
        { "OrganizationName", "Acme Corporation" },
        { "InviteeName", "John Doe" },
        { "InviterName", "Jane Admin" },
        { "InvitationLink", "https://example.com/invite/abc123" },
        { "ExpirationDate", "December 31, 2025" }
    };

    var html = await renderer.RenderTemplateAsync(
        "UserInvitations/UserSignupInvitation",
        variables);

    await Verify(html, extension: "html");
}
```

**Benefits for email testing:**
- Catches CSS/layout regressions
- Detects broken template variables
- Visual review in diff tool
- Version control tracks email changes

---

## API Surface Approval

Prevent accidental breaking changes to public APIs:

```csharp
[Fact]
public Task ApprovePublicApi()
{
    var assembly = typeof(MyLibrary.PublicClass).Assembly;

    var publicApi = assembly.GetExportedTypes()
        .OrderBy(t => t.FullName)
        .Select(t => new
        {
            Type = t.FullName,
            Members = t.GetMembers(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static)
                .Where(m => m.DeclaringType == t)
                .OrderBy(m => m.Name)
                .Select(m => m.ToString())
        });

    return Verify(publicApi);
}
```

Or use the dedicated ApiApprover package:

```bash
dotnet add package PublicApiGenerator
dotnet add package Verify.Xunit
```

```csharp
[Fact]
public Task ApproveApi()
{
    var api = typeof(MyPublicClass).Assembly.GeneratePublicApi();
    return Verify(api);
}
```

Creates `.verified.txt` with full API surface - any change requires explicit approval.

---

## HTTP Response Testing

```csharp
[Fact]
public async Task GetUser_ReturnsExpectedResponse()
{
    var client = _factory.CreateClient();

    var response = await client.GetAsync("/api/users/123");

    // Verify status, headers, and body together
    await Verify(new
    {
        StatusCode = response.StatusCode,
        Headers = response.Headers
            .Where(h => h.Key.StartsWith("X-"))  // Custom headers only
            .ToDictionary(h => h.Key, h => h.Value.First()),
        Body = await response.Content.ReadAsStringAsync()
    });
}
```

---

## Scrubbing Dynamic Values

Handle timestamps, GUIDs, and other dynamic content:

```csharp
[Fact]
public Task VerifyOrder()
{
    var order = new Order
    {
        Id = Guid.NewGuid(),  // Different every run
        CreatedAt = DateTime.UtcNow,  // Different every run
        Total = 99.99m
    };

    return Verify(order)
        .ScrubMember("Id")  // Replace with placeholder
        .ScrubMember("CreatedAt");
}
```

Output:
```json
{
  Id: Guid_1,
  CreatedAt: DateTime_1,
  Total: 99.99
}
```

### Global Scrubbing

Configure in `ModuleInitializer`:

```csharp
[ModuleInitializer]
public static void Init()
{
    VerifierSettings.ScrubMembersWithType<DateTime>();
    VerifierSettings.ScrubMembersWithType<DateTimeOffset>();
    VerifierSettings.ScrubMembersWithType<Guid>();

    // Scrub specific patterns
    VerifierSettings.AddScrubber(s =>
        Regex.Replace(s, @"token=[a-zA-Z0-9]+", "token=SCRUBBED"));
}
```

---

## File Organization

### Recommended Structure

```
tests/
  MyApp.Tests/
    Snapshots/           # All verified files
      EmailTests/
        WelcomeEmail.verified.html
        PasswordReset.verified.html
      ApiTests/
        GetUser.verified.txt
    EmailTests.cs
    ApiTests.cs
    ModuleInitializer.cs
```

### .gitignore

```gitignore
# Verify - ignore received files (only commit verified)
*.received.*
```

### .gitattributes

```gitattributes
# Treat verified files as generated (collapse in PR diffs)
*.verified.txt linguist-generated=true
*.verified.html linguist-generated=true
*.verified.json linguist-generated=true
```

---

## CI/CD Integration

### Fail on Missing Verified Files

```csharp
[ModuleInitializer]
public static void Init()
{
    // In CI, fail instead of launching diff tool
    if (Environment.GetEnvironmentVariable("CI") == "true")
    {
        VerifyDiffPlex.UseDiffPlex(OutputType.Minimal);
        DiffRunner.Disabled = true;
    }
}
```

### GitHub Actions

```yaml
- name: Run tests
  run: dotnet test
  env:
    CI: true

- name: Upload snapshots on failure
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: snapshots
    path: |
      **/*.received.*
      **/*.verified.*
```

---

## When to Use Snapshot Testing

| Scenario | Use Snapshot Testing? | Why |
|----------|----------------------|-----|
| Rendered HTML/emails | Yes | Catches visual regressions |
| API surfaces | Yes | Prevents accidental breaks |
| Serialization output | Yes | Validates wire format |
| Complex object graphs | Yes | Easier than manual assertions |
| Simple value checks | No | Use regular assertions |
| Business logic | No | Use explicit assertions |
| Performance tests | No | Use benchmarks |

---

## Best Practices

### DO

```csharp
// Use descriptive test names - they become file names
[Fact]
public Task UserRegistration_WithValidData_ReturnsConfirmation()

// Scrub dynamic values consistently
VerifierSettings.ScrubMembersWithType<Guid>();

// Use extension parameter for non-text content
await Verify(html, extension: "html");

// Keep verified files in source control
git add *.verified.*
```

### DON'T

```csharp
// Don't verify random/dynamic data without scrubbing
var order = new Order { Id = Guid.NewGuid() };  // Fails every run!
await Verify(order);

// Don't commit .received files
git add *.received.*  // Wrong!

// Don't use for simple assertions
await Verify(result.Count);  // Just use Assert.Equal(5, result.Count)
```

---

## Integration with MJML Email Testing

See the `aspnetcore/transactional-emails` skill for the complete pattern:

1. MJML templates with `{{variable}}` placeholders
2. Render to HTML with test data
3. Snapshot test the rendered output
4. Review changes in diff tool before approving

This catches:
- Broken variable substitution
- CSS/layout regressions
- Email client compatibility issues
- Unintended content changes

---

## Resources

- **Verify GitHub**: https://github.com/VerifyTests/Verify
- **Verify.Xunit**: https://github.com/VerifyTests/Verify.Xunit
- **ApiApprover**: https://github.com/JakeGinnivan/ApiApprover
- **DiffPlex Integration**: https://github.com/VerifyTests/Verify.DiffPlex
