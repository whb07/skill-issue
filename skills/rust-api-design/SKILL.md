---
name: rust-api-design
description: Design stable Rust public APIs and wire formats using extend-only principles, semantic versioning, non_exhaustive types, sealed traits, feature discipline, explicit DTOs, and compatibility testing. Avoid accidental breaking changes in crates, protocols, and FFI boundaries.
invocable: false
---

# Rust Public API Design and Compatibility

## When to Use This Skill

Use this skill when:

- Designing public APIs for Rust crates
- Making changes to exported types, traits, functions, modules, or feature flags
- Planning serialization or wire-format changes
- Reviewing pull requests for semver breaks
- Publishing crates to crates.io or maintaining internal shared crates
- Exposing FFI or plugin boundaries

---

## The Compatibility Model

Rust compatibility has more traps than it first appears.

| Type | Definition | Scope |
|---|---|---|
| **Source compatibility** | Existing downstream source still compiles | Public items, signatures, trait bounds, fields, variants, feature flags |
| **Semantic compatibility** | Existing downstream behavior still works | Defaults, invariants, errors, ordering, retries, timing |
| **Wire compatibility** | Old and new serialized data interoperate | JSON, protobuf, MessagePack, persistence, network protocols |
| **FFI/ABI compatibility** | External callers can safely link/call | `extern "C"`, `#[repr(C)]`, symbols, layout |

Rust has no stable Rust ABI. If ABI matters, expose a C-compatible API and treat it as a separate product.

---

## Extend-Only Design

The foundation of stable Rust APIs: **never remove or mutate released contracts; add new contracts alongside old ones.**

### Three Pillars

1. **Released behavior is immutable** - Once public, signatures and documented behavior are locked.
2. **New behavior uses new constructs** - Add new functions, types, builders, enum variants only when the type was designed for extension.
3. **Removal requires deprecation and a major version** - Give users time, warnings, and a migration path.

### Rust-Specific Rule

In Rust, “just adding something” can still break users. Adding trait methods, enum variants, trait impls, blanket impls, default features, or public fields can be breaking depending on the original shape. Design extension points up front.

---

## API Shape Defaults

### Prefer Private Fields

```rust
// DO: extensible; fields can change without breaking callers.
#[derive(Debug, Clone)]
pub struct ClientOptions {
    timeout: std::time::Duration,
    max_retries: u32,
}

impl ClientOptions {
    pub fn new() -> Self {
        Self {
            timeout: std::time::Duration::from_secs(30),
            max_retries: 3,
        }
    }

    pub fn with_timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_max_retries(mut self, max_retries: u32) -> Self {
        self.max_retries = max_retries;
        self
    }
}
```

```rust
// AVOID for public domain/config types: adding a required field breaks construction.
pub struct ClientOptions {
    pub timeout: std::time::Duration,
    pub max_retries: u32,
}
```

Public fields are acceptable for stable DTOs and simple data carriers, but once released they are hard to evolve.

### Use Builders for Growing Options

```rust
#[derive(Debug, Clone)]
pub struct ClientBuilder {
    endpoint: String,
    timeout: std::time::Duration,
    max_retries: u32,
}

impl ClientBuilder {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            timeout: std::time::Duration::from_secs(30),
            max_retries: 3,
        }
    }

    pub fn timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn max_retries(mut self, max_retries: u32) -> Self {
        self.max_retries = max_retries;
        self
    }

    pub fn build(self) -> Result<Client, ClientBuildError> {
        Client::new(self)
    }
}
```

**Builder rules:**

- Builders are better than long functions with many parameters.
- Builder methods should be additive and chainable.
- Keep defaults stable. If defaults must change, introduce a new named mode or builder method.
- Fallible build belongs in `build()`, not in every setter.

---

## Safe and Unsafe API Changes

### Usually Safe Changes

```rust
// SAFE: add a new free function.
pub fn parse_order_id(value: &str) -> Result<OrderId, ParseOrderIdError> { ... }

// SAFE: add a new inherent method with a distinct name.
impl Client {
    pub fn with_user_agent(mut self, user_agent: impl Into<String>) -> Self { ... }
}

// SAFE: add a new type.
pub struct RetryPolicy { ... }

// SAFE: add a default method to a trait.
pub trait Transport {
    fn send(&self, request: Request) -> Result<Response, TransportError>;

    fn send_with_timeout(
        &self,
        request: Request,
        _timeout: std::time::Duration,
    ) -> Result<Response, TransportError> {
        self.send(request)
    }
}

// SAFE if the enum was marked non_exhaustive before release.
#[non_exhaustive]
pub enum Event {
    Created,
    Updated,
    Deleted,
}
```

Even “safe” changes require review. New inherent methods can conflict with downstream trait methods in method-call syntax. New trait impls can affect type inference. Use semver tooling and changelog review.

### Breaking Changes

```rust
// BREAKING: remove or rename a public item.
pub fn submit_order(order: Order) { ... } // was process_order

// BREAKING: change parameter or return types.
pub fn get_order(id: OrderId) -> Result<Order, Error> { ... } // was Option<Order>

// BREAKING: add a required parameter.
pub fn send(request: Request, timeout: Duration) -> Result<Response, Error> { ... }

// BREAKING: add a required field to a public struct literal.
pub struct ClientOptions {
    pub timeout: Duration,
    pub max_retries: u32,
    pub user_agent: String, // breaks callers constructing ClientOptions { ... }
}

// BREAKING: add a variant to an exhaustive public enum.
pub enum OrderStatus {
    Draft,
    Submitted,
    Paid,
    Refunded, // breaks exhaustive matches downstream
}

// BREAKING: add a required trait method.
pub trait Transport {
    fn send(&self, request: Request) -> Result<Response, Error>;
    fn close(&self) -> Result<(), Error>; // breaks all implementors
}

// BREAKING: change trait bounds.
pub fn process<T: Send + Sync>(value: T) { ... } // was T: Send
```

### Compatibility Gray Areas

Treat these as requiring explicit review:

- Adding trait impls, especially blanket impls
- Adding inherent methods with common names like `get`, `new`, `into_inner`, `try_from`
- Tightening generic bounds
- Loosening generic bounds that change inference
- Changing auto-trait behavior (`Send`, `Sync`, `Unpin`) by changing fields
- Changing feature defaults
- Raising MSRV
- Changing error variants or error display text consumed by users
- Changing iteration order or hashing behavior when users may rely on it

---

## Deprecation Pattern

```rust
#[deprecated(
    since = "1.4.0",
    note = "use Client::send_request instead; this method will be removed in 2.0"
)]
pub fn send(&self, request: Request) -> Result<Response, Error> {
    self.send_request(request)
}

pub fn send_request(&self, request: Request) -> Result<Response, Error> {
    // new implementation
}
```

**Rules:**

- Deprecate in a minor release.
- Keep the old API working.
- Add the replacement in the same release.
- Include examples in the migration guide.
- Remove only in a planned major version.

---

## Designing Extensible Enums

### Closed Domain Enums

Use normal enums when exhaustive matching is part of the value proposition.

```rust
pub enum PaymentState {
    Pending,
    Authorized { authorization_id: String },
    Captured { receipt_id: String },
    Failed { reason: String },
}
```

Do not add variants to a released exhaustive enum without a major version.

### Extensible Public Enums

Use `#[non_exhaustive]` when you expect to add variants.

```rust
#[non_exhaustive]
pub enum ApiErrorKind {
    Timeout,
    RateLimited,
    Unauthorized,
}
```

Downstream callers must include a wildcard arm:

```rust
match error.kind() {
    ApiErrorKind::Timeout => retry(),
    ApiErrorKind::RateLimited => backoff(),
    ApiErrorKind::Unauthorized => refresh_credentials(),
    _ => report_unknown(error),
}
```

**Enum rules:**

- Closed business invariants: exhaustive enum.
- Public error kinds and protocol event categories: `#[non_exhaustive]` unless truly closed forever.
- Wire enums: include `Unknown(value)` or preserve raw numeric/string representation when forward compatibility matters.

---

## Traits as Public Contracts

Traits are the easiest Rust API surface to accidentally freeze.

### Keep Traits Small

```rust
pub trait Clock {
    fn now(&self) -> time::OffsetDateTime;
}
```

### Default New Methods

```rust
pub trait Store {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError>;

    fn contains_key(&self, key: &str) -> Result<bool, StoreError> {
        Ok(self.get(key)?.is_some())
    }
}
```

### Seal Traits Not Meant for Users

```rust
mod sealed {
    pub trait Sealed {}
}

pub trait Event: sealed::Sealed {
    fn name(&self) -> &'static str;
}

pub struct OrderCreated;

impl sealed::Sealed for OrderCreated {}

impl Event for OrderCreated {
    fn name(&self) -> &'static str {
        "order.created"
    }
}
```

**Trait rules:**

- Public traits imply users can implement them unless sealed.
- Adding a required method is breaking.
- Blanket impls are dangerous; they can conflict with downstream code.
- Prefer sealed traits for marker traits, internal extension traits, and protocol families controlled by the crate.
- Prefer inherent methods for behavior on your own types.
- Avoid object-safety surprises: decide whether `dyn Trait` is supported and test it.

---

## Feature Flags

Feature flags are API.

```toml
[features]
default = ["rustls"]
rustls = ["dep:rustls"]
native-tls = ["dep:native-tls"]
json = ["dep:serde", "dep:serde_json"]
```

**Feature rules:**

- Features should be additive. Enabling a feature should not remove APIs.
- Avoid mutually exclusive features. If unavoidable, fail fast with `compile_error!`.
- Do not add heavy default features casually.
- Removing a feature or dependency exposed through a feature is breaking.
- Changing default features can be breaking even in a minor release.
- Test feature combinations with `cargo hack` for shared crates.

---

## MSRV Policy

Minimum Supported Rust Version is part of the contract.

```text
MSRV: 1.85.0
Policy: MSRV may increase only in minor releases and will be called out in release notes.
```

**Rules:**

- Declare `rust-version` in `Cargo.toml`.
- CI should test MSRV if the crate promises one.
- Do not raise MSRV in a patch release unless the project explicitly allows it.
- Mention MSRV changes in the changelog.

---

## Wire Compatibility

For distributed systems, old and new versions must read each other's data during rolling upgrades.

| Direction | Requirement |
|---|---|
| **Backward compatibility** | New readers can read old data |
| **Forward compatibility** | Old readers can tolerate new data |

Both matter for zero-downtime deployments.

### Versioned DTOs, Not Domain Types

```rust
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct HeartbeatV1 {
    pub from: String,
    pub sequence: u64,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct HeartbeatV2 {
    pub from: String,
    pub sequence: u64,
    #[serde(default)]
    pub created_at_unix_ms: Option<i64>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum WireMessage {
    #[serde(rename = "heartbeat.v1")]
    HeartbeatV1(HeartbeatV1),

    #[serde(rename = "heartbeat.v2")]
    HeartbeatV2(HeartbeatV2),
}
```

### Rolling Upgrade Pattern

1. **Read first** - Deploy code that can read old and new formats.
2. **Write opt-in** - Add a config flag to emit the new format.
3. **Enable gradually** - Turn on new writes after all readers understand them.
4. **Make default later** - Only after the fleet and persisted data are safe.
5. **Remove much later** - Usually a major version or explicit data migration.

### Serde Rules

- Use explicit DTOs for wire contracts.
- Use `#[serde(default)]` for newly added optional fields.
- Use `#[serde(skip_serializing_if = "Option::is_none")]` for optional output fields.
- Use tagged enums for protocols, not Rust type names.
- Avoid `deny_unknown_fields` for formats that must tolerate forward-compatible fields.
- Do not rely on struct field order unless the format requires it and tests lock it down.
- Be careful with `bincode` and similar binary formats; configuration and type shape changes can be wire breaks.

### Schema Formats

Prefer schema-based formats for long-lived protocols:

| Format | Compatibility Notes |
|---|---|
| Protocol Buffers | Strong field-number compatibility; reserve removed fields |
| Avro / JSON Schema | Good for data platforms with schema registry discipline |
| JSON with explicit DTOs | Human-readable; forward compatibility requires conventions |
| MessagePack with explicit schema conventions | Compact; avoid type-shape coupling |
| bincode/postcard | Great for controlled environments; risky for public long-lived protocols |

---

## FFI and ABI Compatibility

Rust-to-Rust ABI is not stable. Public Rust functions are not plugin ABI.

```rust
#[repr(C)]
pub struct ApiResult {
    pub code: i32,
    pub data: *mut std::ffi::c_void,
}

#[no_mangle]
pub extern "C" fn client_create() -> ApiResult {
    // C-compatible boundary only
}
```

**FFI rules:**

- Use `extern "C"` and `#[repr(C)]` / `#[repr(transparent)]` for layout-sensitive types.
- Do not expose Rust `String`, `Vec<T>`, `Result<T, E>`, trait objects, or panics across FFI.
- Provide explicit create/free functions for ownership transfer.
- Treat symbol names, struct layout, and allocation rules as frozen API.
- Add ABI tests if consumers link dynamically.

---

## API Compatibility Testing

### cargo-semver-checks

Use semver checks in CI for published crates:

```bash
cargo install cargo-semver-checks
cargo semver-checks check-release
```

### cargo-public-api

Review public surface diffs:

```bash
cargo install cargo-public-api
cargo public-api > public-api.txt
```

Check `public-api.txt` into the repo for API approval testing when the crate is stable.

### Feature Matrix

```bash
cargo install cargo-hack
cargo hack check --feature-powerset --no-dev-deps
```

### Wire Golden Tests

Store representative payloads from previous versions:

```rust
#[test]
fn reads_v1_heartbeat_payload() {
    let payload = include_str!("fixtures/heartbeat-v1.json");
    let message: WireMessage = serde_json::from_str(payload).unwrap();

    assert!(matches!(message, WireMessage::HeartbeatV1(_)));
}
```

**Testing rules:**

- Public API changes must be visible in review.
- Wire format changes need old payload fixtures.
- Feature combinations need CI coverage.
- MSRV needs CI if promised.

---

## Versioning Strategy

### SemVer for Rust Crates

| Version | Allowed Changes |
|---|---|
| **Patch** `1.2.x` | Bug fixes, docs, internal refactors, compatible behavior fixes |
| **Minor** `1.x.0` | Additive APIs, deprecations, additive features, compatible MSRV bump if policy allows |
| **Major** `x.0.0` | Breaking API removals, signature changes, exhaustive enum expansion, major behavior changes |

### Practical Rules

1. **Patch releases must be boring.** Users should upgrade automatically.
2. **Minor releases can add but not surprise.** Add APIs, do not flip defaults carelessly.
3. **Major releases need migration guides.** A major version is not permission to be vague.
4. **Deprecate before remove.** Warnings are a migration tool.
5. **Document behavior, not just signatures.** Semantic changes break users too.

---

## Pull Request Checklist

When reviewing public API or wire changes:

- [ ] No removed public items without major-version plan
- [ ] No changed signatures without new API/deprecation path
- [ ] No new required fields on public structs
- [ ] No new required trait methods
- [ ] No new variants on exhaustive public enums
- [ ] `#[non_exhaustive]` used where future growth is expected
- [ ] Traits sealed when users should not implement them
- [ ] Feature changes are additive and tested
- [ ] MSRV change is intentional and documented
- [ ] Wire readers support old payloads
- [ ] New wire writes are opt-in during rolling upgrade
- [ ] Public API diff or semver check reviewed
- [ ] Changelog and migration notes updated

---

## Anti-Patterns

### Public Struct Literals for Growing Config

```rust
// BAD: every new option is a breaking field addition.
pub struct ClientConfig {
    pub endpoint: String,
    pub timeout: Duration,
}

// GOOD: private fields plus builder.
pub struct ClientConfig {
    endpoint: String,
    timeout: Duration,
}
```

### Exhaustive Error Enum That Will Grow

```rust
// BAD: adding RateLimited later breaks downstream matches.
pub enum ClientErrorKind {
    Timeout,
    Unauthorized,
}

// GOOD: non_exhaustive if this is public and likely to grow.
#[non_exhaustive]
pub enum ClientErrorKind {
    Timeout,
    Unauthorized,
}
```

### Required Trait Method Added Later

```rust
// BAD: breaks every downstream impl.
pub trait Store {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, Error>;
    fn delete(&self, key: &str) -> Result<(), Error>;
}

// GOOD: default method or new extension trait.
pub trait StoreDeleteExt: Store {
    fn delete(&self, key: &str) -> Result<(), Error>;
}
```

### Rust Type Names in Wire Format

```json
{
  "type": "my_crate::orders::OrderCreated",
  "payload": { "id": "..." }
}
```

Use stable protocol names instead:

```json
{
  "type": "order.created.v1",
  "payload": { "id": "..." }
}
```

### Behavior Break Disguised as Cleanup

```rust
// BAD: changed default timeout from 30s to 5s in a patch release.
ClientOptions::new()

// GOOD: add a new explicit mode.
ClientOptions::new().with_fast_fail_defaults()
```

---

## Resources

- Rust API Guidelines: https://rust-lang.github.io/api-guidelines/
- Cargo SemVer Compatibility: https://doc.rust-lang.org/cargo/reference/semver.html
- cargo-semver-checks: https://github.com/obi1kenobi/cargo-semver-checks
- cargo-public-api: https://github.com/Enselic/cargo-public-api
- SemVer: https://semver.org/
