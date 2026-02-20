# Advanced Configuration Patterns

Validators with dependencies, named options, complete production example, and testing configuration validators.

## Contents

- [Validators with Dependencies](#validators-with-dependencies)
- [Named Options](#named-options)
- [Complete Example - Production Settings Class](#complete-example---production-settings-class)
- [Testing Configuration Validators](#testing-configuration-validators)

## Validators with Dependencies

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

## Named Options

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

## Complete Example - Production Settings Class

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
