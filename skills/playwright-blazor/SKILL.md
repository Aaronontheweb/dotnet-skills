---
name: playwright-blazor-testing
description: Write UI tests for Blazor applications (Server or WebAssembly) using Playwright. Covers navigation, interaction, authentication, selectors, and common Blazor-specific patterns.
invocable: false
---

# Testing Blazor Applications with Playwright

## When to Use This Skill

Use this skill when:
- Writing end-to-end UI tests for Blazor Server or WebAssembly applications
- Testing interactive components, forms, and user workflows
- Verifying authentication and authorization flows
- Testing SignalR-based real-time updates in Blazor Server
- Capturing screenshots for visual regression testing
- Testing responsive designs and mobile emulation
- Debugging UI issues with browser developer tools

## Core Principles

1. **Wait for Rendering** - Blazor renders asynchronously; use proper wait strategies
2. **Test Attributes** - Use `data-test` or `data-testid` attributes for stable selectors
3. **Headless by Default** - Run tests headless in CI, headed for local debugging
4. **Handle Error UI** - Always check for `#blazor-error-ui` to catch unhandled exceptions
5. **Avoid Network Wait States** - Blazor navigation doesn't trigger network loads; wait for DOM changes
6. **Pin Browser Channels** - Use specific browser channels (msedge, chrome) for reproducibility

## Required NuGet Packages

```xml
<ItemGroup>
  <PackageReference Include="Microsoft.Playwright" Version="*" />
  <PackageReference Include="Microsoft.Playwright.MSTest" Version="*" />
  <!-- OR for xUnit -->
  <PackageReference Include="xunit" Version="*" />
  <PackageReference Include="xunit.runner.visualstudio" Version="*" />
</ItemGroup>
```

## Installation

Before running tests, install Playwright browsers:

```bash
pwsh -Command "playwright install --with-deps"
```

## Pattern 1: Basic Playwright Setup

```csharp
using Microsoft.Playwright;

public class PlaywrightFixture : IAsyncLifetime
{
    private IPlaywright? _playwright;
    private IBrowser? _browser;

    public IBrowser Browser => _browser
        ?? throw new InvalidOperationException("Browser not initialized");

    public async Task InitializeAsync()
    {
        _playwright = await Playwright.CreateAsync();

        _browser = await _playwright.Chromium.LaunchAsync(new()
        {
            Headless = true,
            // For CI/debugging, you might want:
            // Headless = Environment.GetEnvironmentVariable("CI") != null,
            // SlowMo = 100 // Slow down actions for debugging
        });
    }

    public async Task DisposeAsync()
    {
        if (_browser is not null)
            await _browser.DisposeAsync();

        _playwright?.Dispose();
    }
}
```

## Pattern 2: Navigation in Blazor Apps

### Initial Page Load (Classic Navigation)

```csharp
[Fact]
public async Task InitialPageLoad()
{
    var page = await _fixture.Browser.NewPageAsync();

    // First load is classic HTTP navigation
    await page.GotoAsync("https://localhost:5001");

    // Wait for Blazor to initialize
    await page.WaitForSelectorAsync("h1:has-text('Welcome')");

    Assert.True(await page.IsVisibleAsync("h1:has-text('Welcome')"));
}
```

### In-App Navigation (No Page Reload)

Blazor uses client-side routing, so subsequent navigations don't trigger page reloads:

```csharp
[Fact]
public async Task InternalNavigation()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync("https://localhost:5001");

    // Method 1: Click a navigation link
    await page.GetByRole(AriaRole.Link, new() { Name = "Counter" })
        .ClickAsync();

    // Wait for the new page content (NOT network idle!)
    await page.WaitForSelectorAsync("h1:has-text('Counter')");

    // Method 2: Programmatic navigation (Blazor 8+)
    await page.EvaluateAsync("window.Blazor.navigateTo('/fetchdata')");
    await page.WaitForSelectorAsync("h1:has-text('Weather')");

    // Method 3: Direct URL navigation (causes full reload)
    await page.GotoAsync("https://localhost:5001/counter");
    await page.WaitForSelectorAsync("h1:has-text('Counter')");
}
```

### Wait Strategies for Blazor

```csharp
// ❌ DON'T: Wait for network idle (Blazor doesn't reload pages)
await page.WaitForLoadStateAsync(LoadState.NetworkIdle);

// ✅ DO: Wait for specific DOM elements
await page.WaitForSelectorAsync("h1:has-text('My Page')");

// ✅ DO: Wait for element visibility
await page.Locator("[data-test='content']").WaitForAsync();

// ✅ DO: Wait for URL change
await page.WaitForURLAsync("**/counter");
```

## Pattern 3: Stable Selectors with Test Attributes

### In Your Blazor Components

```razor
<!-- Add data-test attributes for stable selectors -->
<button data-test="submit-button" @onclick="HandleSubmit">
    Submit
</button>

<input data-test="username-input" @bind="Username" />

<div data-test="result-container">
    @Result
</div>
```

### In Your Tests

```csharp
[Fact]
public async Task FormSubmission()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync(baseUrl);

    // Use GetByTestId for elements with data-test attributes
    await page.GetByTestId("username-input").FillAsync("testuser");
    await page.GetByTestId("password-input").FillAsync("password123");
    await page.GetByTestId("submit-button").ClickAsync();

    // Verify result
    var result = await page.GetByTestId("result-container").TextContentAsync();
    Assert.Contains("Success", result);
}
```

## Pattern 4: Handling Authentication

### Interactive Login

```csharp
[Fact]
public async Task LoginFlow()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync($"{baseUrl}/login");

    // Fill login form
    await page.FillAsync("input[name='username']", "alice");
    await page.FillAsync("input[name='password']", "P@ssw0rd");
    await page.ClickAsync("button[type='submit']");

    // Wait for redirect to dashboard
    await page.WaitForURLAsync("**/dashboard");

    // Verify logged in
    var username = await page.TextContentAsync("[data-test='user-name']");
    Assert.Equal("alice", username);
}
```

### Cookie Injection (Faster)

```csharp
[Fact]
public async Task AuthenticatedAccess_ViaCookie()
{
    var page = await _fixture.Browser.NewPageAsync();

    // Inject authentication cookie
    await page.Context.AddCookiesAsync(new[]
    {
        new Cookie
        {
            Name = ".AspNetCore.Cookies",
            Value = GenerateAuthCookie("alice"),
            Url = baseUrl,
            Secure = true,
            HttpOnly = true
        }
    });

    // Navigate directly to protected page
    await page.GotoAsync($"{baseUrl}/dashboard");

    // Already authenticated!
    var username = await page.TextContentAsync("[data-test='user-name']");
    Assert.Equal("alice", username);
}

private string GenerateAuthCookie(string username)
{
    // Generate a valid authentication cookie
    // This requires access to your app's cookie encryption keys
    // OR use a test endpoint that generates valid cookies
    // OR perform actual login once and reuse the cookie
}
```

### OAuth/External Provider Mocking

```csharp
// Use route interception to mock OAuth redirects
await page.RouteAsync("**/signin-microsoft", async route =>
{
    // Intercept OAuth redirect and return mock response
    await route.FulfillAsync(new()
    {
        Status = 302,
        Headers = new Dictionary<string, string>
        {
            ["Location"] = $"{baseUrl}/signin-callback?code=mock_auth_code"
        }
    });
});
```

## Pattern 5: Click Events and Touch Interactions

```csharp
[Fact]
public async Task ClickInteractions()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync(baseUrl);

    // Standard click
    await page.GetByText("Click Me").ClickAsync();

    // Right-click
    await page.ClickAsync("[data-test='context-menu']", new()
    {
        Button = MouseButton.Right
    });

    // Double-click
    await page.DblClickAsync("[data-test='item']");

    // Hover then click dropdown
    var menu = page.Locator("#profile-menu");
    await menu.HoverAsync();
    await menu.GetByText("Sign out").ClickAsync();

    // Touch events (mobile emulation)
    await page.EmulateMediaAsync(new() { Media = Media.Screen });
    await page.Touchscreen.TapAsync(150, 300);
}
```

## Pattern 6: Form Handling

```csharp
[Fact]
public async Task ComplexForm()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync($"{baseUrl}/form");

    // Text input
    await page.FillAsync("[data-test='name']", "John Doe");

    // Select dropdown
    await page.SelectOptionAsync("[data-test='country']", "US");

    // Checkbox
    await page.CheckAsync("[data-test='terms']");

    // Radio button
    await page.CheckAsync("[data-test='option-a']");

    // File upload
    await page.SetInputFilesAsync("[data-test='file-input']",
        "/path/to/test-file.pdf");

    // Submit
    await page.ClickAsync("[data-test='submit']");

    // Wait for success message
    await page.WaitForSelectorAsync("[data-test='success-message']");
}
```

## Pattern 7: Handling Blazor Error UI

Blazor shows an error overlay when unhandled exceptions occur. Always check for this:

```csharp
public static async Task AssertNoBlazorErrors(this IPage page)
{
    var errorUi = page.Locator("#blazor-error-ui");

    if (await errorUi.IsVisibleAsync())
    {
        var errorText = await errorUi.InnerTextAsync();
        Assert.Fail($"Blazor error occurred: {errorText}");
    }
}

[Fact]
public async Task Page_ShouldNotHaveErrors()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync(baseUrl);

    // Perform some actions
    await page.ClickAsync("[data-test='action-button']");

    // Verify no errors occurred
    await page.AssertNoBlazorErrors();
}
```

## Pattern 8: Testing Real-Time Updates (SignalR)

Blazor Server uses SignalR for real-time communication:

```csharp
[Fact]
public async Task RealTimeUpdates()
{
    // Open two browser contexts (simulating two users)
    var page1 = await _fixture.Browser.NewPageAsync();
    var page2 = await _fixture.Browser.NewPageAsync();

    await page1.GotoAsync($"{baseUrl}/drawing");
    await page2.GotoAsync($"{baseUrl}/drawing");

    // User 1 draws something
    await page1.ClickAsync("[data-test='draw-button']");
    await page1.Mouse.ClickAsync(100, 100);

    // User 2 should see the update
    await page2.WaitForSelectorAsync("[data-test='drawing-canvas']");

    // Verify both pages show the same content
    var canvas1 = await page1.GetByTestId("drawing-canvas")
        .GetAttributeAsync("data-strokes");
    var canvas2 = await page2.GetByTestId("drawing-canvas")
        .GetAttributeAsync("data-strokes");

    Assert.Equal(canvas1, canvas2);
}
```

## Pattern 9: Screenshot and Visual Testing

```csharp
[Fact]
public async Task CaptureScreenshots()
{
    var page = await _fixture.Browser.NewPageAsync();
    await page.GotoAsync(baseUrl);

    // Full page screenshot
    await page.ScreenshotAsync(new()
    {
        Path = "screenshots/homepage.png",
        FullPage = true
    });

    // Element screenshot
    var header = page.Locator("header");
    await header.ScreenshotAsync(new()
    {
        Path = "screenshots/header.png"
    });

    // Screenshot with viewport size
    await page.SetViewportSizeAsync(1920, 1080);
    await page.ScreenshotAsync(new()
    {
        Path = "screenshots/desktop.png"
    });

    // Mobile viewport
    await page.SetViewportSizeAsync(375, 667);
    await page.ScreenshotAsync(new()
    {
        Path = "screenshots/mobile.png"
    });
}
```

## Pattern 10: Running Against HTTPS with Dev Certs

```csharp
public async Task InitializeAsync()
{
    _playwright = await Playwright.CreateAsync();

    _browser = await _playwright.Chromium.LaunchAsync(new()
    {
        Headless = true,
        // Ignore certificate errors for local dev certs
        Args = new[] { "--ignore-certificate-errors" }
    });
}
```

For stricter setups, export and trust the dev certificate:

```bash
dotnet dev-certs https --export-path cert.pfx -p YourPassword
```

## Common Selectors for Blazor Components

```csharp
// By role (best for accessibility)
await page.GetByRole(AriaRole.Button, new() { Name = "Submit" });
await page.GetByRole(AriaRole.Link, new() { Name = "Home" });
await page.GetByRole(AriaRole.Heading, new() { Name = "Welcome" });

// By test ID
await page.GetByTestId("user-profile");

// By text content
await page.GetByText("Hello, World!");

// By label (for inputs)
await page.GetByLabel("Email Address");

// By placeholder
await page.GetByPlaceholder("Enter your name");

// CSS selectors (use sparingly)
await page.Locator(".mud-button-primary");
await page.Locator("#login-form");

// XPath (use as last resort)
await page.Locator("xpath=//button[contains(text(), 'Submit')]");
```

## Parallelization Considerations

Blazor Server uses SignalR websockets. Multiple Playwright tests can saturate connections:

```csharp
// Limit parallel execution for Blazor Server tests
[Collection("Blazor Server")]
public class BlazorServerTests { }

// In AssemblyInfo.cs or test startup
[assembly: CollectionBehavior(MaxParallelThreads = 2)]
```

Blazor WebAssembly doesn't have this limitation and can run fully parallel.

## CI/CD Integration

### GitHub Actions

```yaml
name: Playwright Tests

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

    - name: Install Playwright Browsers
      run: pwsh -Command "playwright install --with-deps"

    - name: Build
      run: dotnet build -c Release

    - name: Run Playwright Tests
      run: |
        dotnet test tests/YourApp.UITests \
          --no-build \
          -c Release \
          --logger trx

    - name: Upload Screenshots
      uses: actions/upload-artifact@v3
      if: failure()
      with:
        name: playwright-screenshots
        path: "**/screenshots/"

    - name: Upload Test Results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: test-results
        path: "**/TestResults/*.trx"
```

## Debugging Tips

1. **Run Headed** - Set `Headless = false` to watch tests execute
2. **Slow Motion** - Add `SlowMo = 500` to slow down actions
3. **Pause Execution** - Call `await page.PauseAsync()` to open Playwright Inspector
4. **Console Logs** - Capture browser console: `page.Console += (_, msg) => Console.WriteLine(msg.Text);`
5. **Network Traffic** - Monitor requests: `page.Request += (_, req) => Console.WriteLine(req.Url);`
6. **Screenshots on Failure** - Always capture screenshots in catch blocks

## Best Practices

1. **Use data-test attributes** - More stable than CSS classes or IDs
2. **Prefer semantic selectors** - Use roles, labels, and text content
3. **Wait for specific elements** - Don't use blanket delays
4. **Check for Blazor errors** - Always verify `#blazor-error-ui` is not visible
5. **Test with multiple viewports** - Verify responsive design
6. **Reuse browser contexts** - Faster than creating new browsers
7. **Clean up resources** - Always dispose pages and browsers
8. **Use collections for Blazor Server** - Avoid SignalR connection saturation
9. **Capture screenshots on failure** - Essential for debugging CI failures
10. **Pin browser channels** - Use specific channels for reproducibility

## Advanced: Custom Wait Helpers

```csharp
public static class PlaywrightExtensions
{
    public static async Task WaitForBlazorAsync(this IPage page)
    {
        // Wait for Blazor to finish rendering
        await page.EvaluateAsync(@"
            () => new Promise(resolve => {
                if (typeof Blazor !== 'undefined') {
                    resolve();
                } else {
                    const interval = setInterval(() => {
                        if (typeof Blazor !== 'undefined') {
                            clearInterval(interval);
                            resolve();
                        }
                    }, 100);
                }
            })
        ");
    }

    public static async Task WaitForNoSpinnersAsync(
        this IPage page,
        int timeout = 5000)
    {
        var locator = page.Locator(".spinner, .loading");
        await locator.WaitForAsync(new()
        {
            State = WaitForSelectorState.Hidden,
            Timeout = timeout
        });
    }

    public static async Task FillWithValidationAsync(
        this IPage page,
        string selector,
        string value)
    {
        await page.FillAsync(selector, value);

        // Trigger blur to activate validation
        await page.Locator(selector).BlurAsync();

        // Wait a bit for validation to complete
        await Task.Delay(100);
    }
}
```
