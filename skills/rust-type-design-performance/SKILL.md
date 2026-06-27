---
name: rust-type-design-performance
description: Design and review Rust types and APIs for performance using private representation, borrowed inputs, small Copy newtypes, enums for closed sets, generics for hot paths, trait objects at boundaries, iterator-based allocation control, careful async type design, layout awareness, and justified unsafe. Use when optimizing Rust code, designing performance-sensitive public APIs, reducing clones and allocations, choosing between structs/enums/traits/generics/dyn, or reviewing strings, bytes, slices, paths, collections, futures, and memory layout.
---

# Rust Type Design for Performance

## Operating Model

Performance-friendly Rust starts with precise ownership and representation choices. Prefer APIs that let callers borrow, stream, and choose when to allocate.

Default stance:

1. Keep representation private unless public fields are the intentional API.
2. Borrow inputs by default.
3. Use small newtypes for type safety without runtime cost.
4. Use enums for closed variants and traits for open behavior.
5. Use generics in hot paths and `dyn Trait` at runtime boundaries.
6. Allocate at boundaries, not in the middle of pipelines.
7. Keep pure calculations synchronous.
8. Treat layout and unsafe as measured engineering decisions, not style choices.

Measure before cleverness. Prefer obvious code until profiling, allocation counts, or type-size evidence shows a real problem.

## Private Representation

Private fields preserve invariants and allow representation changes without breaking callers.

```rust
pub struct OrderProcessor {
    max_batch_size: usize,
    retry_policy: RetryPolicy,
}

impl OrderProcessor {
    pub fn new(max_batch_size: usize, retry_policy: RetryPolicy) -> Self {
        Self {
            max_batch_size,
            retry_policy,
        }
    }

    pub fn process(&self, orders: &[Order]) -> Vec<ProcessedOrder> {
        process_batch(orders, self.max_batch_size, &self.retry_policy)
    }
}

fn process_batch(
    orders: &[Order],
    max_batch_size: usize,
    retry_policy: &RetryPolicy,
) -> Vec<ProcessedOrder> {
    orders
        .chunks(max_batch_size)
        .flat_map(|chunk| process_chunk(chunk, retry_policy))
        .collect()
}
```

Avoid public fields for growing or performance-sensitive types:

```rust
pub struct OrderProcessor {
    pub max_batch_size: usize,
    pub retry_policy: RetryPolicy,
}
```

Representation rules:

- Use private fields for domain types, handles, caches, clients, processors, and collections with invariants.
- Expose slices, iterators, and accessors instead of concrete internal containers.
- Use public fields only when literal construction and direct field access are deliberately stable.
- Seal traits when downstream implementations would block future optimization or representation changes.

```rust
mod sealed {
    pub trait Sealed {}
}

pub trait WireMessage: sealed::Sealed {
    fn message_type(&self) -> &'static str;
}
```

## Small Value Types

Newtypes improve type safety and are usually zero-cost.

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CustomerId(uuid::Uuid);

impl CustomerId {
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }

    pub fn as_uuid(self) -> uuid::Uuid {
        self.0
    }
}
```

Use `#[repr(transparent)]` only when layout compatibility matters:

```rust
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UserHandle(u64);
```

Value type rules:

| Use | When |
|---|---|
| `Copy` | Small scalar wrappers where duplication is cheap and invisible |
| `Clone` only | Values with allocation or meaningful duplication cost |
| `#[repr(transparent)]` | Layout guarantee around one field |
| `NonZero*` | Invalid-zero IDs or handles where `Option<T>` should stay compact |
| `Arc<T>` | Shared immutable ownership across tasks or threads |
| `Box<T>` | Stable address, recursive types, or rare large enum variants |

Do not derive `Copy` just because the compiler permits it. `Copy` is an API promise that duplication is cheap and unsurprising.

## Structs, Enums, Generics, and `dyn Trait`

Use structs for one data shape:

```rust
pub struct Money {
    cents: i64,
    currency: Currency,
}
```

Use enums for known closed variants:

```rust
pub enum Discount {
    None,
    Percent(u8),
    Fixed(Money),
}

pub fn apply_discount(total: Money, discount: Discount) -> Money {
    match discount {
        Discount::None => total,
        Discount::Percent(percent) => total.discount_percent(percent),
        Discount::Fixed(amount) => total.saturating_sub(amount),
    }
}
```

Use generics for hot open behavior:

```rust
pub trait PriceRule {
    fn apply(&self, order: &Order) -> Money;
}

pub fn calculate_total<R>(order: &Order, rule: &R) -> Money
where
    R: PriceRule,
{
    rule.apply(order)
}
```

Use `dyn Trait` at boundaries:

```rust
pub struct CheckoutService {
    payment_gateway: Box<dyn PaymentGateway + Send + Sync>,
}
```

Dispatch rules:

- Use enums when variants are known and exhaustiveness is valuable.
- Use generics for hot loops, library internals, and code that benefits from inlining.
- Use `dyn Trait` for runtime composition, plugin systems, dependency injection, and application wiring.
- Avoid `dyn Trait` in inner loops unless measured.
- Avoid exposing huge generic types in public APIs when `impl Trait` can hide them.
- Use `#[inline]` selectively for tiny cross-crate functions and accessors.
- Do not use `#[inline(always)]` without measurement.

## Pure Functions

Pure functions are fast, testable, and easy for LLVM to optimize.

```rust
pub fn calculate_total(items: &[OrderItem]) -> Money {
    items.iter().map(OrderItem::total).sum()
}
```

Use associated functions when construction belongs to a type but does not need `self`:

```rust
impl Money {
    pub fn zero(currency: Currency) -> Self {
        Self { cents: 0, currency }
    }
}
```

Function rules:

- Use methods when behavior depends on `self` or preserves type invariants.
- Use free functions for stateless transformations inside a module.
- Pass dependencies explicitly to pure functions.
- Avoid service structs with hidden dependencies for simple calculations.
- Keep pure CPU work synchronous.

## Borrowed Inputs

Owned containers in parameters force callers to allocate or transfer ownership. Borrow instead.

```rust
use std::path::Path;

pub fn parse_order_id(value: &str) -> Result<OrderId, ParseOrderIdError> {
    value.parse()
}

pub fn checksum(bytes: &[u8]) -> u32 {
    crc32fast::hash(bytes)
}

pub fn load_config(path: &Path) -> Result<Config, ConfigError> {
    let text = std::fs::read_to_string(path)?;
    Ok(toml::from_str(&text)?)
}
```

Type choices:

| Scenario | Prefer | Avoid |
|---|---|---|
| Read text | `&str` | `&String`, owned `String` |
| Store text | `String`, `Box<str>`, `Arc<str>` | `'static str` workarounds |
| Read bytes | `&[u8]` | `&Vec<u8>` |
| Mutate bytes | `&mut [u8]` | Allocating per operation |
| Read path | `&Path` | `&PathBuf`, `&str` for filesystem paths |
| Store path | `PathBuf` | `String` |
| Maybe owned text | `Cow<'a, str>` | Unconditional clone |
| Shared immutable large value | `Arc<T>` | Cloning the whole value |
| Fixed owned sequence | `Box<[T]>` | Keeping spare `Vec<T>` capacity |

Use `Cow` when avoiding common-case allocation is meaningful and the API remains readable:

```rust
use std::borrow::Cow;

pub fn normalize_header<'a>(value: &'a str) -> Cow<'a, str> {
    let trimmed = value.trim();

    if trimmed.len() == value.len() && trimmed.is_ascii() {
        Cow::Borrowed(value)
    } else {
        Cow::Owned(trimmed.to_ascii_lowercase())
    }
}
```

Do not spread `Cow` through ordinary APIs where a borrowed input and owned output are clearer.

## Iterators and Allocation Control

Defer collection until ownership is needed.

```rust
let mut active: Vec<_> = orders
    .iter()
    .filter(|order| order.is_active())
    .collect();
active.sort_by_key(|order| order.created_at());
```

Return iterators when callers may not need all results:

```rust
pub fn active_orders(orders: &[Order]) -> impl Iterator<Item = &Order> {
    orders.iter().filter(|order| order.is_active())
}
```

Preallocate when size is known:

```rust
pub fn render_lines(lines: &[Line]) -> Vec<String> {
    let mut rendered = Vec::with_capacity(lines.len());

    for line in lines {
        rendered.push(render_line(line));
    }

    rendered
}
```

Avoid accidental clones in iterator chains:

```rust
let paid: Vec<&Order> = orders
    .iter()
    .filter(|order| order.is_paid())
    .collect();
```

Iterator rules:

- Use iterator chains for simple transformations.
- Use `for` loops when mutation, error handling, or early exits are clearer.
- Collect once, at the boundary.
- Use `extend` to add iterator output to an existing collection instead of collecting and appending.
- Implement `size_hint` or `ExactSizeIterator::len` for custom iterators when accurate.
- Prefer `filter_map` over `filter` followed by `map` in hot iterator chains when it stays clear.
- Prefer `chunks_exact` when chunk size is known to divide a slice, or handle the remainder explicitly.
- Use `iter().copied()` for small `Copy` values in hot loops when references pessimize codegen.
- Prefer sorting one `Vec` over collect-sort-collect chains.
- Use `SmallVec`, `ArrayVec`, arenas, or bump allocation only after profiling shows allocation pressure.

Reuse collections at hot allocation sites:

```rust
let mut line = String::new();
while reader.read_line(&mut line)? != 0 {
    process(&line);
    line.clear();
}
```

Reuse rules:

- Use `Vec::with_capacity`, `String::with_capacity`, `reserve`, or `reserve_exact` when size is known.
- Reuse workhorse `Vec` and `String` values with `clear()` in hot loops.
- Use `clone_from` to reuse an existing allocation when replacing an owned value with a clone.
- Use `SmallVec` for many short vectors, `ArrayVec` when the maximum length is fixed, and benchmark both.

## Collection Return Types

Return types should communicate ownership precisely.

```rust
pub fn items(&self) -> &[OrderItem] {
    &self.items
}

pub fn into_items(self) -> Vec<OrderItem> {
    self.items
}

pub fn active_items(&self) -> impl Iterator<Item = &OrderItem> {
    self.items.iter().filter(|item| item.is_active())
}
```

Return type guidelines:

| Need | Return |
|---|---|
| Borrow internal sequence | `&[T]` |
| Mutate internal sequence | `&mut [T]` only when mutation is the API |
| Transfer owned sequence | `Vec<T>` |
| Transfer fixed owned sequence | `Box<[T]>` |
| Lazy derived values | `impl Iterator<Item = T>` or `impl Iterator<Item = &T>` |
| Maybe one item | `Option<T>` or `Option<&T>` |
| Shared immutable data | `Arc<T>` or `Arc<[T]>` |
| Stable text view | `&str` |
| Owned text | `String` or `Box<str>` |

Avoid returning `&Vec<T>`; it exposes implementation without adding useful capability.

## Async Type Design

Async Rust creates state machines. That is powerful, but not free.

```rust
pub fn validate_order(command: &CreateOrderCommand) -> Result<(), ValidationError> {
    // CPU-only validation.
}

pub async fn save_order(repository: &OrderRepository, order: Order) -> Result<(), SaveError> {
    repository.save(order).await
}
```

Async performance rules:

- Do not use async for pure calculations.
- Avoid `async_trait` on hot-path traits because it usually boxes futures.
- Prefer concrete async functions for application services.
- Use native `async fn` in traits or associated future types when allocation matters.
- Avoid holding large values across `.await`; the generated future stores them.
- Prefer channels or worker pools for background work instead of unbounded task spawning.
- Use `spawn_blocking` for blocking CPU or sync I/O called from async contexts.

## Memory Layout

Large enum variants can bloat every value of the enum.

```rust
pub enum Event {
    Small(SmallEvent),
    Huge(Box<[u8; 4096]>),
}
```

Measure type sizes in tests when layout matters:

```rust
#[test]
fn event_size_stays_reasonable() {
    assert!(std::mem::size_of::<Event>() <= 32);
}
```

Layout rules:

- Keep frequently copied values small.
- Box rare large enum variants.
- Use `Box<[T]>` for owned sequences that will not grow; it stores pointer plus length without vector capacity.
- Consider `ThinVec` for often-empty vectors inside hot, frequently instantiated types.
- Consider smaller integer fields such as `u32` or `u16` for stored indices when bounds make that valid.
- Use `Option<NonZeroU64>` or `Option<NonNull<T>>` when niche optimization matters.
- Use static size assertions for hot types where accidental growth would hurt.
- Do not rely on Rust layout unless using `repr(C)` or `repr(transparent)`.
- Never change representation for FFI-exposed types without ABI review.
- Verify cache-sensitive changes with benchmarks, not intuition.

Rust may copy types larger than roughly 128 bytes with `memcpy`; if `memcpy` is hot, inspect type sizes and consider shrinking hot types.

## Hashing and I/O

Use specialized choices only when profiling identifies the bottleneck.

Hashing rules:

- Try faster hashers such as `rustc_hash`, `fnv`, or `ahash` only when hashing is hot and HashDoS resistance is not required.
- Use `nohash_hasher` for suitable integer-like keys that do not need real hashing.
- Preallocate hot `HashMap` and `HashSet` values when the expected size is known.
- Treat byte-wise hashing as advanced; require layout proof and measurement.

I/O rules:

- Lock stdout, stdin, or stderr manually when doing repeated operations.
- Use `BufReader` and `BufWriter` for many small reads or writes.
- Flush buffered writers explicitly when flush errors matter.
- Prefer `BufRead::read_line` with a reused `String` over `BufRead::lines` in hot line-reading loops.
- Use byte-oriented input such as `read_until` when UTF-8 validation is unnecessary.

## Lazy Standard Library APIs

Prefer lazy variants when fallback construction may be expensive:

```rust
let value = maybe_value.unwrap_or_else(|| build_default());
let result = maybe_id.ok_or_else(|| make_error(context));
```

Use `*_or_else` forms for `Option` and `Result` when the fallback allocates, formats, clones, or computes nontrivially.

## Unsafe

Default policy:

```toml
[lints.rust]
unsafe_code = "forbid"
```

For crates that require unsafe:

```toml
[lints.rust]
unsafe_op_in_unsafe_fn = "deny"
```

Every unsafe block needs a safety comment:

```rust
// SAFETY: `ptr` is created from a valid mutable slice above, and `len` is the
// exact slice length. No aliases are used while the mutable slice exists.
unsafe {
    std::slice::from_raw_parts_mut(ptr, len)
}
```

Unsafe rules:

- Use safe Rust unless a benchmark or boundary requirement proves the need.
- Prefer standard library APIs and well-reviewed crates over custom unsafe code.
- Keep unsafe blocks tiny and wrapped in safe APIs.
- State the aliasing, lifetime, initialization, and thread-safety invariants.
- Test unsafe abstractions with Miri where possible.
- Add property tests or fuzzing around boundary conditions when risk is meaningful.

## Review Checklist

Use this checklist for performance-sensitive Rust type and API reviews:

- [ ] Public fields are intentional; otherwise representation is private.
- [ ] Parameters borrow instead of forcing ownership.
- [ ] Clones are intentional, cheap, or documented.
- [ ] Newtypes protect primitive values without unnecessary allocation.
- [ ] `Copy` is limited to cheap scalar values.
- [ ] Closed variants use enums.
- [ ] Hot paths use static dispatch when appropriate.
- [ ] Trait objects are at boundaries or justified by measurement.
- [ ] Intermediate collections are avoided.
- [ ] Hot collections reuse capacity or preallocate when sizes are known.
- [ ] Return types communicate ownership precisely.
- [ ] Hashing and I/O choices match the measured bottleneck.
- [ ] Async functions actually perform async work.
- [ ] Large values are not held across `.await` without reason.
- [ ] Large enum variants, layout-sensitive types, and FFI types have size/layout review.
- [ ] Unsafe is forbidden or narrowly justified with safety comments and tests.
- [ ] Performance-sensitive changes have benchmarks or profiling evidence.

## Common Anti-Patterns

### Owned Input for Read-Only Work

```rust
pub fn parse_id(value: String) -> Result<OrderId, Error> { ... }
```

Accept `&str` instead.

### Exposing Concrete Collections

```rust
pub fn items(&self) -> &Vec<OrderItem> { &self.items }
```

Expose `&[OrderItem]` instead.

### Dynamic Dispatch in Hot Loops

```rust
fn score_all(rules: &[Box<dyn Rule>], orders: &[Order]) -> Vec<Score> { ... }
```

Use enums or generics for known hot strategies unless measurement supports dynamic dispatch.

### Reflexive Intermediate Collections

```rust
let values = items.iter().map(a).collect::<Vec<_>>();
let values = values.iter().map(b).collect::<Vec<_>>();
```

Chain and collect once, or use a loop when clearer.

### Async Pure Functions

```rust
pub async fn calculate_total(items: &[OrderItem]) -> Money { ... }
```

Make pure calculations synchronous.

### Blanket Cloning

```rust
let snapshot = value.clone();
```

Borrow, move, or document why the clone is intentional.

## References

- Rust API Guidelines: https://rust-lang.github.io/api-guidelines/
- Rust Performance Book: https://nnethercote.github.io/perf-book/
- std::borrow::Cow: https://doc.rust-lang.org/std/borrow/enum.Cow.html
- Rustonomicon: https://doc.rust-lang.org/nomicon/
- Miri: https://github.com/rust-lang/miri
