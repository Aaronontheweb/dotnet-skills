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

## Why Configuration Validation Matters

**The Problem:** Applications often fail at runtime due to misconfiguration - missing connection strings, invalid URLs, out-of-range values. These failures happen deep in business logic, far from where configuration is loaded, making debugging difficult.

**The Solution:** Validate configuration at startup. If configuration is invalid, the application fails immediately with a clear error message. This is the "fail fast" principle.

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
// In Program.cs or service registration
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

**Key Point:** `.ValidateOnStart()` is critical. Without it, validation only runs when the options are first accessed, which could be minutes or hours into application runtime.

---

## Pattern 3: IValidateOptions<T> for Complex Validation

Data Annotations work for simple rules, but complex validation requires `IValidateOptions<T>`:

### When to Use IValidateOptions

| Scenario | Data Annotations | IValidateOptions |
|----------|------------------|------------------|
| Required field | ✅ | ✅ |
| Range check | ✅ | ✅ |
| Regex pattern | ✅ | ✅ |
| Cross-property validation | ❌ | ✅ |
| Conditional validation | ❌ | ✅ |
| External service checks | ❌ | ✅ |
| Custom error messages with context | Limited | ✅ |
| Dependency injection in validator | ❌ | ✅ |

### Implementing IValidateOptions

```csharp
using Microsoft.Extensions.Options;

public class SmtpSettingsValidator : IValidateOptions<SmtpSettings>
{
    public ValidateOptionsResult Validate(string? name, SmtpSettings options)
    {
        var failures = new List<string>();

        // Required field validation
        if (string.IsNullOrWhiteSpace(options.Host))
        {
            failures.Add("Host is required");
        }

        // Range validation
        if (options.Port is < 1 or > 65535)
        {
            failures.Add($"Port {options.Port} is invalid. Must be between 1 and 65535");
        }

        // Cross-property validation
        if (!string.IsNullOrEmpty(options.Username) && string.IsNullOrEmpty(options.Password))
        {
            failures.Add("Password is required when Username is specified");
        }

        // Conditional validation
        if (options.UseSsl && options.Port == 25)
        {
            failures.Add("Port 25 is typically not used with SSL. Consider port 465 or 587");
        }

        // Return result
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
    .ValidateDataAnnotations()  // Run attribute validation first
    .ValidateOnStart();

// Register the custom validator
builder.Services.AddSingleton<IValidateOptions<SmtpSettings>, SmtpSettingsValidator>();
```

**Order matters:** Data Annotations run first, then IValidateOptions validators. All failures are collected and reported together.

---

## Pattern 4: Validators with Dependencies

IValidateOptions validators are resolved from DI, so they can have dependencies:

```csharp
public class DatabaseSettingsValidator : IValidateOptions<DatabaseSettings>
{
    private readonly ILogger<DatabaseSettingsValidator> _logger;
    private readonly IHostEnvironment _environment;

    public DatabaseSettingsValidator(
        ILogger<DatabaseSettingsValidator> logger,
        IHostEnvironment environment)
    {
        _logger = logger;
        _environment = environment;
    }

    public ValidateOptionsResult Validate(string? name, DatabaseSettings options)
    {
        var failures = new List<string>();

        if (string.IsNullOrWhiteSpace(options.ConnectionString))
        {
            failures.Add("ConnectionString is required");
        }

        // Environment-specific validation
        if (_environment.IsProduction())
        {
            if (options.ConnectionString?.Contains("localhost") == true)
            {
                failures.Add("Production cannot use localhost database");
            }

            if (!options.ConnectionString?.Contains("Encrypt=True") == true)
            {
                _logger.LogWarning("Production database connection should use encryption");
            }
        }

        // Validate connection string format
        if (!string.IsNullOrEmpty(options.ConnectionString))
        {
            try
            {
                var builder = new SqlConnectionStringBuilder(options.ConnectionString);
                if (string.IsNullOrEmpty(builder.DataSource))
                {
                    failures.Add("ConnectionString must specify a Data Source");
                }
            }
            catch (Exception ex)
            {
                failures.Add($"ConnectionString is malformed: {ex.Message}");
            }
        }

        return failures.Count > 0
            ? ValidateOptionsResult.Fail(failures)
            : ValidateOptionsResult.Success;
    }
}
```

---

## Pattern 5: Named Options

When you have multiple instances of the same settings type (e.g., multiple database connections):

```csharp
// appsettings.json
{
  "Databases": {
    "Primary": {
      "ConnectionString": "Server=primary;..."
    },
    "Replica": {
      "ConnectionString": "Server=replica;..."
    }
  }
}

// Registration
builder.Services.AddOptions<DatabaseSettings>("Primary")
    .BindConfiguration("Databases:Primary")
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddOptions<DatabaseSettings>("Replica")
    .BindConfiguration("Databases:Replica")
    .ValidateDataAnnotations()
    .ValidateOnStart();

// Consumption
public class DataService
{
    private readonly DatabaseSettings _primary;
    private readonly DatabaseSettings _replica;

    public DataService(IOptionsSnapshot<DatabaseSettings> options)
    {
        _primary = options.Get("Primary");
        _replica = options.Get("Replica");
    }
}
```

### Named Options Validator

```csharp
public class DatabaseSettingsValidator : IValidateOptions<DatabaseSettings>
{
    public ValidateOptionsResult Validate(string? name, DatabaseSettings options)
    {
        var failures = new List<string>();
        var prefix = string.IsNullOrEmpty(name) ? "" : $"[{name}] ";

        if (string.IsNullOrWhiteSpace(options.ConnectionString))
        {
            failures.Add($"{prefix}ConnectionString is required");
        }

        // Name-specific validation
        if (name == "Primary" && options.ReadOnly)
        {
            failures.Add("Primary database cannot be read-only");
        }

        return failures.Count > 0
            ? ValidateOptionsResult.Fail(failures)
            : ValidateOptionsResult.Success;
    }
}
```

---

## Pattern 6: Options Lifetime

Understanding the three options interfaces:

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

        // Subscribe to configuration changes
        _optionsMonitor.OnChange(settings =>
        {
            _currentSettings = settings;
            _logger.LogInformation("Worker settings updated: Interval={Interval}",
                settings.PollingInterval);
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

## Pattern 7: Post-Configuration

Modify options after binding but before validation:

```csharp
builder.Services.AddOptions<ApiSettings>()
    .BindConfiguration("Api")
    .PostConfigure(options =>
    {
        // Ensure BaseUrl ends with /
        if (!string.IsNullOrEmpty(options.BaseUrl) && !options.BaseUrl.EndsWith('/'))
        {
            options.BaseUrl += '/';
        }

        // Set defaults based on environment
        options.Timeout ??= TimeSpan.FromSeconds(30);
    })
    .ValidateDataAnnotations()
    .ValidateOnStart();
```

### PostConfigure with Dependencies

```csharp
builder.Services.AddOptions<ApiSettings>()
    .BindConfiguration("Api")
    .PostConfigure<IHostEnvironment>((options, env) =>
    {
        if (env.IsDevelopment())
        {
            options.Timeout = TimeSpan.FromMinutes(5); // Longer timeout for debugging
        }
    });
```

---

## Pattern 8: Complete Example - Production Settings Class

```csharp
using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.Options;

public class AkkaSettings
{
    public const string SectionName = "AkkaSettings";

    [Required]
    public string ActorSystemName { get; set; } = "MySystem";

    public AkkaExecutionMode ExecutionMode { get; set; } = AkkaExecutionMode.LocalTest;

    public bool LogConfigOnStart { get; set; } = false;

    public RemoteOptions RemoteOptions { get; set; } = new();

    public ClusterOptions ClusterOptions { get; set; } = new();

    public ClusterBootstrapOptions ClusterBootstrapOptions { get; set; } = new();
}

public enum AkkaExecutionMode
{
    LocalTest,   // No remoting, no clustering
    Clustered    // Full cluster with sharding, distributed pub/sub
}

public class AkkaSettingsValidator : IValidateOptions<AkkaSettings>
{
    private readonly IHostEnvironment _environment;

    public AkkaSettingsValidator(IHostEnvironment environment)
    {
        _environment = environment;
    }

    public ValidateOptionsResult Validate(string? name, AkkaSettings options)
    {
        var failures = new List<string>();

        // Basic validation
        if (string.IsNullOrWhiteSpace(options.ActorSystemName))
        {
            failures.Add("ActorSystemName is required");
        }

        // Mode-specific validation
        if (options.ExecutionMode == AkkaExecutionMode.Clustered)
        {
            ValidateClusteredMode(options, failures);
        }

        // Environment-specific validation
        if (_environment.IsProduction() && options.ExecutionMode == AkkaExecutionMode.LocalTest)
        {
            failures.Add("LocalTest execution mode is not allowed in production");
        }

        return failures.Count > 0
            ? ValidateOptionsResult.Fail(failures)
            : ValidateOptionsResult.Success;
    }

    private void ValidateClusteredMode(AkkaSettings options, List<string> failures)
    {
        if (string.IsNullOrEmpty(options.RemoteOptions.PublicHostName))
        {
            failures.Add("RemoteOptions.PublicHostName is required in Clustered mode");
        }

        if (options.RemoteOptions.Port is null or < 0)
        {
            failures.Add("RemoteOptions.Port must be >= 0 in Clustered mode");
        }

        if (options.ClusterBootstrapOptions.Enabled)
        {
            ValidateClusterBootstrap(options.ClusterBootstrapOptions, failures);
        }
        else if (options.ClusterOptions.SeedNodes?.Length == 0)
        {
            failures.Add("Either ClusterBootstrap must be enabled or SeedNodes must be specified");
        }
    }

    private void ValidateClusterBootstrap(ClusterBootstrapOptions options, List<string> failures)
    {
        if (string.IsNullOrEmpty(options.ServiceName))
        {
            failures.Add("ClusterBootstrapOptions.ServiceName is required");
        }

        if (options.RequiredContactPointsNr <= 0)
        {
            failures.Add("ClusterBootstrapOptions.RequiredContactPointsNr must be > 0");
        }

        switch (options.DiscoveryMethod)
        {
            case DiscoveryMethod.Config:
                if (options.ConfigServiceEndpoints?.Length == 0)
                {
                    failures.Add("ConfigServiceEndpoints required for Config discovery");
                }
                break;

            case DiscoveryMethod.AzureTableStorage:
                if (options.AzureDiscoveryOptions == null)
                {
                    failures.Add("AzureDiscoveryOptions required for Azure discovery");
                }
                break;
        }
    }
}

// Registration
builder.Services.AddOptions<AkkaSettings>()
    .BindConfiguration(AkkaSettings.SectionName)
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddSingleton<IValidateOptions<AkkaSettings>, AkkaSettingsValidator>();
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

// GOOD: Validation at startup
builder.Services.AddOptions<Settings>()
    .ValidateDataAnnotations()
    .ValidateOnStart();
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

## Testing Configuration Validators

```csharp
public class SmtpSettingsValidatorTests
{
    private readonly SmtpSettingsValidator _validator = new();

    [Fact]
    public void Validate_WithValidSettings_ReturnsSuccess()
    {
        var settings = new SmtpSettings
        {
            Host = "smtp.example.com",
            Port = 587,
            Username = "user@example.com",
            Password = "secret"
        };

        var result = _validator.Validate(null, settings);

        result.Succeeded.Should().BeTrue();
    }

    [Fact]
    public void Validate_WithMissingHost_ReturnsFail()
    {
        var settings = new SmtpSettings { Host = "" };

        var result = _validator.Validate(null, settings);

        result.Succeeded.Should().BeFalse();
        result.FailureMessage.Should().Contain("Host is required");
    }

    [Fact]
    public void Validate_WithUsernameButNoPassword_ReturnsFail()
    {
        var settings = new SmtpSettings
        {
            Host = "smtp.example.com",
            Username = "user@example.com",
            Password = null  // Missing!
        };

        var result = _validator.Validate(null, settings);

        result.Succeeded.Should().BeFalse();
        result.FailureMessage.Should().Contain("Password is required");
    }
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
