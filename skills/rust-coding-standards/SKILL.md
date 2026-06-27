---
name: modern-rust-coding-standards
description: Write, refactor, and review idiomatic modern Rust code using ownership-first design, private invariants, typed domain models, enums, Option/Result, explicit error handling, borrowing over cloning, small traits, explicit DTO mapping, async discipline, and measured unsafe. Use when implementing Rust features, translating object-oriented designs into Rust, reviewing Rust code quality, or correcting needless cloning, stringly typed state, panics, weak errors, broad traits, hidden allocation, or blocking async code.
---

# Modern Rust Coding Standards

## Operating Model

Design Rust code around ownership, invariants, and explicit states. Prefer types that make invalid states unrepresentable, APIs that reveal ownership intent, and errors that callers can handle.

Default stance:

1. Model the domain before choosing abstractions.
2. Keep invariants behind constructors and private fields.
3. Borrow inputs unless the function must take ownership.
4. Use enums, newtypes, `Option`, and `Result` instead of strings, booleans, sentinels, null-like values, and panics.
5. Keep traits small and behavior-focused.
6. Make conversions explicit and reviewable.
7. Keep async at I/O boundaries.
8. Use unsafe only with a written proof, tests, and a reason safe Rust cannot meet.

Good Rust is usually direct. Avoid clever abstractions that hide ownership, allocation, control flow, or error behavior.

## Project Defaults

For new application crates, prefer this baseline and adjust only with project-specific reasons:

```toml
[package]
edition = "2024"
rust-version = "1.85"

[lints.rust]
unsafe_code = "forbid"
missing_docs = "warn"

[lints.clippy]
all = "warn"
pedantic = "warn"
nursery = "warn"
unwrap_used = "warn"
expect_used = "warn"
panic = "warn"
```

Lint rules:

- Keep `cargo fmt` mandatory.
- Run `cargo clippy --all-targets --all-features` for shared crates when feasible.
- Suppress lints locally with a reason instead of relaxing crate-wide policy casually.
- Relax `missing_docs`, `pedantic`, or `nursery` for prototypes or binaries when the noise outweighs the benefit.
- For library crates, pair coding style with API compatibility review.

## Domain Types

### Structs for Invariants

Use structs for named data with invariants. Keep fields private unless the type is intentionally a plain data carrier.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Customer {
    id: CustomerId,
    email: EmailAddress,
    name: String,
}

impl Customer {
    pub fn new(id: CustomerId, email: EmailAddress, name: impl Into<String>) -> Result<Self, CustomerError> {
        let name = name.into();
        if name.trim().is_empty() {
            return Err(CustomerError::EmptyName);
        }

        Ok(Self { id, email, name })
    }

    pub fn id(&self) -> CustomerId {
        self.id
    }

    pub fn email(&self) -> &EmailAddress {
        &self.email
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}
```

Struct rules:

- Keep domain fields private.
- Expose read-only accessors that preserve invariants.
- Use public fields for DTOs, test fixtures, and simple value aggregates only when literal construction is intended.
- Do not expose `&mut Vec<T>` or other mutable internals unless mutation is the API.
- Prefer fallible constructors when input validation can fail.

### Newtypes for Values

Wrap IDs, validated text, money, counts, percentages, handles, and other values where raw primitives lose meaning.

```rust
use std::{fmt, str::FromStr};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OrderId(Uuid);

impl OrderId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    pub fn from_uuid(value: Uuid) -> Self {
        Self(value)
    }

    pub fn as_uuid(self) -> Uuid {
        self.0
    }
}

impl fmt::Display for OrderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for OrderId {
    type Err = uuid::Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Uuid::parse_str(value).map(Self)
    }
}
```

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmailAddress(String);

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EmailAddressError {
    #[error("email is empty")]
    Empty,
    #[error("email is missing @")]
    MissingAtSign,
}

impl EmailAddress {
    pub fn parse(value: impl Into<String>) -> Result<Self, EmailAddressError> {
        let value = value.into();
        let trimmed = value.trim();

        if trimmed.is_empty() {
            return Err(EmailAddressError::Empty);
        }
        if !trimmed.contains('@') {
            return Err(EmailAddressError::MissingAtSign);
        }

        Ok(Self(trimmed.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
```

Newtype rules:

- Derive `Copy` only for small scalar wrappers where duplication is cheap and semantically invisible.
- Prefer `parse`, `try_new`, `FromStr`, or `TryFrom` for validated values.
- Implement `Display` for stable text output.
- Avoid `Deref<Target = str>` for domain wrappers; it leaks representation and weakens invariants.
- Use `#[repr(transparent)]` only for layout guarantees such as FFI.

## Enums and State

Use enums for closed sets, state machines, commands, and protocol messages. Do not encode state as strings, booleans, or nullable field clusters.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OrderStatus {
    Draft,
    Submitted,
    Paid { receipt_id: String },
    Shipped { tracking_number: String },
    Cancelled { reason: String },
}

pub fn can_cancel(status: &OrderStatus) -> bool {
    matches!(status, OrderStatus::Draft | OrderStatus::Submitted | OrderStatus::Paid { .. })
}

pub fn status_label(status: &OrderStatus) -> &'static str {
    match status {
        OrderStatus::Draft => "draft",
        OrderStatus::Submitted => "submitted",
        OrderStatus::Paid { .. } => "paid",
        OrderStatus::Shipped { .. } => "shipped",
        OrderStatus::Cancelled { .. } => "cancelled",
    }
}
```

Enum rules:

- Prefer exhaustive `match` in domain logic.
- Avoid `_` when a future variant should force a decision.
- Use `if let` for one interesting case, `let ... else` for guard extraction, and `matches!` for predicates.
- Put state-specific data in the variant that owns it.
- Use `#[non_exhaustive]` only when designing public APIs that must grow without breaking downstream matches.

## Option, Result, and Panics

Use `Option<T>` for absence and `Result<T, E>` for expected failure.

```rust
pub fn find_customer(id: CustomerId, customers: &[Customer]) -> Option<&Customer> {
    customers.iter().find(|customer| customer.id() == id)
}
```

```rust
#[derive(Debug, thiserror::Error)]
pub enum CheckoutError {
    #[error("cart is empty")]
    EmptyCart,

    #[error("payment failed: {0}")]
    PaymentFailed(String),
}

pub fn checkout(cart: &Cart, payment: &PaymentMethod) -> Result<Order, CheckoutError> {
    if cart.items().is_empty() {
        return Err(CheckoutError::EmptyCart);
    }

    charge(payment, cart.total()).map_err(|err| CheckoutError::PaymentFailed(err.to_string()))?;

    Ok(Order::from_cart(cart))
}
```

Error rules:

- Library crates should expose typed errors callers can match or inspect.
- Binary crates may use `anyhow` at the outer orchestration layer.
- Do not return `String` or `Box<dyn Error>` from stable library APIs unless type erasure is deliberate.
- Use `?` and `map_err` to preserve context.
- Do not `unwrap()` in production paths.
- Use `expect()` only when the message documents an invariant, such as `expect("static regex must compile")`.
- Use `panic!` for bugs, impossible states, and tests; not for ordinary input validation.

## Borrowing and Ownership

Accept borrowed data by default:

```rust
use std::path::Path;

pub fn normalize_email(email: &str) -> String {
    email.trim().to_ascii_lowercase()
}

pub fn read_config(path: &Path) -> std::io::Result<Config> {
    let text = std::fs::read_to_string(path)?;
    toml::from_str(&text).map_err(std::io::Error::other)
}

pub fn total(items: &[OrderItem]) -> Money {
    items.iter().map(OrderItem::total).sum()
}
```

Parameter rules:

| Need | Accept |
|---|---|
| Read text | `&str` |
| Read bytes | `&[u8]` |
| Read a path | `&Path` |
| Read a sequence | `&[T]` |
| Consume a sequence | `impl IntoIterator<Item = T>` |
| Maybe borrow or own text | `Cow<'a, str>` |
| Store for later | `String`, `Vec<T>`, `PathBuf`, `Arc<T>` |
| Mutate caller data | `&mut T` or `&mut [T]` |

Clone rules:

- Do not clone to appease the borrow checker before understanding ownership.
- Prefer accessors that return borrowed views: `&str`, `&[T]`, `&Path`, `Option<&T>`.
- Make intentional clones visible with a variable name or short comment when the cost or reason is non-obvious.
- Use `Arc<T>` for shared ownership across tasks or threads; do not use it to avoid designing ownership.

```rust
let snapshot = current_state.clone(); // intentional: audit task needs an immutable snapshot
```

## Traits and Composition

Traits define capabilities, not inheritance trees.

```rust
pub trait Clock {
    fn now(&self) -> time::OffsetDateTime;
}
```

Prefer small traits owned by the consumer:

```rust
pub trait SendReceipt {
    fn send_receipt(&self, order: &Order) -> Result<(), ReceiptError>;
}

pub fn complete_order(sender: &impl SendReceipt, order: Order) -> Result<Order, ReceiptError> {
    sender.send_receipt(&order)?;
    Ok(order.mark_completed())
}
```

Trait rules:

- Create a trait when multiple implementations, a boundary, or a test substitute is real.
- Keep traits small; one to three methods is often enough.
- Prefer inherent methods for behavior on types you own.
- Prefer generics (`T: Trait`) in hot paths and `dyn Trait` at runtime boundaries.
- Avoid blanket impls unless coherence and downstream conflicts have been reviewed.
- Avoid `async_trait` in hot paths because it usually boxes futures.
- Use native `async fn` in traits or associated future types when performance and allocation matter.
- Do not build broad repository or service base classes with traits.

## Explicit Mapping

Keep domain types separate from wire, storage, and UI DTOs. Map explicitly.

```rust
#[derive(Debug, serde::Serialize)]
pub struct OrderDto {
    pub id: String,
    pub customer_id: String,
    pub total_cents: i64,
    pub currency: String,
}

impl From<&Order> for OrderDto {
    fn from(order: &Order) -> Self {
        Self {
            id: order.id().to_string(),
            customer_id: order.customer_id().to_string(),
            total_cents: order.total().cents(),
            currency: order.total().currency().to_owned(),
        }
    }
}
```

Inbound mapping should be fallible:

```rust
#[derive(Debug, serde::Deserialize)]
pub struct CreateOrderRequest {
    pub customer_id: String,
    pub items: Vec<CreateOrderItemRequest>,
}

impl TryFrom<CreateOrderRequest> for CreateOrderCommand {
    type Error = CreateOrderError;

    fn try_from(request: CreateOrderRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            customer_id: request.customer_id.parse()?,
            items: request
                .items
                .into_iter()
                .map(OrderItemCommand::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}
```

Mapping rules:

- Use `From` only for infallible conversions.
- Use `TryFrom` for validation, parsing, and domain construction.
- Do not serialize domain objects directly unless the domain type is explicitly a wire type.
- Avoid macro-heavy field mapping across domain boundaries.
- Keep serde attributes on DTOs, not core domain types, unless serialization is the domain purpose.

## Async Discipline

Async Rust is cooperative. Keep async at I/O and scheduling boundaries.

```rust
pub async fn load_dashboard(
    user_id: UserId,
    orders: &OrderClient,
    notifications: &NotificationClient,
) -> Result<Dashboard, DashboardError> {
    let (orders, notifications) = tokio::try_join!(
        orders.recent_orders(user_id),
        notifications.unread(user_id),
    )?;

    Ok(Dashboard { orders, notifications })
}
```

Async rules:

- Do not make pure CPU functions async.
- Do not call `std::thread::sleep`, blocking file I/O, or blocking database clients inside async tasks.
- Use `tokio::task::spawn_blocking` for unavoidable blocking work.
- Do not hold `MutexGuard`, `RefCell` borrows, or other synchronous guards across `.await`.
- Prefer bounded channels for background work.
- Decide how every spawned task shuts down.
- Propagate cancellation intentionally; dropped handles and immortal tasks are bugs.

## Unsafe

Default to safe Rust.

Require all of the following before accepting `unsafe`:

- A clear reason safe Rust is insufficient.
- A safety comment explaining the invariants the block relies on.
- Tests that exercise boundary conditions.
- Fuzzing, Miri, sanitizers, or benchmarks when the risk justifies it.
- A narrow unsafe surface wrapped by a safe API.

Do not use unsafe to bypass ownership, lifetime, or concurrency design problems.

## Code Organization

Prefer domain-first modules with explicit public surfaces.

```text
src/
  lib.rs
  orders/
    mod.rs
    order.rs
    order_id.rs
    status.rs
    commands.rs
    errors.rs
    dto.rs
```

```rust
mod commands;
mod errors;
mod order;
mod order_id;
mod status;

pub use commands::{CreateOrderCommand, SubmitOrderCommand};
pub use errors::OrderError;
pub use order::Order;
pub use order_id::OrderId;
pub use status::OrderStatus;
```

Module rules:

- Keep implementation details private by default.
- Re-export only the intended API from `mod.rs` or `lib.rs`.
- Avoid exposing internal module paths accidentally.
- Use integration tests for public behavior and unit tests for private invariants.

## Testing Standards

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_email() {
        let result = EmailAddress::parse("   ");
        assert_eq!(result, Err(EmailAddressError::Empty));
    }

    #[test]
    fn accepts_valid_email() {
        let email = EmailAddress::parse("USER@example.com").unwrap();
        assert_eq!(email.as_str(), "USER@example.com");
    }
}
```

Testing rules:

- Tests may use `unwrap()` when failure should fail the test immediately.
- Prefer table-driven tests for business rules.
- Use `proptest` for parsers, serialization, and value objects with invariants.
- Use `insta` snapshots for stable textual output, not for complex domain behavior.
- Test public behavior more than private implementation details.
- Add regression tests before fixing subtle ownership, parsing, serialization, or concurrency bugs.

## Review Checklist

Use this checklist for Rust implementation and refactor reviews:

- [ ] Domain states are represented with types, not strings, booleans, or nullable clusters.
- [ ] Constructors preserve invariants and are fallible when input can be invalid.
- [ ] Domain fields are private unless public literal construction is intentional.
- [ ] Absence uses `Option`; expected failure uses typed `Result`.
- [ ] `unwrap`, `expect`, and `panic` are absent from production paths or justified by invariants.
- [ ] Function parameters borrow by default and take ownership only when needed.
- [ ] Clones are necessary, cheap, or deliberately documented.
- [ ] Traits are small, capability-focused, and justified by a real boundary.
- [ ] DTO mapping is explicit and fallible where validation is required.
- [ ] Async code avoids blocking calls and synchronous guards across `.await`.
- [ ] Unsafe code has a safety comment, tests, and a narrow safe wrapper.
- [ ] `cargo fmt`, `cargo clippy`, and relevant tests have been run.

## Common Anti-Patterns

### Stringly Typed State

```rust
pub struct Order {
    pub status: String,
}
```

Use an enum instead.

### Nullable State Clusters

```rust
pub struct Order {
    pub status: OrderStatus,
    pub receipt_id: Option<String>,
    pub cancel_reason: Option<String>,
}
```

Put state-specific data on enum variants.

### Panics for Input Failure

```rust
pub fn parse_quantity(value: &str) -> Quantity {
    Quantity(value.parse().unwrap())
}
```

Return a typed error.

### Habitual Cloning

```rust
fn render(user: User) -> String {
    format!("{}", user.name.clone())
}
```

Borrow instead.

### Broad Base Traits

```rust
pub trait Repository {
    fn get_order(&self, id: OrderId) -> Result<Order, Error>;
    fn save_order(&self, order: Order) -> Result<(), Error>;
    fn get_customer(&self, id: CustomerId) -> Result<Customer, Error>;
    fn save_customer(&self, customer: Customer) -> Result<(), Error>;
}
```

Use small traits per consumer.
