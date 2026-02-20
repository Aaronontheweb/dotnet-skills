---
name: microsoft-extensions-configuration
description: Microsoft.Extensions.Options patterns including IValidateOptions, strongly-typed settings, validation on startup, and the Options pattern for clean configuration management.
invocable: false
---

# Microsoft.Extensions Configuration Patterns

## When to Use This Skill

Use this skill when:
- Binding configuration from appsettings.json to strongly-typed classes
- Validating configuration at application startup (fail fast)
- Implementing complex validation logic for settings
- Designing configuration classes that are testable and maintainable
- Understanding IOptions<T>, IOptionsSnapshot<T>, and IOptionsMonitor<T>

## Reference Files

- [advanced-patterns.md](advanced-patterns.md): Validators with dependencies, named options, complete production example (AkkaSettings), and testing validators

## Why Configuration Validation Matters

**The Problem:** Applications often fail at runtime due to misconfiguration - missing connection strings, invalid URLs, out-of-range values. These failures happen deep in business logic, far from where configuration is loaded.

**The Solution:** Validate configuration at startup. If invalid, fail immediately with a clear error message.

```csharp
// BAD: Fails at runtime when someone tries to use the service
public class EmailService
{
    public EmailService(IOptions<SmtpSettings> options)
    {
        var settings = options.Value;
        // Throws NullReferenceException 10 minutes into production
        _client = new SmtpClient(settings.Host, settings.Port);
    }
}

// GOOD: Fails at startup with clear error
// "SmtpSettings validation failed: Host is required"
```

---

## Pattern 1: Basic Options Binding

### Define a Settings Class

```csharp
public class SmtpSettings
{
    public const string SectionName = "Smtp";

    public string Host { get; set; } = string.Empty;
    public int Port { get; set; } = 587;
    public string? Username { get; set; }
    public string? Password { get; set; }
    public bool UseSsl { get; set; } = true;
}
```

### Bind from Configuration

```csharp
builder.Services.AddOptions<SmtpSettings>()
    .BindConfiguration(SmtpSettings.SectionName);

// appsettings.json
{
  "Smtp": {
    "Host": "smtp.example.com",
    "Port": 587,
    "Username": "user@example.com",
    "Password": "secret",
    "UseSsl": true
  }
}
```

### Consume in Services

```csharp
public class EmailService
{
    private readonly SmtpSettings _settings;

    // IOptions<T> - singleton, read once at startup
    public EmailService(IOptions<SmtpSettings> options)
    {
        _settings = options.Value;
    }
}
```

---

## Pattern 2: Data Annotations Validation

For simple validation rules, use Data Annotations:

```csharp
using System.ComponentModel.DataAnnotations;

public class SmtpSettings
{
    public const string SectionName = "Smtp";

    [Required(ErrorMessage = "SMTP host is required")]
    public string Host { get; set; } = string.Empty;

    [Range(1, 65535, ErrorMessage = "Port must be between 1 and 65535")]
    public int Port { get; set; } = 587;

    [EmailAddress(ErrorMessage = "Username must be a valid email address")]
    public string? Username { get; set; }

    public string? Password { get; set; }
    public bool UseSsl { get; set; } = true;
}
```

### Enable Data Annotations Validation

```csharp
builder.Services.AddOptions<SmtpSettings>()
    .BindConfiguration(SmtpSettings.SectionName)
    .ValidateDataAnnotations()  // Enable attribute-based validation
    .ValidateOnStart();         // Validate immediately at startup
```

**Key Point:** `.ValidateOnStart()` is critical. Without it, validation only runs when the options are first accessed.

---

## Pattern 3: IValidateOptions<T> for Complex Validation

Data Annotations work for simple rules, but complex validation requires `IValidateOptions<T>`:

| Scenario | Data Annotations | IValidateOptions |
|----------|------------------|------------------|
| Required field | Yes | Yes |
| Range check | Yes | Yes |
| Cross-property validation | No | Yes |
| Conditional validation | No | Yes |
| External service checks | No | Yes |
| Dependency injection in validator | No | Yes |

### Implementing IValidateOptions

```csharp
using Microsoft.Extensions.Options;

public class SmtpSettingsValidator : IValidateOptions<SmtpSettings>
{
    public ValidateOptionsResult Validate(string? name, SmtpSettings options)
    {
        var failures = new List<string>();

        if (string.IsNullOrWhiteSpace(options.Host))
            failures.Add("Host is required");

        if (options.Port is < 1 or > 65535)
            failures.Add($"Port {options.Port} is invalid. Must be between 1 and 65535");

        // Cross-property validation
        if (!string.IsNullOrEmpty(options.Username) && string.IsNullOrEmpty(options.Password))
            failures.Add("Password is required when Username is specified");

        // Conditional validation
        if (options.UseSsl && options.Port == 25)
            failures.Add("Port 25 is typically not used with SSL. Consider port 465 or 587");

        return failures.Count > 0
            ? ValidateOptionsResult.Fail(failures)
            : ValidateOptionsResult.Success;
    }
}
```

### Register the Validator

```csharp
builder.Services.AddOptions<SmtpSettings>()
    .BindConfiguration(SmtpSettings.SectionName)
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton<IValidateOptions<SmtpSettings>, SmtpSettingsValidator>();
```

**Order matters:** Data Annotations run first, then IValidateOptions validators. All failures are collected together.

See [advanced-patterns.md](advanced-patterns.md) for validators with dependencies, named options, and a complete production example.

---

## Pattern 4: Options Lifetime

| Interface | Lifetime | Reloads on Change | Use Case |
|-----------|----------|-------------------|----------|
| `IOptions<T>` | Singleton | No | Static config, read once |
| `IOptionsSnapshot<T>` | Scoped | Yes (per request) | Web apps needing fresh config |
| `IOptionsMonitor<T>` | Singleton | Yes (with callback) | Background services, real-time updates |

### IOptionsMonitor for Background Services

```csharp
public class BackgroundWorker : BackgroundService
{
    private readonly IOptionsMonitor<WorkerSettings> _optionsMonitor;
    private WorkerSettings _currentSettings;

    public BackgroundWorker(IOptionsMonitor<WorkerSettings> optionsMonitor)
    {
        _optionsMonitor = optionsMonitor;
        _currentSettings = optionsMonitor.CurrentValue;

        _optionsMonitor.OnChange(settings =>
        {
            _currentSettings = settings;
        });
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            await DoWorkAsync();
            await Task.Delay(_currentSettings.PollingInterval, stoppingToken);
        }
    }
}
```

---

## Pattern 5: Post-Configuration

Modify options after binding but before validation:

```csharp
builder.Services.AddOptions<ApiSettings>()
    .BindConfiguration("Api")
    .PostConfigure(options =>
    {
        if (!string.IsNullOrEmpty(options.BaseUrl) && !options.BaseUrl.EndsWith('/'))
            options.BaseUrl += '/';

        options.Timeout ??= TimeSpan.FromSeconds(30);
    })
    .ValidateDataAnnotations()
    .ValidateOnStart();
```

---

## Anti-Patterns to Avoid

### 1. Manual Configuration Access

```csharp
// BAD: Bypasses validation, hard to test
public class MyService
{
    public MyService(IConfiguration configuration)
    {
        var host = configuration["Smtp:Host"]; // No validation!
    }
}

// GOOD: Strongly-typed, validated
public class MyService
{
    public MyService(IOptions<SmtpSettings> options)
    {
        var host = options.Value.Host; // Validated at startup
    }
}
```

### 2. Validation in Constructor

```csharp
// BAD: Validation happens at runtime, not startup
public class MyService
{
    public MyService(IOptions<Settings> options)
    {
        if (string.IsNullOrEmpty(options.Value.Required))
            throw new ArgumentException("Required is missing"); // Too late!
    }
}

// GOOD: Validation at startup via IValidateOptions + ValidateOnStart()
```

### 3. Forgetting ValidateOnStart

```csharp
// BAD: Validation only runs when first accessed
builder.Services.AddOptions<Settings>()
    .ValidateDataAnnotations(); // Missing ValidateOnStart!

// GOOD: Fails immediately if invalid
builder.Services.AddOptions<Settings>()
    .ValidateDataAnnotations()
    .ValidateOnStart();
```

### 4. Throwing in IValidateOptions

```csharp
// BAD: Throws exception, breaks validation chain
public ValidateOptionsResult Validate(string? name, Settings options)
{
    if (options.Value < 0)
        throw new ArgumentException("Value cannot be negative"); // Wrong!
    return ValidateOptionsResult.Success;
}

// GOOD: Return failure result
public ValidateOptionsResult Validate(string? name, Settings options)
{
    if (options.Value < 0)
        return ValidateOptionsResult.Fail("Value cannot be negative");
    return ValidateOptionsResult.Success;
}
```

---

## Summary

| Principle | Implementation |
|-----------|----------------|
| Fail fast | `.ValidateOnStart()` |
| Strongly-typed | Bind to POCO classes |
| Simple validation | Data Annotations |
| Complex validation | `IValidateOptions<T>` |
| Cross-property rules | `IValidateOptions<T>` |
| Environment-aware | Inject `IHostEnvironment` |
| Testable | Validators are plain classes |
