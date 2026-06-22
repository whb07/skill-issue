---
name: rust-type-design-performance
description: Design Rust types for performance: private fields and sealed traits by default, small Copy newtypes, slices over owned containers, iterators over intermediate Vecs, generics for hot paths, trait objects at boundaries, and measured allocation control. Use unsafe only with proof.
invocable: false
---

# Rust Type Design for Performance

## When to Use This Skill

Use this skill when:

- Designing new Rust types and APIs
- Reviewing code for avoidable allocations, cloning, dispatch overhead, or lock contention
- Choosing between structs, enums, traits, generics, and trait objects
- Working with strings, bytes, paths, slices, iterators, or async hot paths
- Optimizing code after profiling or benchmark evidence

---

## Core Principles

1. **Encapsulation is performance control** - Private fields let you change representation without breaking callers.
2. **Borrowed inputs first** - Accept `&str`, `&[T]`, `&Path`, and iterators before owned containers.
3. **Small value types are cheap** - Use newtypes and `Copy` for small scalars; avoid `Copy` for expensive or ownership-bearing values.
4. **Closed sets use enums** - Enums avoid heap allocation and dynamic dispatch for known variants.
5. **Open sets use traits** - Use generics for hot paths and `dyn Trait` at boundaries.
6. **Pure functions are free of hidden state** - Prefer free functions or associated functions when no state is needed.
7. **Allocate at boundaries** - Stream, borrow, and iterate internally; collect only when the caller needs ownership.
8. **Async has cost** - Do not make hot pure code async; avoid boxed futures in tight loops.
9. **Unsafe is a last resort** - Require a benchmark, a safety comment, and tests.
10. **Measure before cleverness** - Prefer obvious code until profiling says otherwise.

---

## Rust Equivalent of “Seal by Default”

Rust structs are not inherited, but public APIs are still extensibility contracts. Seal representation with privacy.

```rust
// DO: representation is private and can change later.
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

// Private pure helper. Not part of public API.
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

Avoid public fields unless they are the stable API:

```rust
// DON'T for growing public types: locks representation forever.
pub struct OrderProcessor {
    pub max_batch_size: usize,
    pub retry_policy: RetryPolicy,
}
```

### Seal Traits You Own

```rust
mod sealed {
    pub trait Sealed {}
}

pub trait WireMessage: sealed::Sealed {
    fn message_type(&self) -> &'static str;
}

pub struct OrderCreated;

impl sealed::Sealed for OrderCreated {}

impl WireMessage for OrderCreated {
    fn message_type(&self) -> &'static str {
        "order.created"
    }
}
```

Use sealed traits when downstream implementations would prevent future optimization or evolution.

---

## Small Value Types and Newtypes

Newtypes improve type safety and can be zero-cost.

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

**Value type rules:**

| Use | When |
|---|---|
| `Copy` | Small scalar wrappers: IDs, handles, flags, coordinates |
| `Clone` only | Values with heap allocation or meaningful duplication cost |
| `#[repr(transparent)]` | FFI/layout guarantee around one field |
| `NonZero*` | IDs or handles where zero is invalid and `Option<T>` should stay compact |
| `Arc<T>` | Shared ownership across tasks/threads |
| `Box<T>` | Stable address, recursive types, large enum variants |

Do not derive `Copy` just because the compiler permits it. `Copy` says duplication is invisible and cheap.

---

## Struct vs Enum vs Trait Object

### Use Structs for Data with One Shape

```rust
pub struct Money {
    cents: i64,
    currency: Currency,
}
```

### Use Enums for Closed Variants

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

Enums keep data inline and make matches exhaustive. They are ideal for closed business states and known strategy sets.

### Use Generics for Hot Open Behavior

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

Generics use static dispatch and enable inlining, at the cost of larger generated code.

### Use `dyn Trait` at Boundaries

```rust
pub struct CheckoutService {
    payment_gateway: Box<dyn PaymentGateway + Send + Sync>,
}
```

Trait objects are appropriate when you need runtime polymorphism, plugin boundaries, or dependency injection. Do not put `dyn Trait` in inner loops without measuring.

---

## Static Pure Functions

Rust’s simplest high-performance unit is a pure function.

```rust
pub fn calculate_total(items: &[OrderItem]) -> Money {
    items.iter().map(OrderItem::total).sum()
}
```

Use associated functions when the function belongs to a type but does not need `self`:

```rust
impl Money {
    pub fn zero(currency: Currency) -> Self {
        Self { cents: 0, currency }
    }
}
```

**Rules:**

- Use methods when behavior depends on `self` or preserves invariants.
- Use free functions for stateless transformations within a module.
- Pass dependencies explicitly to pure functions.
- Avoid service structs with hidden dependencies for simple calculations.
- Pure functions are naturally thread-safe, easy to test, and easy for LLVM to optimize.

---

## Slices, Strings, Paths, and Bytes

Owned containers in parameters force callers to allocate or give up ownership. Borrow instead.

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

**Type choices:**

| Scenario | Prefer | Avoid |
|---|---|---|
| Read text | `&str` | `&String`, `String` |
| Store text | `String`, `Box<str>`, `Arc<str>` | `'static str` hacks |
| Read bytes | `&[u8]` | `&Vec<u8>` |
| Mutable bytes | `&mut [u8]` | Allocating a new `Vec<u8>` per operation |
| Read path | `&Path` | `&PathBuf`, `&str` for filesystem paths |
| Store path | `PathBuf` | `String` |
| Maybe owned text | `Cow<'a, str>` | unconditional clone |
| Shared immutable large value | `Arc<T>` | cloning whole value |

### Use `Cow` for Maybe-Owned Data

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

Do not use `Cow` everywhere. Use it when avoiding common-case allocation is meaningful and the API remains readable.

---

## Iterators and Allocation Control

### Defer Collection

```rust
// BAD: repeated materialization.
let active: Vec<_> = orders.iter().filter(|order| order.is_active()).collect();
let sorted: Vec<_> = active.into_iter().sorted_by_key(Order::created_at).collect();

// GOOD: collect once when needed.
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

### Preallocate When Size Is Known

```rust
pub fn render_lines(lines: &[Line]) -> Vec<String> {
    let mut rendered = Vec::with_capacity(lines.len());

    for line in lines {
        rendered.push(render_line(line));
    }

    rendered
}
```

### Avoid Accidental Clones in Iterator Chains

```rust
// BAD: clones every order.
let paid: Vec<Order> = orders
    .iter()
    .cloned()
    .filter(Order::is_paid)
    .collect();

// GOOD: borrow until ownership is required.
let paid: Vec<&Order> = orders
    .iter()
    .filter(|order| order.is_paid())
    .collect();
```

**Iterator rules:**

- Use iterator chains for simple transformations.
- Use `for` loops when error handling, mutation, or early exits are clearer.
- Collect once, at the boundary.
- Prefer `sort_by_key` on a single `Vec` over collect-sort-collect chains.
- Use `SmallVec`, `ArrayVec`, and custom arenas only after profiling shows allocation pressure.

---

## Collection Return Types

Rust APIs should communicate ownership precisely.

```rust
// Borrowed view. No allocation.
pub fn items(&self) -> &[OrderItem] {
    &self.items
}

// Caller owns snapshot.
pub fn into_items(self) -> Vec<OrderItem> {
    self.items
}

// Lazy borrowed iteration.
pub fn active_items(&self) -> impl Iterator<Item = &OrderItem> {
    self.items.iter().filter(|item| item.is_active())
}
```

**Return type guidelines:**

| Need | Return |
|---|---|
| Borrow internal sequence | `&[T]` |
| Borrow mutable internal sequence | `&mut [T]` only when mutation is the API |
| Transfer owned sequence | `Vec<T>` |
| Lazy derived values | `impl Iterator<Item = T>` or `impl Iterator<Item = &T>` |
| Maybe one item | `Option<T>` or `Option<&T>` |
| Shared immutable data | `Arc<T>` or `Arc<[T]>` |
| Stable text view | `&str` |
| Owned text | `String` or `Box<str>` |

Avoid returning `&Vec<T>`; it exposes the implementation without adding value.

---

## Dispatch and Inlining

### Static Dispatch for Hot Paths

```rust
pub fn encode<W>(message: &Message, writer: &mut W) -> Result<(), EncodeError>
where
    W: std::io::Write,
{
    // monomorphized for each writer type
    write_message(message, writer)
}
```

### Dynamic Dispatch for Boundaries

```rust
pub struct Server {
    handlers: Vec<Box<dyn Handler + Send + Sync>>,
}
```

**Rules:**

- Use generics inside libraries and hot loops.
- Use `dyn Trait` for runtime composition, plugin systems, and application wiring.
- Avoid exposing huge generic types in public APIs when `impl Trait` can hide them.
- Use `#[inline]` selectively for tiny cross-crate functions and accessors.
- Do not carpet-bomb `#[inline(always)]`; it can make performance worse.

---

## Async Type Design Performance

Async Rust creates state machines. That is powerful, not free.

```rust
// DO: pure function is sync.
pub fn validate_order(command: &CreateOrderCommand) -> Result<(), ValidationError> {
    // CPU-only validation
}

// DO: async function performs I/O.
pub async fn save_order(repository: &OrderRepository, order: Order) -> Result<(), SaveError> {
    repository.save(order).await
}
```

**Async rules:**

- Do not use async for pure calculations.
- Avoid `async_trait` on hot-path traits; it boxes futures.
- Prefer concrete async functions for application services.
- Prefer channels for background work instead of spawning unbounded tasks.
- Avoid holding large values across `.await`; the future stores them.
- Use `spawn_blocking` for blocking CPU or sync I/O called from async contexts.

---

## Memory Layout and Large Types

Large enum variants can bloat every value of the enum.

```rust
// BAD: one huge variant makes the entire enum huge.
pub enum Event {
    Small(SmallEvent),
    Huge([u8; 4096]),
}

// BETTER: box the rare huge variant.
pub enum Event {
    Small(SmallEvent),
    Huge(Box<[u8; 4096]>),
}
```

Measure type sizes in tests when it matters:

```rust
#[test]
fn event_size_stays_reasonable() {
    assert!(std::mem::size_of::<Event>() <= 32);
}
```

**Layout rules:**

- Keep frequently copied values small.
- Box rare large enum variants.
- Use `Option<NonZeroU64>` or `Option<NonNull<T>>` when niche optimization matters.
- Do not rely on Rust layout unless using `repr(C)` or `repr(transparent)`.
- Never change representation for FFI-exposed types without ABI review.

---

## Unsafe Policy

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

**Unsafe rules:**

- Use safe Rust unless a benchmark proves the need.
- Prefer standard library APIs and well-reviewed crates over custom unsafe code.
- Keep unsafe blocks tiny and wrapped in safe APIs.
- Test unsafe abstractions with Miri where possible.
- Add property tests around boundary conditions.

---

## Quick Reference

| Pattern | Benefit |
|---|---|
| Private fields | Representation can change; invariants preserved |
| Sealed traits | Prevent unsupported downstream implementations |
| Small `Copy` newtypes | Type safety with zero runtime cost |
| `&str`, `&[T]`, `&Path` params | Avoid forced allocation and ownership transfer |
| `impl Iterator` returns | Lazy, allocation-free derived views |
| `Vec::with_capacity` | Avoid repeated reallocations |
| Enums for closed variants | Exhaustive, inline, no virtual dispatch |
| Generics for hot paths | Static dispatch and inlining |
| `dyn Trait` at boundaries | Runtime composition without generic explosion |
| `Cow<'a, str>` | Avoid common-case clone |
| Box rare large enum variants | Keep enum size small |
| Pure free functions | No hidden state, easy optimization |

---

## Anti-Patterns

```rust
// DON'T: accept owned String for read-only parsing.
pub fn parse_id(value: String) -> Result<OrderId, Error> { ... }

// DO: borrow.
pub fn parse_id(value: &str) -> Result<OrderId, Error> { ... }
```

```rust
// DON'T: expose Vec implementation.
pub fn items(&self) -> &Vec<OrderItem> { &self.items }

// DO: expose a slice.
pub fn items(&self) -> &[OrderItem] { &self.items }
```

```rust
// DON'T: dynamic dispatch in inner loop without reason.
fn score_all(rules: &[Box<dyn Rule>], orders: &[Order]) -> Vec<Score> { ... }

// DO: use enum or generics for known hot strategies.
enum RuleKind { Standard(StandardRule), Premium(PremiumRule) }
```

```rust
// DON'T: collect intermediate vectors reflexively.
let values = items.iter().map(a).collect::<Vec<_>>();
let values = values.iter().map(b).collect::<Vec<_>>();

// DO: chain and collect once, or use a loop if clearer.
let values = items.iter().map(a).map(b).collect::<Vec<_>>();
```

```rust
// DON'T: async pure function.
pub async fn calculate_total(items: &[OrderItem]) -> Money { ... }

// DO: sync pure function.
pub fn calculate_total(items: &[OrderItem]) -> Money { ... }
```

```rust
// DON'T: blanket clone.
let snapshot = value.clone();

// DO: borrow, move, or document the clone.
let snapshot = value.clone(); // intentional: immutable audit snapshot
```

---

## Review Checklist

- [ ] Are public fields necessary, or should representation be private?
- [ ] Can parameters be borrowed instead of owned?
- [ ] Are clones intentional and visible?
- [ ] Are intermediate collections avoided?
- [ ] Is `Copy` limited to cheap scalar values?
- [ ] Are closed variants modeled as enums?
- [ ] Are hot paths using static dispatch where appropriate?
- [ ] Are trait objects only at boundaries or measured hot paths?
- [ ] Are async functions actually doing async work?
- [ ] Is unsafe forbidden or tightly justified?
- [ ] Has performance-sensitive code been benchmarked?

---

## Resources

- Rust API Guidelines: https://rust-lang.github.io/api-guidelines/
- Rust Performance Book: https://nnethercote.github.io/perf-book/
- std::borrow::Cow: https://doc.rust-lang.org/std/borrow/enum.Cow.html
- Rustonomicon: https://doc.rust-lang.org/nomicon/
- Miri: https://github.com/rust-lang/miri
