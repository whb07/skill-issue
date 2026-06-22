---
name: modern-rust-coding-standards
description: Write modern, high-performance Rust using ownership-first design, enums and pattern matching, Option/Result, newtype value objects, explicit mapping, zero-copy borrowing, and small trait boundaries. Avoid reflection-like magic, global mutable state, and unnecessary cloning.
invocable: false
---

# Modern Rust Coding Standards

## When to Use This Skill

Use this skill when:

- Writing new Rust code or refactoring existing Rust code
- Designing domain models, messages, DTOs, or library APIs
- Translating class-heavy code into idiomatic Rust
- Reviewing code for needless cloning, weak typing, panics, or async misuse
- Building code that must be maintainable, testable, and fast without cleverness

---

## Core Principles

1. **Ownership is the design tool** - Model who owns data before writing code.
2. **Immutability by default** - Use `let`, private fields, and constructors that preserve invariants.
3. **Types over conventions** - Use newtypes, enums, and `Result` instead of strings, booleans, sentinels, and comments.
4. **Pattern matching over condition soup** - Make state explicit and exhaustive.
5. **Borrow before you clone** - Accept `&str`, `&[T]`, `&Path`, and iterators unless ownership is required.
6. **Explicit errors** - `Result<T, E>` for expected failures, `Option<T>` for absence, `panic!` only for bugs and tests.
7. **Traits are boundaries, not base classes** - Keep traits small and behavior-focused.
8. **No magic mapping** - Use `From`, `TryFrom`, explicit functions, and reviewed serde DTOs. Do not hide business mapping behind macro-heavy frameworks.
9. **Async is for I/O boundaries** - Do not make pure code async. Do not block inside async tasks.
10. **Unsafe must earn its keep** - Default to safe Rust. Require benchmarks, comments, and tests for every `unsafe` block.

---

## Project Defaults

For application crates, prefer this baseline:

```toml
# Cargo.toml
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

Adjust `missing_docs` and `pedantic` per crate maturity, but do not disable lints casually. If a lint is wrong for the codebase, suppress it locally with a comment explaining why.

---

## Domain Modeling

### Structs for Product Types

Use structs for named data with invariants. Keep fields private unless the type is a dumb DTO.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Customer {
    id: CustomerId,
    email: EmailAddress,
    name: String,
}

impl Customer {
    pub fn new(id: CustomerId, email: EmailAddress, name: impl Into<String>) -> Self {
        let name = name.into();
        assert!(!name.trim().is_empty(), "customer name cannot be empty");

        Self { id, email, name }
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

**Rules:**

- Prefer private fields plus accessors for domain types.
- Use public fields only for wire DTOs, config structs, and simple data carriers.
- Do not expose internal collections as mutable references unless mutation is the API.
- Use `impl Into<String>` at constructors, not everywhere. Internal functions should usually take `&str`.

### Newtypes for Value Objects

Primitive obsession is a bug factory. Wrap IDs, email addresses, money, counts, and percentages.

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmailAddressError {
    Empty,
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

**Newtype rules:**

- Derive `Copy` only for small scalar wrappers where copying is semantically cheap.
- Prefer `parse`, `try_new`, or `TryFrom` for validated values.
- Prefer `Display` and `FromStr` for text conversions.
- Avoid `Deref<Target = str>` for domain wrappers; it leaks representation and blurs invariants.
- Use `#[repr(transparent)]` only when FFI/layout compatibility matters.

---

## Enums and Pattern Matching

Use enums for closed sets, state machines, commands, and protocol messages. Do not encode state as loose strings.

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

**Pattern matching rules:**

- Match on domain states, not on string constants.
- Prefer exhaustive `match` over `_` in business logic. `_` hides future cases.
- Use `if let` for one interesting case, `matches!` for predicates, and `let ... else` for guard extraction.
- Keep enum variants data-rich. A `Paid { receipt_id }` variant is better than `status == Paid` plus a nullable `receipt_id` field.

---

## Option, Result, and Panics

Rust has no null. Do not reintroduce it with sentinels.

```rust
pub fn find_customer(id: CustomerId, customers: &[Customer]) -> Option<&Customer> {
    customers.iter().find(|customer| customer.id() == id)
}
```

Use `Result` for expected failures:

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

    charge(payment, cart.total())
        .map_err(|err| CheckoutError::PaymentFailed(err.to_string()))?;

    Ok(Order::from_cart(cart))
}
```

**Error rules:**

- Library crates expose typed errors. `thiserror` is fine because it does not leak into the public API unless you choose to expose it.
- Binary crates may use `anyhow` at the top level.
- Do not return `String` as an error from library APIs.
- Do not `unwrap()` in production code. Use `?`, typed errors, or explicit recovery.
- `expect()` is acceptable only when the message proves an invariant: `expect("static regex must compile")`.
- `panic!` means a bug, impossible state, or test failure. It is not input validation.

---

## Borrowing and Ownership

### Accept Borrowed Data by Default

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

**Parameter rules:**

| Need | Accept |
|---|---|
| Text read-only | `&str` |
| Bytes read-only | `&[u8]` |
| Path read-only | `&Path` |
| Sequence read-only | `&[T]` or `impl IntoIterator<Item = T>` depending on ownership |
| Maybe owned text | `Cow<'a, str>` |
| Store for later | `String`, `Vec<T>`, `PathBuf`, or `Arc<T>` |
| Mutate caller data | `&mut T` or `&mut [T]` |

### Clone Deliberately

```rust
// BAD: clone to satisfy the borrow checker without understanding ownership.
let email = customer.email().clone();
send_email(email.as_str());

// GOOD: borrow the value.
send_email(customer.email().as_str());
```

If a clone is intentional, make it visible:

```rust
let snapshot = current_state.clone(); // intentional: audit task needs an immutable snapshot
```

---

## Traits and Composition

Traits are not base classes. They define a narrow capability.

```rust
pub trait Clock {
    fn now(&self) -> time::OffsetDateTime;
}

pub trait OrderRepository {
    fn get(&self, id: OrderId) -> impl Future<Output = Result<Option<Order>, RepositoryError>> + Send;
    fn save(&self, order: Order) -> impl Future<Output = Result<(), RepositoryError>> + Send;
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

**Trait rules:**

- Keep traits small. One to three methods is usually enough.
- Do not create a trait just because a type exists. Create a trait when multiple implementations or test seams are real.
- Prefer generics (`T: Trait`) for hot paths and static dispatch.
- Prefer `dyn Trait` at application boundaries where plugin-like behavior is needed.
- Avoid `async_trait` in hot paths; it boxes futures. Use native `async fn` in traits or explicit associated future types when performance matters.
- Do not build inheritance trees with traits. Compose capabilities.

---

## Explicit Mapping, No Magic

Rust does not have runtime reflection in the C# sense. Do not replace it with unreviewable macro mapping.

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

Inbound mappings should be fallible:

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

**Mapping rules:**

- Use separate DTOs for wire shape and domain types.
- Use `From` only for infallible conversions.
- Use `TryFrom` for validation, parsing, and domain construction.
- Do not use broad derive macros that silently copy fields across domain boundaries.
- Avoid serializing domain objects directly unless the domain type is explicitly a wire type.

---

## Async Coding Standards

Async Rust is cooperative. Blocking inside it harms the whole runtime.

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

**Async rules:**

- Do not make pure CPU functions async.
- Do not call `std::thread::sleep`, blocking file I/O, or blocking database clients inside async tasks.
- Use `tokio::task::spawn_blocking` for unavoidable blocking work.
- Do not hold a `MutexGuard` across `.await`.
- Prefer bounded channels for background work.
- Always decide how tasks shut down. Dropped handles and immortal tasks are bugs.

---

## Code Organization

Prefer domain-first modules with explicit public surfaces.

```text
src/
  lib.rs
  orders/
    mod.rs          # public exports for the orders module
    order.rs        # primary aggregate
    order_id.rs     # value object
    status.rs       # enum state
    commands.rs     # command types
    errors.rs       # typed errors
    dto.rs          # wire/API DTOs if needed
```

```rust
// src/orders/mod.rs
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

**Module rules:**

- Keep implementation details private by default.
- Re-export only the intended API from `mod.rs` or `lib.rs`.
- Do not expose internal module paths as part of public API accidentally.
- Use integration tests for public API behavior and unit tests for private invariants.

---

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
    fn normalizes_valid_email() {
        let email = EmailAddress::parse("  USER@example.com  ").unwrap();
        assert_eq!(email.as_str(), "USER@example.com");
    }
}
```

**Testing rules:**

- Tests may use `unwrap()` when failure should fail the test immediately.
- Prefer table-driven tests for business rules.
- Use `proptest` for parsers, serialization, and value objects with invariants.
- Use `insta` snapshots for stable textual outputs, not for complex domain behavior.
- Test public behavior, not private implementation details.

---

## Anti-Patterns

```rust
// DON'T: stringly typed state.
pub struct Order {
    pub status: String,
}

// DO: typed state.
pub enum OrderStatus {
    Draft,
    Submitted,
    Paid,
}
```

```rust
// DON'T: optional fields that only make sense in certain states.
pub struct Order {
    pub status: OrderStatus,
    pub receipt_id: Option<String>,
    pub cancel_reason: Option<String>,
}

// DO: state carries its own data.
pub enum OrderStatus {
    Paid { receipt_id: String },
    Cancelled { reason: String },
}
```

```rust
// DON'T: panic for expected input failure.
pub fn parse_quantity(value: &str) -> Quantity {
    Quantity(value.parse().unwrap())
}

// DO: return a typed error.
pub fn parse_quantity(value: &str) -> Result<Quantity, ParseQuantityError> {
    let parsed = value.parse()?;
    Quantity::try_new(parsed)
}
```

```rust
// DON'T: clone as a habit.
fn render(user: User) -> String {
    format!("{}", user.name.clone())
}

// DO: borrow.
fn render(user: &User) -> String {
    user.name().to_owned()
}
```

```rust
// DON'T: massive trait as a fake repository base class.
pub trait Repository {
    fn get_order(&self, id: OrderId) -> Result<Order, Error>;
    fn save_order(&self, order: Order) -> Result<(), Error>;
    fn get_customer(&self, id: CustomerId) -> Result<Customer, Error>;
    fn save_customer(&self, customer: Customer) -> Result<(), Error>;
}

// DO: small traits per consumer.
pub trait LoadOrder {
    fn load_order(&self, id: OrderId) -> Result<Option<Order>, Error>;
}
```

---

## Best Practices Summary

### DO

- Use structs with private fields for domain types.
- Use newtypes for IDs, validated text, quantities, and money.
- Use enums for state and protocol variants.
- Use `Option` for absence and `Result` for expected failure.
- Use `match`, `if let`, `let ... else`, and `matches!` instead of flags and casts.
- Accept borrowed inputs by default: `&str`, `&[T]`, `&Path`.
- Return owned values when transferring ownership across API boundaries.
- Use `From` and `TryFrom` for explicit mapping.
- Keep traits small and local to the consumer.
- Run `cargo fmt`, `cargo clippy`, and tests before review.

### DON'T

- Do not encode state as strings or nullable field clusters.
- Do not use `unwrap`, `expect`, or `panic` for ordinary input failures.
- Do not expose mutable collections from public APIs.
- Do not clone to appease the compiler without understanding ownership.
- Do not use macro-heavy mapping to hide business conversions.
- Do not create traits for every struct.
- Do not block inside async code.
- Do not use `unsafe` for convenience.

---

## Additional Resources

- The Rust Book: https://doc.rust-lang.org/book/
- Rust API Guidelines: https://rust-lang.github.io/api-guidelines/
- Error Handling in Rust: https://doc.rust-lang.org/book/ch09-00-error-handling.html
- Clippy: https://doc.rust-lang.org/clippy/
