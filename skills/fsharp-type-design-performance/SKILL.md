---
name: fsharp-type-design-performance
description: Design and review F# types and APIs for performance using private representation, records, discriminated unions, struct records, struct unions, ValueOption, arrays, ResizeArray, IReadOnlyList, ReadOnlySpan, sequences, closures, inline functions, SRTP, task allocation, layout awareness, and measured mutation. Use when optimizing F# code, designing performance-sensitive public APIs, reducing allocations and boxing, choosing between records, classes, structs, DUs, interfaces, functions, generics, and SRTP, or reviewing collection, async, serialization, interop, and memory-layout choices.
---

# F# Type Design for Performance

## Operating Model

Performance-friendly F# starts with precise representation choices and clear allocation boundaries. Prefer domain clarity first, then optimize hot paths with measurements.

Default stance:

1. Keep representation private unless construction and fields are the intentional API.
2. Use records and DUs for clarity in ordinary domain code.
3. Use struct records, struct DUs, `ValueOption`, arrays, spans, and mutation only where measurements justify them.
4. Prefer arrays or `ResizeArray` for hot indexed collection work.
5. Prefer `seq` for streaming boundaries, not as a default in inner loops.
6. Keep `inline` and SRTP-heavy code local unless generic numeric performance is the API purpose.
7. Avoid hidden allocation from closures, partial application, sequence expressions, async workflows, and boxing in hot paths.
8. Treat layout and mutation as engineering decisions backed by profiling.
9. Prefer data-oriented layouts for hot code: contiguous arrays, predictable branches, and cache-friendly traversal often matter more than micro-optimizing individual functions.

Measure before cleverness. Prefer obvious F# until profiling, allocation counts, or type-size evidence shows a real problem.

## Private Representation

Private representation preserves invariants and allows performance changes without breaking callers.

```fsharp
type OrderProcessor private (maxBatchSize: int, retryPolicy: RetryPolicy) =
    member _.Process(orders: IReadOnlyList<Order>) =
        processBatches maxBatchSize retryPolicy orders

    static member Create(maxBatchSize, retryPolicy) =
        if maxBatchSize <= 0 then
            invalidArg (nameof maxBatchSize) "Batch size must be positive."

        OrderProcessor(maxBatchSize, retryPolicy)
```

Rules:

- Use private fields and constructors for domain types, handles, clients, processors, caches, and collections with invariants.
- Expose accessors, members, slices, arrays, spans, or iterators deliberately.
- Use public records only when labels and copy-and-update are part of the stable API.
- Avoid exposing concrete mutable collections unless mutation is the API.
- Keep public API shape separate from internal performance representation.

## Small Value Types

Single-case DUs improve type safety. In hot paths, choose reference or struct representation deliberately.

```fsharp
[<Struct>]
type CustomerId =
    private
    | CustomerId of System.Guid

[<RequireQualifiedAccess>]
module CustomerId =
    let create () = CustomerId(System.Guid.NewGuid())
    let value (CustomerId value) = value
```

Value rules:

| Use | When |
|---|---|
| Reference single-case DU | Ordinary domain code; avoids default-value traps |
| `[<Struct>]` single-case DU | Small hot scalar wrappers |
| Struct record | Small immutable aggregate copied cheaply |
| Class | Identity, lifecycle, inheritance, or large object avoiding repeated copies |
| `ValueOption<'T>` | Hot optional values where allocation matters |
| `option<'T>` | Ordinary domain absence and readability |

Do not make a type a struct just because it is possible. Structs have default values, copy costs, boxing risks, and public API consequences.

For larger structs, review copies explicitly. Passing a large struct by value can erase the intended allocation win; `inref<'T>` and `byref<'T>` can help in narrow internal APIs but come with lifetime restrictions and poor ergonomics for ordinary public APIs.

## Records, Classes, Structs, and DUs

Use records for ordinary immutable data:

```fsharp
type Money =
    { Cents: int64
      Currency: Currency }
```

Use DUs for known closed variants:

```fsharp
type Discount =
    | NoDiscount
    | Percent of byte
    | Fixed of Money
```

Use classes when identity, laziness, caches, disposal, or large state should not be copied:

```fsharp
type PriceCalculator(rules: IReadOnlyList<PriceRule>) =
    member _.Calculate(order: Order) =
        rules |> Seq.fold (fun total rule -> rule.Apply(order, total)) (Order.subtotal order)
```

Representation rules:

- Use DUs when variants are known and exhaustiveness is valuable.
- Box or separate rare large DU payloads if every value becomes too large.
- Use struct records/DUs only for small values with simple invariants.
- Avoid large structs in public APIs; copies can dominate.
- Beware generic struct values flowing through interfaces; boxing may erase the benefit.
- Review struct DU layout; each value carries enough space for the largest case plus a tag, so one large case can make every value large.
- Measure type size or allocations for hot representations.

## Collections

Choose collections by access pattern.

| Scenario | Prefer | Avoid |
|---|---|---|
| Hot indexed read | array or `IReadOnlyList<'T>` | list |
| Incremental append | `ResizeArray<'T>` | repeated list append |
| Immutable prepend and pattern match | list | array copying |
| Streaming boundary | `seq<'T>` or `IAsyncEnumerable<'T>` | precollecting everything |
| Known output size | preallocated array or `ResizeArray` | repeated concatenation |
| Key lookup | `Dictionary` or `Map` by mutability need | linear scans in hot paths |
| Byte/text slices | `ReadOnlySpan<byte>` or `ReadOnlySpan<char>` | allocating substrings |

Collection rules:

- Remember F# list is a linked list; it is great for prepend and pattern matching, not indexed loops.
- Arrays are usually best for tight loops and interop.
- `seq` is lazy and can allocate enumerators, closures, and state machines.
- Prefer `Array` functions or loops in hot paths.
- Use `ResizeArray` internally for builders, then return an immutable view or array.
- Preallocate when size is known.
- Avoid repeated `@`, `List.append`, or sequence concatenation in loops.
- Prefer contiguous arrays of simple data for cache-sensitive scans; object graphs and linked lists are expensive when memory locality dominates.

## Sequences and Allocation Control

Defer collection when callers may not need all results, but do not hide expensive repeated enumeration.

```fsharp
let activeOrders (orders: seq<Order>) =
    orders |> Seq.filter Order.isActive
```

For hot paths, be more concrete:

```fsharp
let activeOrdersArray (orders: Order[]) =
    let output = ResizeArray<Order>(orders.Length)

    for order in orders do
        if Order.isActive order then
            output.Add order

    output.ToArray()
```

Rules:

- Use `seq` at streaming boundaries and for one-pass transformations.
- Use arrays or `IReadOnlyList` when count, indexing, or repeated traversal matters.
- Avoid returning a lazy sequence over disposable resources unless lifetime is explicit.
- Avoid multiple enumeration of `seq`; materialize once when necessary.
- Use loops when mutation, early exit, or allocation control is clearer.

## Functions, Closures, and Dispatch

F# functions are values and may allocate closures.

```fsharp
let calculateTotal (rule: PriceRule) (order: Order) =
    rule.Apply order
```

Rules:

- Use functions for clarity in ordinary code.
- Watch partial application in hot loops; it can allocate closures.
- Prefer direct calls or local loops when profiling shows closure allocation.
- Use interfaces or delegates at runtime composition boundaries.
- Use generics or `inline` for hot generic behavior when it materially helps.
- Keep SRTP constraints private unless they are central to the library's purpose.
- Avoid object expressions in hot paths unless allocation is irrelevant.
- Distinguish F# `inline` from JIT inlining: F# `inline` enables compile-time specialization and SRTP, while the JIT still decides machine-code inlining for ordinary calls.

## Span, Memory, and Interop

Use spans for allocation-sensitive parsing and slicing.

```fsharp
let parseHeader (value: ReadOnlySpan<char>) =
    let trimmed = value.Trim()
    // parse without allocating substrings
    trimmed.Length
```

Span rules:

- Use `ReadOnlySpan<'T>` and `Span<'T>` for hot parsing, buffers, and interop.
- Do not store spans in heap objects.
- Do not use spans across `task`, `async`, iterator, or closure boundaries that outlive the stack frame.
- Provide simpler string/array overloads for public APIs when ergonomics matter.
- Use `Memory<'T>` or `ReadOnlyMemory<'T>` when data must cross async boundaries.

## Async Type Design

Async abstractions allocate state machines and capture values.

```fsharp
let validateOrder command =
    // CPU-only validation.
    Ok()

let saveOrder (repository: IOrderRepository) order =
    task {
        do! repository.Save(order)
    }
```

Async performance rules:

- Do not use async for pure calculations.
- Prefer `task {}` for .NET-facing APIs.
- Use `ValueTask` only for APIs with frequent synchronous completion and after understanding its consumption rules.
- Avoid holding large values across `let!`; the generated state machine stores them.
- Avoid creating many tiny tasks in hot loops.
- Bound background work instead of spawning freely.
- Keep cancellation tokens explicit in long-running APIs.

## Boxing and Units of Measure

F# abstractions can erase into boxed values when used through object, interfaces, reflection, or unconstrained generics.

Rules:

- Watch boxing for struct DUs, struct records, numeric values, and units of measure in generic/interface-heavy code.
- Units of measure are compile-time only; do not rely on them for runtime validation or C# consumers.
- Avoid `obj` and reflection in hot paths.
- Prefer concrete generic functions or inline helpers when boxing shows up in profiles.
- Use BenchmarkDotNet allocation diagnosers to confirm.

Common boxing triggers:

- Passing struct values through `obj`, non-generic interfaces, or reflection.
- Using generic equality or comparison in shapes that cannot stay specialized.
- Capturing struct values behind delegates or object expressions at abstraction boundaries.
- Mixing units of measure with runtime-generic code that erases the numeric representation.

## Atomic Immutable Updates

Immutable data can still support concurrent updates when the shared reference is swapped atomically.

```fsharp
open System.Threading

let mutable currentRules: PricingRules = PricingRules.empty

let updateRules transform =
    let rec loop () =
        let snapshot = Volatile.Read(&currentRules)
        let updated = transform snapshot
        let previous = Interlocked.CompareExchange(&currentRules, updated, snapshot)

        if obj.ReferenceEquals(previous, snapshot) then
            updated
        else
            loop ()

    loop ()
```

Rules:

- Use atomic swaps for occasional updates to immutable snapshots read by many threads.
- Keep the transformed value immutable; do not mutate snapshots after publication.
- Prefer a lock when updates touch multiple references or invariants are easier to preserve under a critical section.
- Avoid compare-exchange loops for high-contention workflows unless profiling supports the design.

## Strings and Formatting

String allocation is often the real hot path.

Rules:

- Use `StringBuilder` or pooled buffers for repeated concatenation.
- Avoid `sprintf` in hot paths; it is convenient but relatively expensive.
- Prefer `StringComparer.Ordinal` or `OrdinalIgnoreCase` for dictionaries unless culture-aware comparison is required.
- Avoid `ToLower()` for case-insensitive comparisons; use a comparer.
- Use spans for parsing substrings when profiling points there.

## Measurement

Use measurement to justify performance-oriented type changes.

Useful tools:

```bash
dotnet test -c Release
dotnet run -c Release
dotnet trace collect --process-id <pid>
```

Measurement rules:

- Use BenchmarkDotNet for microbenchmarks.
- Use dotnet-trace, dotnet-counters, PerfView, or profiler output for application behavior.
- Include allocation measurements for changes intended to reduce allocation.
- Add regression benchmarks or tests for hot code when the risk is real.
- Do not trade away clear domain modeling without evidence.

## Review Checklist

Use this checklist for performance-sensitive F# type and API reviews:

- [ ] Public representation is intentional; otherwise fields and constructors are private.
- [ ] Records, DUs, classes, and structs match the access pattern and copy cost.
- [ ] Struct types are small, default-safe, and do not introduce boxing in hot paths.
- [ ] `ValueOption` is used only where optional allocation matters.
- [ ] Collection choices match access patterns.
- [ ] Hot paths avoid accidental lazy sequence, closure, tuple, option, or result allocation when measured.
- [ ] Repeated traversal of `seq` is avoided or materialized deliberately.
- [ ] Cache-sensitive paths use contiguous data and predictable traversal where profiling shows locality matters.
- [ ] Spans or memory types are used only where lifetime rules are clear.
- [ ] Async functions actually perform async work.
- [ ] Large values are not held across awaits without reason.
- [ ] Large structs, struct DUs, and byref-style APIs have copy, layout, boxing, and lifetime review.
- [ ] String formatting and comparison choices match the measured bottleneck.
- [ ] Inline, SRTP, mutation, and low-level representation choices are justified by profiling or API purpose.
- [ ] Performance-sensitive changes include benchmarks, profiler evidence, or allocation evidence.

## Common Anti-Patterns

### List as Default Hot Collection

```fsharp
orders |> List.mapi scoreOrder
```

Use arrays or `IReadOnlyList` for hot indexed work.

### Lazy Sequence in an Inner Loop

```fsharp
let values = items |> Seq.map f |> Seq.filter g
```

Use arrays, loops, or materialize once when this is hot or repeatedly traversed.

### Struct Everything

```fsharp
[<Struct>]
type LargeOrder = { ... many fields ... }
```

Large structs copy; use classes or reference records unless measurement supports the struct.

### Public Tuple API

```fsharp
val tryParse : string -> bool * OrderId
```

Prefer `OrderId option`, `ValueOption<OrderId>`, or a named result type.

### Async Pure Function

```fsharp
let calculateTotal items =
    task { return items |> List.sumBy OrderItem.total }
```

Make pure calculations synchronous.

### Hidden Closure Allocation

```fsharp
for order in orders do
    handlers |> List.iter (fun handler -> handler order)
```

This may be fine; if it is hot, measure and consider a direct loop or concrete dispatch.

### Large Struct DU Case

```fsharp
[<Struct>]
type Snapshot =
    { A: int64
      B: int64
      C: int64
      D: int64
      E: int64
      F: int64 }

[<Struct>]
type Event =
    | Tick of int64
    | Snapshot of Snapshot
```

One large case can bloat every value. Use a reference DU, split the shape, or box the rare payload.

## References

- F# performance guidance: https://learn.microsoft.com/dotnet/fsharp/language-reference/functions/#inline-functions
- Writing High-Performance F# Code: https://www.bartoszsypytkowski.com/writing-high-performance-f-code/
- BenchmarkDotNet: https://benchmarkdotnet.org/
- .NET performance diagnostics: https://learn.microsoft.com/dotnet/core/diagnostics/
- Span and Memory usage guidelines: https://learn.microsoft.com/dotnet/standard/memory-and-spans/
