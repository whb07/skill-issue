---
name: fsharp-coding-standards
description: Write, refactor, and review idiomatic modern F# code using functional-first design, domain modeling with records and discriminated unions, immutability, options/results, typed errors, explicit DTO mapping, modules, small interfaces at boundaries, computation expressions, async discipline, and pragmatic .NET interop. Use when implementing F# features, translating object-oriented designs into F#, reviewing F# code quality, or correcting stringly typed state, nulls, exceptions for ordinary flow, mutation-heavy code, broad interfaces, weak domain types, hidden allocation, or blocking async code.
---

# Modern F# Coding Standards

## Operating Model

Design F# code around domain models, explicit states, and simple transformations. Prefer types that make invalid states unrepresentable, functions that reveal effects, and boundaries that interoperate cleanly with .NET.

Default stance:

1. Model the domain before choosing abstractions.
2. Keep invariants behind constructors and private representation.
3. Use immutable records, discriminated unions, options, results, and single-case wrappers instead of strings, booleans, nulls, sentinel values, and ordinary exceptions for expected failure.
4. Prefer pure functions and small modules for core logic.
5. Use classes and interfaces at .NET, dependency, UI, and framework boundaries.
6. Keep conversions explicit and reviewable.
7. Keep async at I/O and scheduling boundaries.
8. Use mutation only when locality, interop, or measured performance justifies it.

Good F# is usually direct. Avoid clever point-free pipelines, custom operators, and computation expressions that hide control flow, effects, allocation, or error behavior.

## Project Defaults

For new projects, prefer this baseline and adjust for local constraints:

```xml
<PropertyGroup>
  <TargetFramework>net8.0</TargetFramework>
  <LangVersion>latest</LangVersion>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  <Nullable>enable</Nullable>
</PropertyGroup>
```

Tooling rules:

- Keep Fantomas formatting mandatory when the project uses it.
- Keep warnings clean for shared libraries.
- Use analyzers or FSharpLint when the project already has them; do not introduce heavy lint gates casually.
- Run `dotnet test` for relevant projects.
- For public libraries, pair coding style with API compatibility review.

## Domain Types

### Records for Named Data

Use records for immutable named data. Keep representation private when values have invariants.

```fsharp
type Customer =
    private
        { Id: CustomerId
          Email: EmailAddress
          Name: string }

[<RequireQualifiedAccess>]
module Customer =
    let create id email name =
        if System.String.IsNullOrWhiteSpace name then
            Error CustomerError.EmptyName
        else
            Ok { Id = id; Email = email; Name = name }

    let id customer = customer.Id
    let email customer = customer.Email
    let name customer = customer.Name
```

Record rules:

- Use private records for domain values with invariants.
- Use public records for DTOs, view models, tests, and simple data carriers when record construction is intended.
- Prefer copy-and-update for immutable state transitions.
- Avoid mutable record fields unless required by a framework or interop boundary.
- Reserve `[<CLIMutable>]` for DTOs that need parameterless constructors and setters.

### Single-Case Unions for Values

Wrap IDs, validated text, money, counts, percentages, handles, and other values where primitives lose meaning.

```fsharp
type OrderId = private OrderId of System.Guid

[<RequireQualifiedAccess>]
module OrderId =
    let create () = OrderId(System.Guid.NewGuid())
    let ofGuid value = OrderId value
    let value (OrderId value) = value
```

```fsharp
type EmailAddress = private EmailAddress of string

type EmailAddressError =
    | Empty
    | MissingAtSign

[<RequireQualifiedAccess>]
module EmailAddress =
    let parse (value: string) =
        if System.String.IsNullOrWhiteSpace value then
            Error Empty
        else
            let trimmed = value.Trim()

            if not (trimmed.Contains "@") then Error MissingAtSign
            else Ok(EmailAddress trimmed)

    let value (EmailAddress value) = value
```

Value rules:

- Use private single-case DUs for validated values.
- Use `[<Struct>]` only for small hot values where copy cost and default values are acceptable.
- Expose `value`, `toString`, or domain-specific accessors deliberately.
- Avoid type abbreviations for domain concepts; `type OrderId = Guid` does not protect the domain.
- Keep parsing and formatting stable when text representation is part of the API.

## Discriminated Unions and State

Use DUs for closed sets, state machines, commands, events, typed errors, and workflow results.

```fsharp
type OrderStatus =
    | Draft
    | Submitted
    | Paid of receiptId: string
    | Shipped of trackingNumber: string
    | Cancelled of reason: string

let canCancel status =
    match status with
    | Draft | Submitted | Paid _ -> true
    | Shipped _ | Cancelled _ -> false
```

DU rules:

- Prefer exhaustive `match` in domain logic.
- Avoid `_` when a future case should force a decision.
- Put state-specific data on the case that owns it.
- Use `[<RequireQualifiedAccess>]` when public case names are common or ambiguous.
- Use active patterns sparingly to name complex classification logic; do not hide simple matches behind active patterns.

## Option, Result, and Exceptions

Use `option<'T>` for absence and `Result<'T,'Error>` for expected failure.

```fsharp
let tryFindCustomer id customers =
    customers
    |> List.tryFind (fun customer -> Customer.id customer = id)
```

```fsharp
type CheckoutError =
    | EmptyCart
    | PaymentFailed of PaymentError

let checkout cart payment =
    if Cart.isEmpty cart then
        Error EmptyCart
    else
        match Payment.charge payment (Cart.total cart) with
        | Ok () -> Ok(Order.fromCart cart)
        | Error err -> Error(PaymentFailed err)
```

Error rules:

- Use typed errors for domain failures callers can handle.
- Use exceptions for bugs, impossible states, cancellation, and conventional .NET boundary failures.
- Do not use `failwith`, `invalidOp`, or `Unchecked.defaultof` in production paths unless guarding an impossible invariant with context.
- Avoid returning `string` errors from shared libraries.
- Convert exceptions to results at domain boundaries only when callers can act on them.

## Functions, Pipelines, and Composition

Prefer named functions with clear data flow.

```fsharp
let total items =
    items
    |> List.sumBy OrderItem.total
```

Function rules:

- Prefer pure functions for domain transformations.
- Keep pipelines readable; break out named intermediate values when debugging or error handling matters.
- Avoid custom operators unless the domain already has a strong convention.
- Avoid point-free style when argument names would clarify intent.
- Prefer partial application for clarity, not as a default style in public APIs or hot paths.
- Use computation expressions when they remove real plumbing for `Async`, `Task`, validation, queries, or project-provided result workflows.

## Modules, Classes, and Interfaces

Use modules for cohesive functions around a type or bounded domain.

```fsharp
[<RequireQualifiedAccess>]
module Order =
    let submit order =
        // ...
```

Use classes when object identity, lifecycle, framework integration, or C# consumption matters.

```fsharp
type CheckoutService(paymentGateway: IPaymentGateway) =
    member _.Checkout(command: CheckoutCommand) : Task<Result<OrderId, CheckoutError>> =
        // ...
```

Rules:

- Keep domain modules small and cohesive.
- Put type definitions before modules that operate on them.
- Respect F# file order; dependencies flow downward through project files.
- Prefer small interfaces at boundaries and test seams.
- Avoid inheritance-first designs unless a .NET framework requires them.
- Avoid broad repository or service interfaces that mix unrelated capabilities.

## Explicit Mapping

Keep domain types separate from wire, storage, and UI DTOs.

```fsharp
[<CLIMutable>]
type OrderDto =
    { Id: string
      CustomerId: string
      TotalCents: int64
      Currency: string }

[<RequireQualifiedAccess>]
module OrderDto =
    let fromDomain order =
        { Id = OrderId.value (Order.id order) |> string
          CustomerId = CustomerId.value (Order.customerId order) |> string
          TotalCents = Money.cents (Order.total order)
          Currency = Currency.code (Money.currency (Order.total order)) }
```

Inbound mapping should be fallible:

```fsharp
let private parseItems items =
    let rec loop parsed remaining =
        match remaining with
        | [] ->
            Ok(List.rev parsed)
        | item :: rest ->
            match OrderItemCommand.fromDto item with
            | Ok parsedItem -> loop (parsedItem :: parsed) rest
            | Error err -> Error err

    loop [] items

let toCommand (request: CreateOrderRequestDto) =
    CustomerId.parse request.CustomerId
    |> Result.bind (fun customerId ->
        parseItems request.Items
        |> Result.map (fun items ->
            { CustomerId = customerId
              Items = items }))
```

Mapping rules:

- Keep serializer attributes on DTOs, not core domain types, unless serialization is the domain purpose.
- Make inbound mapping validate and return typed errors.
- Avoid reflection-heavy or macro-style mapping across domain boundaries unless the project already standardizes on it.
- Preserve stable wire names independently from F# type, module, and case names.

## Async Discipline

Keep async at I/O and scheduling boundaries.

```fsharp
let loadDashboard userId (orders: IOrderClient) (notifications: INotificationClient) =
    task {
        let ordersTask = orders.Recent(userId)
        let notificationsTask = notifications.Unread(userId)

        let! recentOrders = ordersTask
        let! unreadNotifications = notificationsTask

        return
            { Orders = recentOrders
              Notifications = unreadNotifications }
    }
```

Async rules:

- Do not make pure CPU functions async.
- Use `task {}` for .NET-facing APIs and `async {}` where an existing F# async workflow is already the project convention.
- Do not block with `.Result`, `.Wait()`, `Thread.Sleep`, or blocking I/O inside async code.
- Pass `CancellationToken` where cancellation matters.
- Do not start background work without a shutdown and error-observation plan.

## Null and Interop

F# code should avoid null in the domain, but .NET boundaries may produce it.

Rules:

- Convert nullable input to `option` at the boundary.
- Use `isNull` checks only at interop boundaries.
- Prefer `Option.ofObj` and `ValueOption` where appropriate.
- Avoid `AllowNullLiteral` on domain types.
- Be explicit about `Task<'T>` values that may complete with null when called from C# APIs.

## Testing Standards

```fsharp
[<Fact>]
let ``rejects empty email`` () =
    let result = EmailAddress.parse "   "
    Assert.Equal(Error EmailAddressError.Empty, result)
```

Testing rules:

- Prefer tests against public behavior and domain rules.
- Use table-driven tests for business cases.
- Use FsCheck for parsers, serializers, and value objects with invariants.
- Use snapshots only for stable textual output.
- Add regression tests before fixing subtle parsing, serialization, async, or state bugs.

## Review Checklist

Use this checklist for F# implementation and refactor reviews:

- [ ] Domain states are represented with records, DUs, options, results, and value wrappers rather than strings, booleans, nulls, or sentinel values.
- [ ] Constructors and module functions preserve invariants and are fallible when input can be invalid.
- [ ] Domain representation is private unless direct construction is intentional.
- [ ] Absence uses `option`; expected failure uses typed `Result`.
- [ ] Exceptions and `failwith` are absent from ordinary input validation paths.
- [ ] Functions are pure where possible and effects are visible in signatures.
- [ ] Mutation is local, justified, or required by interop.
- [ ] Interfaces are small, boundary-focused, and justified by real substitution.
- [ ] DTO mapping is explicit and fallible where validation is required.
- [ ] Async code avoids blocking calls and unobserved background work.
- [ ] Null handling is isolated at .NET boundaries.
- [ ] Fantomas, relevant builds, and tests have been run.

## Common Anti-Patterns

### Stringly Typed State

```fsharp
type Order =
    { Status: string }
```

Use a DU instead.

### Nullable State Clusters

```fsharp
type Order =
    { Status: OrderStatus
      ReceiptId: string option
      CancelReason: string option }
```

Put state-specific data on DU cases.

### Exceptions for Input Failure

```fsharp
let parseQuantity value =
    int value
```

Return `Result<Quantity, QuantityError>` when invalid input is expected.

### Type Abbreviation as Domain Model

```fsharp
type CustomerId = string
```

Use a single-case DU.

### Broad Base Interface

```fsharp
type IRepository =
    abstract GetOrder: OrderId -> Order
    abstract SaveOrder: Order -> unit
    abstract GetCustomer: CustomerId -> Customer
    abstract SaveCustomer: Customer -> unit
```

Use small interfaces per consumer boundary.

## References

- F# Coding Conventions: https://learn.microsoft.com/dotnet/fsharp/style-guide/conventions
- F# Component Design Guidelines: https://learn.microsoft.com/dotnet/fsharp/style-guide/component-design-guidelines
- F# for Fun and Profit, domain modeling: https://fsharpforfunandprofit.com/ddd/
