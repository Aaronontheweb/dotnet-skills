---
name: mjml-email-templates
description: Build responsive email templates using MJML markup language. Compiles to cross-client HTML that works in Outlook, Gmail, and Apple Mail. Includes template renderer, layout patterns, and variable substitution.
invocable: false
---

# MJML Email Templates

## When to Use This Skill

Use this skill when:
- Building transactional emails (signup, password reset, invoices, notifications)
- Creating responsive email templates that work across clients
- Setting up MJML template rendering in .NET

**Related skills:**
- `aspire/mailpit-integration` - Test emails locally with Mailpit
- `testing/verify-email-snapshots` - Snapshot test rendered HTML

---

## Why MJML?

**Problem**: Email HTML is notoriously difficult. Each email client (Outlook, Gmail, Apple Mail) renders differently, requiring complex table-based layouts and inline styles.

**Solution**: [MJML](https://mjml.io/) is a markup language that compiles to responsive, cross-client HTML:

```mjml
<!-- MJML - simple and readable -->
<mj-section>
  <mj-column>
    <mj-text>Hello {{UserName}}</mj-text>
    <mj-button href="{{ActionUrl}}">Click Here</mj-button>
  </mj-column>
</mj-section>
```

Compiles to ~200 lines of table-based HTML with inline styles that works everywhere.

---

## Installation

### Add Mjml.Net

```bash
dotnet add package Mjml.Net
```

### Embed Templates as Resources

In your `.csproj`:

```xml
<ItemGroup>
  <EmbeddedResource Include="Templates\**\*.mjml" />
</ItemGroup>
```

---

## Project Structure

```
src/
  Infrastructure/
    MyApp.Infrastructure.Mailing/
      Templates/
        _Layout.mjml              # Shared layout (header, footer)
        UserInvitations/
          UserSignupInvitation.mjml
          InvitationExpired.mjml
        PasswordReset/
          PasswordReset.mjml
        Billing/
          PaymentReceipt.mjml
          RenewalReminder.mjml
      Mjml/
        IMjmlTemplateRenderer.cs
        MjmlTemplateRenderer.cs
        MjmlEmailMessage.cs
      Composers/
        IUserEmailComposer.cs
        UserEmailComposer.cs
      MyApp.Infrastructure.Mailing.csproj
```

---

## Layout Template (_Layout.mjml)

```mjml
<mjml>
  <mj-head>
    <mj-title>MyApp</mj-title>
    <mj-preview>{{PreviewText}}</mj-preview>
    <mj-attributes>
      <mj-all font-family="'Helvetica Neue', Helvetica, Arial, sans-serif" />
      <mj-text font-size="14px" color="#555555" line-height="20px" />
      <mj-section padding="20px" />
    </mj-attributes>
    <mj-style inline="inline">
      a { color: #2563eb; text-decoration: none; }
      a:hover { text-decoration: underline; }
    </mj-style>
  </mj-head>
  <mj-body background-color="#f3f4f6">
    <!-- Header -->
    <mj-section background-color="#ffffff" padding-bottom="0">
      <mj-column>
        <mj-image
          src="https://myapp.com/logo.png"
          alt="MyApp"
          width="150px"
          href="{{SiteUrl}}"
          padding="30px 25px 20px 25px" />
      </mj-column>
    </mj-section>

    <!-- Content injected here -->
    <mj-section background-color="#ffffff" padding-top="20px" padding-bottom="40px">
      <mj-column>
        {{Content}}
      </mj-column>
    </mj-section>

    <!-- Footer -->
    <mj-section background-color="#f9fafb" padding="20px 25px">
      <mj-column>
        <mj-text align="center" font-size="12px" color="#9ca3af">
          &copy; 2025 MyApp Inc. All rights reserved.
        </mj-text>
      </mj-column>
    </mj-section>
  </mj-body>
</mjml>
```

---

## Content Template

```mjml
<!-- UserInvitations/UserSignupInvitation.mjml -->
<!-- Wrapped in _Layout.mjml automatically -->

<mj-text font-size="16px" color="#111827" font-weight="600" padding-bottom="20px">
  You've been invited to join {{OrganizationName}}
</mj-text>

<mj-text padding-bottom="15px">
  Hi {{InviteeName}},
</mj-text>

<mj-text padding-bottom="15px">
  {{InviterName}} has invited you to join <strong>{{OrganizationName}}</strong>.
</mj-text>

<mj-text padding-bottom="25px">
  Click the button below to accept your invitation:
</mj-text>

<mj-button background-color="#2563eb" color="#ffffff" font-size="16px" href="{{InvitationLink}}">
  Accept Invitation
</mj-button>

<mj-text padding-top="25px" font-size="13px" color="#6b7280">
  This invitation expires on {{ExpirationDate}}.
</mj-text>
```

---

## Template Renderer

```csharp
public interface IMjmlTemplateRenderer
{
    Task<string> RenderTemplateAsync(
        string templateName,
        IReadOnlyDictionary<string, string> variables,
        CancellationToken ct = default);
}

public sealed partial class MjmlTemplateRenderer : IMjmlTemplateRenderer
{
    private readonly MjmlRenderer _mjmlRenderer = new();
    private readonly Assembly _assembly;
    private readonly string _siteUrl;

    public MjmlTemplateRenderer(IConfiguration config)
    {
        _assembly = typeof(MjmlTemplateRenderer).Assembly;
        _siteUrl = config["SiteUrl"] ?? "https://myapp.com";
    }

    public async Task<string> RenderTemplateAsync(
        string templateName,
        IReadOnlyDictionary<string, string> variables,
        CancellationToken ct = default)
    {
        // Load content template
        var contentMjml = await LoadTemplateAsync(templateName, ct);

        // Load layout and inject content
        var layoutMjml = await LoadTemplateAsync("_Layout", ct);
        var combinedMjml = layoutMjml.Replace("{{Content}}", contentMjml);

        // Merge variables (layout + template-specific)
        var allVariables = new Dictionary<string, string>
        {
            { "SiteUrl", _siteUrl }
        };
        foreach (var kvp in variables)
            allVariables[kvp.Key] = kvp.Value;

        // Substitute variables
        var processedMjml = SubstituteVariables(combinedMjml, allVariables);

        // Compile to HTML
        var result = await _mjmlRenderer.RenderAsync(processedMjml, null, ct);

        if (result.Errors.Any())
            throw new InvalidOperationException(
                $"MJML compilation failed: {string.Join(", ", result.Errors.Select(e => e.Error))}");

        return result.Html;
    }

    private async Task<string> LoadTemplateAsync(string templateName, CancellationToken ct)
    {
        var resourceName = $"MyApp.Infrastructure.Mailing.Templates.{templateName.Replace('/', '.')}.mjml";

        await using var stream = _assembly.GetManifestResourceStream(resourceName)
            ?? throw new FileNotFoundException($"Template '{templateName}' not found");

        using var reader = new StreamReader(stream);
        return await reader.ReadToEndAsync(ct);
    }

    private static string SubstituteVariables(string mjml, IReadOnlyDictionary<string, string> variables)
    {
        return VariableRegex().Replace(mjml, match =>
        {
            var name = match.Groups[1].Value;
            return variables.TryGetValue(name, out var value) ? value : match.Value;
        });
    }

    [GeneratedRegex(@"\{\{([^}]+)\}\}", RegexOptions.Compiled)]
    private static partial Regex VariableRegex();
}
```

---

## Email Composer Pattern

Separate template rendering from email composition with strongly-typed value objects:

```csharp
public interface IUserEmailComposer
{
    Task<EmailMessage> ComposeSignupInvitationAsync(
        EmailAddress recipientEmail,
        PersonName recipientName,
        PersonName inviterName,
        OrganizationName organizationName,
        AbsoluteUri invitationUrl,
        DateTimeOffset expiresAt,
        CancellationToken ct = default);
}

public sealed class UserEmailComposer : IUserEmailComposer
{
    private readonly IMjmlTemplateRenderer _renderer;

    public UserEmailComposer(IMjmlTemplateRenderer renderer)
    {
        _renderer = renderer;
    }

    public async Task<EmailMessage> ComposeSignupInvitationAsync(
        EmailAddress recipientEmail,
        PersonName recipientName,
        PersonName inviterName,
        OrganizationName organizationName,
        AbsoluteUri invitationUrl,
        DateTimeOffset expiresAt,
        CancellationToken ct = default)
    {
        var variables = new Dictionary<string, string>
        {
            { "PreviewText", $"You've been invited to join {organizationName.Value}" },
            { "InviteeName", recipientName.Value },
            { "InviterName", inviterName.Value },
            { "OrganizationName", organizationName.Value },
            { "InvitationLink", invitationUrl.ToString() },
            { "ExpirationDate", expiresAt.ToString("MMMM d, yyyy") }
        };

        var html = await _renderer.RenderTemplateAsync(
            "UserInvitations/UserSignupInvitation",
            variables,
            ct);

        return new EmailMessage(
            To: recipientEmail,
            Subject: $"You've been invited to join {organizationName.Value}",
            HtmlBody: html);
    }
}
```

---

## Email Preview Endpoint

Add an admin endpoint to preview emails during development:

```csharp
app.MapGet("/admin/emails/preview/{template}", async (
    string template,
    IMjmlTemplateRenderer renderer) =>
{
    var sampleVariables = GetSampleVariables(template);
    var html = await renderer.RenderTemplateAsync(template, sampleVariables);

    return Results.Content(html, "text/html");
})
.RequireAuthorization("AdminOnly");
```

---

## Best Practices

### Template Design

```mjml
<!-- DO: Use MJML components for layout -->
<mj-section>
  <mj-column>
    <mj-text>Content</mj-text>
  </mj-column>
</mj-section>

<!-- DON'T: Use raw HTML tables -->
<table><tr><td>Content</td></tr></table>

<!-- DO: Use production URLs for images -->
<mj-image src="https://myapp.com/logo.png" />

<!-- DON'T: Use relative paths -->
<mj-image src="/img/logo.png" />
```

### Variable Handling

```csharp
// DO: Use strongly-typed value objects
Task<EmailMessage> ComposeAsync(
    EmailAddress to,
    PersonName name,
    AbsoluteUri actionUrl);

// DON'T: Use raw strings
Task<EmailMessage> ComposeAsync(
    string email,
    string name,
    string url);
```

---

## MJML Components Reference

| Component | Purpose |
|-----------|---------|
| `<mj-section>` | Horizontal container (like a row) |
| `<mj-column>` | Vertical container within section |
| `<mj-text>` | Text content with styling |
| `<mj-button>` | Call-to-action button |
| `<mj-image>` | Responsive image |
| `<mj-divider>` | Horizontal line |
| `<mj-spacer>` | Vertical spacing |
| `<mj-table>` | Data tables |
| `<mj-social>` | Social media icons |

---

## Resources

- **MJML Documentation**: https://documentation.mjml.io/
- **MJML Playground**: https://mjml.io/try-it-live
- **Mjml.Net**: https://github.com/ArtZab/Mjml.Net
