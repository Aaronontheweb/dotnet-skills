---
name: mailpit-integration
description: Test email sending locally using Mailpit with .NET Aspire. Captures all outgoing emails without sending them. View rendered HTML, inspect headers, and verify delivery in integration tests.
invocable: false
---

# Email Testing with Mailpit and .NET Aspire

## When to Use This Skill

Use this skill when:
- Testing email delivery locally without sending real emails
- Setting up email infrastructure in .NET Aspire
- Writing integration tests that verify emails are sent
- Debugging email rendering and headers

**Related skills:**
- `aspnetcore/mjml-email-templates` - MJML template authoring
- `testing/verify-email-snapshots` - Snapshot test rendered HTML
- `aspire/integration-testing` - General Aspire testing patterns

---

## What is Mailpit?

[Mailpit](https://github.com/axllent/mailpit) is a lightweight email testing tool that:
- Captures all SMTP traffic without delivering emails
- Provides a web UI to view captured emails
- Exposes an API for programmatic access
- Supports HTML rendering, headers, and attachments

Perfect for development and integration testing.

---

## Aspire AppHost Configuration

Add Mailpit as a container in your AppHost:

```csharp
// AppHost/Program.cs
var builder = DistributedApplication.CreateBuilder(args);

// Add Mailpit for email testing
var mailpit = builder.AddContainer("mailpit", "axllent/mailpit")
    .WithHttpEndpoint(port: 8025, targetPort: 8025, name: "ui")
    .WithEndpoint(port: 1025, targetPort: 1025, name: "smtp");

// Reference in your API project
var api = builder.AddProject<Projects.MyApp_Api>("api")
    .WithReference(mailpit.GetEndpoint("smtp"))
    .WithEnvironment("Smtp__Host", mailpit.GetEndpoint("smtp"));

builder.Build().Run();
```

---

## SMTP Configuration

### appsettings.json

```json
{
  "Smtp": {
    "Host": "localhost",
    "Port": 1025,
    "EnableSsl": false,
    "FromAddress": "noreply@myapp.com",
    "FromName": "MyApp"
  }
}
```

### Configuration Class

```csharp
public class SmtpSettings
{
    public string Host { get; set; } = "localhost";
    public int Port { get; set; } = 1025;
    public bool EnableSsl { get; set; } = false;
    public string FromAddress { get; set; } = "noreply@myapp.com";
    public string FromName { get; set; } = "MyApp";

    // Optional: For production SMTP
    public string? Username { get; set; }
    public string? Password { get; set; }
}
```

### Service Registration

```csharp
// In Program.cs or extension method
services.Configure<SmtpSettings>(configuration.GetSection("Smtp"));

services.AddSingleton<IEmailSender>(sp =>
{
    var settings = sp.GetRequiredService<IOptions<SmtpSettings>>().Value;
    return new SmtpEmailSender(settings);
});
```

---

## Email Sender Implementation

```csharp
public interface IEmailSender
{
    Task SendEmailAsync(EmailMessage message, CancellationToken ct = default);
}

public sealed class SmtpEmailSender : IEmailSender
{
    private readonly SmtpSettings _settings;

    public SmtpEmailSender(SmtpSettings settings)
    {
        _settings = settings;
    }

    public async Task SendEmailAsync(EmailMessage message, CancellationToken ct = default)
    {
        using var client = new SmtpClient();

        await client.ConnectAsync(
            _settings.Host,
            _settings.Port,
            _settings.EnableSsl ? SecureSocketOptions.StartTls : SecureSocketOptions.None,
            ct);

        if (!string.IsNullOrEmpty(_settings.Username))
        {
            await client.AuthenticateAsync(_settings.Username, _settings.Password, ct);
        }

        var mailMessage = new MimeMessage();
        mailMessage.From.Add(new MailboxAddress(_settings.FromName, _settings.FromAddress));
        mailMessage.To.Add(new MailboxAddress(message.ToName, message.To));
        mailMessage.Subject = message.Subject;

        var bodyBuilder = new BodyBuilder { HtmlBody = message.HtmlBody };
        mailMessage.Body = bodyBuilder.ToMessageBody();

        await client.SendAsync(mailMessage, ct);
        await client.DisconnectAsync(true, ct);
    }
}
```

Requires `MailKit` package:

```bash
dotnet add package MailKit
```

---

## Viewing Captured Emails

### Web UI

Navigate to `http://localhost:8025` to see:

- **Inbox** - All captured emails
- **HTML view** - Rendered email
- **Source view** - Raw HTML/MJML output
- **Headers** - Full email headers
- **Attachments** - Any attached files

### Aspire Dashboard

The Mailpit UI endpoint appears in the Aspire dashboard under Resources.

---

## Integration Testing

### Test Fixture with Aspire

```csharp
public class EmailIntegrationTests : IClassFixture<AspireFixture>
{
    private readonly HttpClient _client;
    private readonly MailpitClient _mailpit;

    public EmailIntegrationTests(AspireFixture fixture)
    {
        _client = fixture.CreateClient();
        _mailpit = new MailpitClient(fixture.GetMailpitUrl());
    }

    [Fact]
    public async Task SignupFlow_SendsWelcomeEmail()
    {
        // Arrange
        await _mailpit.ClearMessagesAsync();

        // Act - Trigger signup flow
        var response = await _client.PostAsJsonAsync("/api/auth/signup", new
        {
            Email = "test@example.com",
            Password = "SecurePassword123!"
        });
        response.EnsureSuccessStatusCode();

        // Assert - Verify email was sent
        var messages = await _mailpit.GetMessagesAsync();

        var welcomeEmail = messages.Should().ContainSingle()
            .Which;

        welcomeEmail.To.Should().Contain("test@example.com");
        welcomeEmail.Subject.Should().Contain("Welcome");
        welcomeEmail.HtmlBody.Should().Contain("Thank you for signing up");
    }
}
```

### Mailpit API Client

```csharp
public class MailpitClient
{
    private readonly HttpClient _client;

    public MailpitClient(string baseUrl)
    {
        _client = new HttpClient { BaseAddress = new Uri(baseUrl) };
    }

    public async Task<List<MailpitMessage>> GetMessagesAsync()
    {
        var response = await _client.GetFromJsonAsync<MailpitResponse>("/api/v1/messages");
        return response?.Messages ?? new List<MailpitMessage>();
    }

    public async Task ClearMessagesAsync()
    {
        await _client.DeleteAsync("/api/v1/messages");
    }

    public async Task<MailpitMessage?> WaitForMessageAsync(
        Func<MailpitMessage, bool> predicate,
        TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            var messages = await GetMessagesAsync();
            var match = messages.FirstOrDefault(predicate);

            if (match != null)
                return match;

            await Task.Delay(100);
        }

        return null;
    }
}

public class MailpitResponse
{
    public List<MailpitMessage> Messages { get; set; } = new();
}

public class MailpitMessage
{
    public string Id { get; set; } = "";
    public List<string> To { get; set; } = new();
    public string Subject { get; set; } = "";
    public string HtmlBody { get; set; } = "";
}
```

---

## Aspire Test Fixture

```csharp
public class AspireFixture : IAsyncLifetime
{
    private DistributedApplication? _app;
    private string _mailpitUrl = "";

    public async Task InitializeAsync()
    {
        var appHost = await DistributedApplicationTestingBuilder
            .CreateAsync<Projects.MyApp_AppHost>();

        // Disable persistence for clean tests
        appHost.Configuration["MyApp:UseVolumes"] = "false";

        _app = await appHost.BuildAsync();
        await _app.StartAsync();

        // Get Mailpit URL from Aspire
        var mailpit = _app.GetContainerResource("mailpit");
        _mailpitUrl = await mailpit.GetEndpointAsync("ui");
    }

    public HttpClient CreateClient()
    {
        var api = _app!.GetProjectResource("api");
        return api.CreateHttpClient();
    }

    public string GetMailpitUrl() => _mailpitUrl;

    public async Task DisposeAsync()
    {
        if (_app != null)
            await _app.DisposeAsync();
    }
}
```

---

## Common Test Patterns

### Wait for Async Email

Some emails are sent asynchronously. Wait for them:

```csharp
[Fact]
public async Task AsyncWorkflow_EventuallySendsEmail()
{
    await _mailpit.ClearMessagesAsync();

    // Trigger async workflow
    await _client.PostAsync("/api/workflows/start", null);

    // Wait for email (with timeout)
    var email = await _mailpit.WaitForMessageAsync(
        m => m.Subject.Contains("Workflow Complete"),
        timeout: TimeSpan.FromSeconds(10));

    email.Should().NotBeNull();
}
```

### Verify Multiple Emails

```csharp
[Fact]
public async Task BulkOperation_SendsMultipleEmails()
{
    await _mailpit.ClearMessagesAsync();

    await _client.PostAsJsonAsync("/api/invitations/bulk", new
    {
        Emails = new[] { "a@test.com", "b@test.com", "c@test.com" }
    });

    var messages = await _mailpit.WaitForMessagesAsync(
        expectedCount: 3,
        timeout: TimeSpan.FromSeconds(10));

    messages.Should().HaveCount(3);
    messages.Select(m => m.To.First())
        .Should().BeEquivalentTo("a@test.com", "b@test.com", "c@test.com");
}
```

### Verify Email Content

```csharp
[Fact]
public async Task PasswordReset_ContainsValidResetLink()
{
    await _mailpit.ClearMessagesAsync();

    await _client.PostAsJsonAsync("/api/auth/forgot-password", new
    {
        Email = "user@test.com"
    });

    var email = await _mailpit.WaitForMessageAsync(
        m => m.Subject.Contains("Password Reset"),
        timeout: TimeSpan.FromSeconds(5));

    // Extract reset link from HTML
    var resetLink = Regex.Match(email!.HtmlBody, @"href=""([^""]+/reset/[^""]+)""")
        .Groups[1].Value;

    resetLink.Should().StartWith("https://myapp.com/reset/");

    // Verify the link works
    var resetResponse = await _client.GetAsync(resetLink);
    resetResponse.StatusCode.Should().Be(HttpStatusCode.OK);
}
```

---

## Production vs Development

```csharp
services.AddSingleton<IEmailSender>(sp =>
{
    var settings = sp.GetRequiredService<IOptions<SmtpSettings>>().Value;
    var env = sp.GetRequiredService<IHostEnvironment>();

    if (env.IsDevelopment())
    {
        // Mailpit - no auth, no SSL
        return new SmtpEmailSender(settings);
    }
    else
    {
        // Production SMTP (SendGrid, Postmark, etc.)
        return new SmtpEmailSender(settings with
        {
            EnableSsl = true
        });
    }
});
```

---

## Troubleshooting

### Emails Not Appearing

1. Check Mailpit container is running in Aspire dashboard
2. Verify SMTP host/port configuration
3. Check for exceptions in application logs

### Connection Refused

```bash
# Verify Mailpit is listening
curl http://localhost:8025/api/v1/messages
```

### Aspire Endpoint Not Resolving

```csharp
// Ensure endpoint reference is correct
.WithEnvironment("Smtp__Host", mailpit.GetEndpoint("smtp").Property(EndpointProperty.Host))
.WithEnvironment("Smtp__Port", mailpit.GetEndpoint("smtp").Property(EndpointProperty.Port))
```

---

## Resources

- **Mailpit**: https://github.com/axllent/mailpit
- **Mailpit API**: https://mailpit.axllent.org/docs/api-v1/
- **MailKit**: https://github.com/jstedfast/MailKit
- **Aspire Containers**: https://learn.microsoft.com/en-us/dotnet/aspire/fundamentals/container-resources
