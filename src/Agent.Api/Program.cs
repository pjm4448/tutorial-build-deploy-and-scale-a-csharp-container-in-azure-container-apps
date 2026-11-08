using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "v1";
var defaultDelayMs = int.TryParse(
	Environment.GetEnvironmentVariable("AGENT_DEFAULT_DELAY_MS"),
	out var configuredDelay)
	? Math.Clamp(configuredDelay, 0, 30_000)
	: 500;

app.MapGet("/", () => Results.Ok(new
{
	service = "agent-api",
	version,
	message = "C# API running in Azure Container Apps - release v2"
}));

app.MapGet("/health", () => Results.Ok(new { status = "Healthy" }));

app.MapGet("/api/info", () => Results.Ok(new
{
	service = "agent-api",
	version,
	machine = Environment.MachineName,
	defaultDelayMs,
	framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription
}));

app.MapPost("/api/process", async (ProcessRequest? request, CancellationToken cancellationToken) =>
{
	var delayMs = Math.Clamp(request?.DelayMilliseconds ?? defaultDelayMs, 0, 30_000);
	var stopwatch = Stopwatch.StartNew();

	await Task.Delay(delayMs, cancellationToken);

	return Results.Ok(new ProcessResponse(
		request?.Prompt ?? "demo request",
		version,
		Environment.MachineName,
		delayMs,
		stopwatch.ElapsedMilliseconds));
});

app.Run();

public sealed record ProcessRequest(string? Prompt, int? DelayMilliseconds);

public sealed record ProcessResponse(
	string Prompt,
	string Version,
	string Machine,
	int RequestedDelayMilliseconds,
	long ElapsedMilliseconds);
