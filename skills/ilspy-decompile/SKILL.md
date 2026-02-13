---
name: ilspy-decompile
description: Understand implementation details of .NET code by decompiling assemblies. Use when you want to see how a .NET API works internally, inspect NuGet package source, view framework implementation, or understand compiled .NET binaries.
allowed-tools: Bash(dnx:*)
---

# .NET Assembly Decompilation with ILSpy

Use this skill to understand how .NET code works internally by decompiling compiled assemblies.

## Prerequisites

- .NET SDK installed
- ILSpy command-line tool available via one of the following:
  - `dnx ilspycmd` (if available in your SDK or runtime)
  - `dotnet tool install --global ilspycmd`

Both forms are shown below. Use the one that works in your environment.

> Note: ILSpyCmd options may vary slightly by version.  
> Always verify supported flags with `ilspycmd -h`.

## Quick start

```bash
# Decompile an assembly to stdout
ilspycmd MyLibrary.dll
# or
dnx ilspycmd MyLibrary.dll

# Decompile to an output folder
ilspycmd -o output-folder MyLibrary.dll
```

## Common .NET Assembly Locations

### NuGet packages

```bash
~/.nuget/packages/<package-name>/<version>/lib/<tfm>/
```

### .NET runtime libraries

```bash
dotnet --list-runtimes
```

### .NET SDK reference assemblies

```bash
dotnet --list-sdks
```

> Reference assemblies do not contain implementations.

### Project build output

```bash
./bin/Debug/net8.0/<AssemblyName>.dll
./bin/Release/net8.0/publish/<AssemblyName>.dll
```

## Core workflow

1. Identify what you want to understand
2. Locate the assembly
3. List types
4. Decompile the target

## Commands

### Basic decompilation

```bash
ilspycmd MyLibrary.dll
ilspycmd -o ./decompiled MyLibrary.dll
ilspycmd -p -o ./project MyLibrary.dll
```

### Targeted decompilation

```bash
ilspycmd -t Namespace.ClassName MyLibrary.dll
ilspycmd -lv CSharp12_0 MyLibrary.dll
```

### View IL code

```bash
ilspycmd -il MyLibrary.dll
```

## Notes on modern .NET builds

- ReadyToRun images may reduce readability
- Trimmed or AOT builds may omit code
- Prefer non-trimmed builds

## Legal note

Decompiling assemblies may be subject to license restrictions.
