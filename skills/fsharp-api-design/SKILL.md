---
name: fsharp-api-design
description: Design and review stable F# and .NET public APIs, NuGet package contracts, binary/source compatibility, serialization schemas, C# interop, computation expression builders, module and type surfaces, and migration tests. Use when changing exported F# modules, functions, records, discriminated unions, classes, interfaces, attributes, target frameworks, FSharp.Core versions, DTOs, wire formats, or any contract consumed outside the current assembly. Emphasize private representation, explicit DTOs, additive APIs, C#-friendly boundaries, staged migrations, Obsolete guidance, and API diff tooling.
---

# F# Public API Design and Compatibility

## Operating Model

Treat every public F# surface as both an F# source contract and a CLR contract. F# syntax can hide generated .NET members, method overloads, properties, nested case types, and helper methods that consumers may bind to.

Review compatibility across four dimensions:

| Dimension | Question | Examples |
|---|---|---|
| Source | Does downstream F# and C# source still compile? | names, modules, overloads, function shape, record labels, DU cases, optional args |
| Binary | Do existing compiled consumers still load and call? | method signatures, assembly identity, generated members, target framework |
| Semantic | Does behavior remain compatible? | defaults, validation, exceptions, ordering, retries, cancellation |
| Wire | Can old and new serialized data interoperate? | JSON, protobuf, persistence, event payloads, database DTOs |

Use this default stance:

1. Preserve released contracts.
2. Add new contracts beside old ones.
3. Deprecate before removing.
4. Keep representation private when future growth is plausible.
5. Make compatibility claims testable.

F#-specific caution: changes that look local can alter the compiled CLR shape. Changing curried versus tupled arguments, record fields, DU cases, optional parameters, generic constraints, inline functions, active patterns, or module placement can break source, binary, reflection, serialization, or C# consumers.

## Release Decision Rules

| Change | Minimum release | Notes |
|---|---|---|
| Bug fix with compatible behavior | Patch | Avoid changing documented defaults or exception behavior. |
| New module function, type, member, DU case on private/internal DU | Minor | Review overload and type inference effects. |
| New optional configuration through builder/options object | Minor | Keep defaults stable. |
| Deprecation with working replacement | Minor | Add replacement in the same release. |
| Target framework or FSharp.Core dependency broadening | Minor | Verify all supported consumers still restore and compile. |
| Removed item, renamed item, changed signature, reordered tuple, required record field | Major | Provide migration notes and obsolete period first. |
| New case on released public DU used exhaustively | Usually major | Use an extensible class/interface model when cases must grow. |
| Changed wire field, tag, case name, default, or meaning | Usually major or staged migration | Deploy readers before writers. |

Patch releases should be boring. Minor releases may add capabilities, but must not flip defaults casually. Major releases still need precise migration guidance.

## Shape Public APIs Deliberately

Prefer signatures that are stable for both F# and C# callers when the API is public outside a single F# codebase.

```fsharp
namespace Orders

type ClientOptions private (
    endpoint: System.Uri,
    timeout: System.TimeSpan,
    maxRetries: int
) =
    member _.Endpoint = endpoint
    member _.Timeout = timeout
    member _.MaxRetries = maxRetries

    static member Create(endpoint: System.Uri) =
        ClientOptions(endpoint, System.TimeSpan.FromSeconds 30.0, 3)

    member this.WithTimeout(timeout: System.TimeSpan) =
        ClientOptions(this.Endpoint, timeout, this.MaxRetries)

    member this.WithMaxRetries(maxRetries: int) =
        ClientOptions(this.Endpoint, this.Timeout, maxRetries)
```

Rules:

- Prefer private constructors for domain types, options, clients, handles, and values with invariants.
- Expose named members, factories, and builders for types expected to grow.
- Avoid public record fields for configuration expected to grow; adding a required field breaks record construction.
- Use records for stable data carriers where copy-and-update is intentionally part of the API.
- Avoid public tuples for long-lived APIs; names matter for versioning, docs, and C# callers.
- Prefer explicit parameter names and options objects over long curried public functions.

## Modules, Functions, and Members

F# modules compile to static classes. Module names, compiled names, function names, and argument shape are public CLR surface.

```fsharp
[<RequireQualifiedAccess>]
module OrderId =
    let parse (value: string) : Result<OrderId, OrderIdError> =
        // ...
```

Module rules:

- Use modules for stateless functions, construction helpers, and operations on DUs or records.
- Use `[<RequireQualifiedAccess>]` on modules containing common names such as `parse`, `create`, `empty`, or DU cases exposed broadly.
- Consider `[<CompiledName>]` when public F# names need stable C# names.
- Avoid moving functions between modules after release; the compiled type name changes.
- Avoid changing curried functions to tupled functions, or tupled functions to curried functions, in public APIs.
- Prefer members on classes for object-oriented .NET APIs that many C# consumers will call.

## Records

Public records are convenient but expose construction, labels, generated copy members, equality, and serialization shape.

```fsharp
type Money =
    private
        { Cents: int64
          Currency: Currency }

[<RequireQualifiedAccess>]
module Money =
    let create cents currency =
        if cents < 0L then Error MoneyError.Negative
        else Ok { Cents = cents; Currency = currency }

    let cents value = value.Cents
    let currency value = value.Currency
```

Record rules:

- Use private records plus module functions for domain values with invariants.
- Use public records for stable DTOs and simple immutable data where field labels are the contract.
- Treat adding, removing, renaming, or changing a public record field as breaking.
- Avoid `[<CLIMutable>]` on domain records; reserve it for serializer/model-binding DTOs.
- Do not expose mutable record fields in public APIs unless mutation is deliberately the contract.

## Discriminated Unions

Use DUs for closed domains where exhaustive matching is valuable.

```fsharp
type PaymentState =
    | Pending
    | Authorized of authorizationId: string
    | Captured of receiptId: string
    | Failed of reason: string
```

DU rules:

- Use DUs for closed state, commands, events inside a bounded context, and typed errors.
- Treat adding a case to a released public DU as source-breaking for exhaustive matches.
- Prefer `[<RequireQualifiedAccess>]` for public DUs whose case names are common.
- Put case-specific data on the case that owns it.
- Avoid catch-all `_` matches in the defining assembly for business logic; exhaustive matches catch new cases.
- For wire enums, preserve unknown values with `Unknown of string` or raw storage.

For public APIs that must grow without breaking exhaustive matches, prefer an abstract class, interface, or stable DTO with a string kind and payload.

## Classes, Interfaces, and Abstract Types

Use classes at .NET interop boundaries, when object identity matters, or when construction and overloads need C# ergonomics.

```fsharp
type IClock =
    abstract Now: unit -> System.DateTimeOffset

type SystemClock() =
    interface IClock with
        member _.Now() = System.DateTimeOffset.UtcNow
```

Rules:

- Prefer functions and modules for F#-only pure behavior.
- Prefer small interfaces owned by the consumer boundary.
- Avoid broad service/repository interfaces that become inheritance-shaped architecture.
- Adding an abstract member to a public interface or abstract class is breaking.
- Prefer a new derived interface, extension member, or helper function when behavior must grow.
- Seal classes by default unless inheritance is a supported extension point.
- Document thread-safety and disposal behavior for public classes.

## Inline, SRTP, and Computation Expressions

Inline functions and statically resolved type parameters are powerful but can make public APIs brittle.

Rules:

- Keep `inline` and SRTP-heavy helpers internal unless generic numeric performance is the API purpose.
- Avoid exposing complex inferred constraints in stable public APIs.
- Treat computation expression builder methods as public protocol: `Bind`, `Return`, `ReturnFrom`, `Delay`, `Combine`, `Using`, `TryWith`, `TryFinally`, `MergeSources`, and overloads.
- Add builder capabilities additively and test representative expressions.
- Do not rename builder members or change return types after release.

## Exceptions, Results, and Cancellation

F# APIs should make expected failure explicit. .NET APIs still need exception discipline.

Rules:

- Use `Result<'T,'Error>` for expected domain failures in F#-first APIs.
- Use exceptions for programmer errors, impossible states, and conventional .NET boundary failures.
- Avoid changing exception types, messages documented for users, or error classification in patch releases.
- Include `CancellationToken` on async or long-running public APIs when cancellation matters.
- Do not add required cancellation parameters later; provide overloads or options objects up front.

## Wire Compatibility

Keep domain types separate from wire contracts. F# record and DU shapes are not automatically durable schemas.

```fsharp
[<CLIMutable>]
type HeartbeatV1Dto =
    { From: string
      Sequence: int64 }

[<CLIMutable>]
type HeartbeatV2Dto =
    { From: string
      Sequence: int64
      CreatedAtUnixMs: int64 option }
```

Wire rules:

- Use explicit DTOs for JSON, protobuf, database rows, and public event payloads.
- Use stable field names and stable discriminator values, not F# type or case names.
- Keep domain validation in mapping functions, not serializer attributes alone.
- Add optional input fields with defaults; do not make old payloads invalid.
- Avoid relying on DU default serialization for long-lived external protocols unless the exact format is documented and fixture-tested.
- Preserve old payload fixtures and new-write fixtures.

Rolling upgrade sequence:

1. Deploy readers that accept old and new formats.
2. Add a flag or config for new writes.
3. Enable new writes after active readers support them.
4. Make the new format default only when persisted data and fleet versions are safe.
5. Remove old support later through a major release or explicit migration.

## NuGet, Assembly, and Target Frameworks

Package metadata and assembly identity are part of the contract.

Rules:

- Treat target framework changes, FSharp.Core dependency changes, strong names, public analyzers, and generated source as compatibility-sensitive.
- Avoid raising the minimum supported .NET SDK, target framework, or FSharp.Core version in a patch release unless policy explicitly allows it.
- Keep `AssemblyVersion` stable across compatible releases when binary binding matters; use `AssemblyFileVersion` and package version for release identity.
- Test package restore and compile for supported target frameworks.
- Include C# smoke tests for public packages intended for mixed .NET consumers.

## Deprecation

```fsharp
[<System.Obsolete("Use Client.SendRequest instead. This member will be removed in 2.0.")>]
member this.Send(request: Request) =
    this.SendRequest(request)
```

Deprecation rules:

- Add the replacement before or in the same release as the deprecation.
- Keep obsolete APIs working until the planned major release.
- Include examples and mechanical migration notes.
- Avoid using `Obsolete` as a substitute for compatibility in patch releases.

## Compatibility Testing

Use tooling as a gate, not as a substitute for review.

Useful checks:

```bash
dotnet build -c Release
dotnet test -c Release
dotnet pack -c Release
```

Add package/API checks when stable contracts matter:

- Use PublicApiGenerator, ApiCompat, or a similar API diff tool for public assemblies.
- Add downstream-style tests from F# and C# projects.
- Keep serialization fixtures from previous versions.
- Test supported target frameworks and FSharp.Core version ranges.
- Test binary compatibility by referencing the previous package from a sample consumer when the package promises it.

## Review Checklist

Use this checklist for PRs that touch public APIs, packages, wire formats, target frameworks, or interop:

- [ ] No removed, renamed, moved, or hidden public modules, types, members, fields, labels, or cases without a major-version plan.
- [ ] No changed function shape, tuple shape, generic constraints, optional parameters, return types, or exception/error contract without a new API and deprecation path.
- [ ] Records and DUs are public only when their exact shape is intentionally stable.
- [ ] Configuration expected to grow uses private representation plus builders, options, or named members.
- [ ] F#-first APIs and C#-consumed APIs have both been reviewed for ergonomics.
- [ ] Inline, SRTP, active patterns, and computation expression builder surfaces are intentional and tested.
- [ ] Target frameworks, FSharp.Core versions, package metadata, and assembly identity changes are policy-compliant.
- [ ] Defaults, ordering, validation, retries, cancellation, and error semantics remain compatible or have a migration plan.
- [ ] Wire readers accept old payloads; new writes are staged.
- [ ] API diff, downstream compile tests, package restore tests, release notes, and migration notes have been reviewed.

## Common Anti-Patterns

### Public Config Record That Must Grow

```fsharp
type ClientConfig =
    { Endpoint: string
      Timeout: System.TimeSpan }
```

Prefer private representation plus `Create` and `With...` members when new options are likely.

### Durable Wire Format Based on DU Names

```json
{ "Case": "OrderCreated", "Fields": [ "..." ] }
```

Prefer explicit protocol names such as `order.created.v1`.

### C#-Hostile Public Function Shape

```fsharp
val send : client:Client -> request:Request -> Async<Response>
```

For mixed consumers, provide a member or static method with tupled arguments and `Task<Response>`.

### Behavior Break Presented as Cleanup

Changing a default timeout from 30 seconds to 5 seconds is a behavior break. Add an explicit fast-fail mode instead.

## References

- F# Component Design Guidelines: https://learn.microsoft.com/dotnet/fsharp/style-guide/component-design-guidelines
- F# Coding Conventions: https://learn.microsoft.com/dotnet/fsharp/style-guide/conventions
- .NET library guidance: https://learn.microsoft.com/dotnet/standard/library-guidance/
- Semantic Versioning: https://semver.org/
