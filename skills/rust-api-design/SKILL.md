---
name: rust-api-design
description: Design and review stable Rust public APIs, semver-sensitive crate changes, wire formats, feature flags, FFI boundaries, and compatibility tests. Use when changing exported types, traits, functions, modules, Cargo features, MSRV, serialization schemas, plugin interfaces, or any contract consumed outside the current crate. Emphasize extend-only design, private representation, non_exhaustive enums, sealed traits, explicit DTOs, staged migrations, and tooling that catches accidental breaking changes.
---

# Rust Public API Design and Compatibility

## Operating Model

Treat every public surface as a contract with four compatibility dimensions:

| Dimension | Question | Examples |
|---|---|---|
| Source | Does downstream source still compile? | item names, signatures, fields, variants, trait bounds, features |
| Semantic | Does downstream behavior still match expectations? | defaults, invariants, errors, ordering, retries, timing |
| Wire | Can old and new serialized data interoperate? | JSON, protobuf, MessagePack, persistence, network protocols |
| FFI/ABI | Can external callers still link and call safely? | symbols, layouts, allocation rules, `extern "C"` functions |

Rust has no stable Rust-to-Rust ABI. If ABI matters, expose a C-compatible API and version it as a separate product.

Use this default stance:

1. Preserve released contracts.
2. Add new contracts beside old ones.
3. Deprecate before removing.
4. Make compatibility claims testable.

Rust-specific caution: "additive" does not always mean compatible. Adding enum variants, trait methods, trait impls, blanket impls, public fields, default features, or stricter bounds can break downstream code depending on the original API shape.

## Release Decision Rules

| Change | Minimum release | Notes |
|---|---|---|
| Bug fix with compatible behavior | Patch | Avoid changing documented defaults or observable semantics. |
| New free function, type, module, or inherent method | Minor | Review method-name conflicts and inference changes. |
| New Cargo feature that only adds APIs | Minor | Keep features additive. |
| Deprecation with working replacement | Minor | Add replacement in the same release. |
| MSRV increase | Minor | Only if policy allows; document it. |
| Removed item, renamed item, changed signature, required field, required trait method | Major | Provide migration notes. |
| New variant on released exhaustive enum | Major | Use `#[non_exhaustive]` before release if variants may grow. |
| Changed wire default, tag, field meaning, numeric code, or ABI layout | Usually major or staged migration | Stage reads before writes for distributed systems. |

Patch releases should be uneventful. Minor releases may add capabilities, but must not flip defaults casually. Major releases still need precise migration guidance.

## Design for Extension

### Keep Representation Private

Prefer private fields for domain types, clients, builders, handles, errors with internal context, and configuration expected to grow.

```rust
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

Avoid public fields for growing types:

```rust
pub struct ClientOptions {
    pub timeout: std::time::Duration,
    pub max_retries: u32,
}
```

Adding a required public field breaks callers that construct the struct with a literal. Public fields are acceptable for stable DTOs and simple data carriers when that literal construction is deliberately part of the API.

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

Builder rules:

- Use builders instead of long public functions with many parameters.
- Keep setters chainable and additive.
- Keep defaults stable. If defaults must change, add an explicit named mode.
- Put cross-field validation in `build()`, not every setter.
- Avoid exposing builder fields unless literal construction is intentionally stable.

## API Change Classification

### Usually Compatible

```rust
pub fn parse_order_id(value: &str) -> Result<OrderId, ParseOrderIdError> { ... }

impl Client {
    pub fn with_user_agent(mut self, user_agent: impl Into<String>) -> Self { ... }
}

pub struct RetryPolicy { ... }

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
```

Still review compatible-looking changes. New inherent methods can conflict with downstream trait methods in method-call syntax. New impls can change inference and trait selection. New defaults can change behavior even when signatures are untouched.

### Breaking

```rust
pub fn submit_order(order: Order) { ... } // renamed from process_order

pub fn get_order(id: OrderId) -> Result<Order, Error> { ... } // was Option<Order>

pub fn send(request: Request, timeout: Duration) -> Result<Response, Error> { ... }

pub struct ClientOptions {
    pub timeout: Duration,
    pub max_retries: u32,
    pub user_agent: String,
}

pub enum OrderStatus {
    Draft,
    Submitted,
    Paid,
    Refunded,
}

pub trait Transport {
    fn send(&self, request: Request) -> Result<Response, Error>;
    fn close(&self) -> Result<(), Error>;
}

pub fn process<T: Send + Sync>(value: T) { ... } // was T: Send
```

Treat these as breaking unless proven otherwise:

- Removing, renaming, hiding, or moving public items.
- Changing parameter types, return types, error types, lifetimes, const generics, or generic bounds.
- Adding required parameters, required fields, required trait methods, or exhaustive enum variants.
- Removing trait impls or changing auto-trait behavior (`Send`, `Sync`, `Unpin`) through representation changes.
- Changing documented defaults, ordering, retry behavior, timeout behavior, or error classification.

### Gray Areas That Need Explicit Review

- Adding trait impls, especially blanket impls.
- Adding inherent methods with common names such as `new`, `get`, `into_inner`, `try_from`, or `from_str`.
- Loosening bounds in ways that change inference or selected impls.
- Changing default features or feature dependency graphs.
- Raising MSRV.
- Changing error `Display` text when users parse it, even if they should not.
- Changing iteration order, hashing, serialization order, or deterministic output.
- Making previously possible construction impossible through stricter validation.

## Enums

Use exhaustive enums for closed domains where downstream exhaustive matching is valuable.

```rust
pub enum PaymentState {
    Pending,
    Authorized { authorization_id: String },
    Captured { receipt_id: String },
    Failed { reason: String },
}
```

Use `#[non_exhaustive]` for public categories expected to grow, especially error kinds, events, and protocol classifications.

```rust
#[non_exhaustive]
pub enum ApiErrorKind {
    Timeout,
    RateLimited,
    Unauthorized,
}
```

Downstream callers must then include a fallback arm:

```rust
match error.kind() {
    ApiErrorKind::Timeout => retry(),
    ApiErrorKind::RateLimited => backoff(),
    ApiErrorKind::Unauthorized => refresh_credentials(),
    _ => report_unknown(error),
}
```

Enum rules:

- Do not add variants to a released exhaustive enum without a major version.
- Mark structs and enum variants `#[non_exhaustive]` before release when fields or variants may grow.
- Avoid wildcard matches inside the defining crate for business logic; exhaustive internal matches catch new cases.
- For wire enums, preserve unknown numeric/string values with `Unknown(value)` or equivalent raw storage.

## Traits

Public traits imply downstream implementations unless sealed. Decide up front whether users are supposed to implement the trait.

Prefer small traits:

```rust
pub trait Clock {
    fn now(&self) -> time::OffsetDateTime;
}
```

Add new trait behavior as a default method only when the default is correct for all existing implementors:

```rust
pub trait Store {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError>;

    fn contains_key(&self, key: &str) -> Result<bool, StoreError> {
        Ok(self.get(key)?.is_some())
    }
}
```

Seal traits users should not implement:

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

Trait rules:

- Prefer inherent methods for behavior on types you own.
- Use sealed traits for marker traits, extension points controlled by the crate, and protocol families with fixed implementors.
- Avoid blanket impls unless coherence and downstream conflict risk have been reviewed.
- Decide whether `dyn Trait` is supported. If yes, test object safety.
- Adding associated types, generic parameters, supertraits, or required methods is breaking.

## Deprecation

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

Deprecation rules:

- Add the replacement before or in the same release as the deprecation.
- Keep the deprecated API working until the planned major release.
- Include examples and mechanical migration notes.
- Do not use deprecation as a substitute for compatibility in patch releases.

## Feature Flags and MSRV

Feature flags are public API.

```toml
[features]
default = ["rustls"]
rustls = ["dep:rustls"]
native-tls = ["dep:native-tls"]
json = ["dep:serde", "dep:serde_json"]
```

Feature rules:

- Features should be additive. Enabling one feature should not remove APIs from another configuration.
- Avoid mutually exclusive features. If unavoidable, reject invalid combinations with `compile_error!`.
- Do not add heavy default features casually.
- Removing a feature or changing default features is breaking for many users.
- Test feature combinations with `cargo hack` for shared crates.

MSRV rules:

- Declare `rust-version` in `Cargo.toml` when the crate has an MSRV policy.
- Test MSRV in CI if the project promises it.
- Do not raise MSRV in a patch release unless the project explicitly says patch MSRV bumps are allowed.
- Call out MSRV changes in release notes.

## Wire Compatibility

For distributed systems, old and new versions must interoperate during rolling upgrades.

| Direction | Requirement |
|---|---|
| Backward compatibility | New readers can read old data. |
| Forward compatibility | Old readers can tolerate new data. |

Use explicit DTOs for wire contracts. Do not expose domain types as long-lived protocol schemas.

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
    #[serde(skip_serializing_if = "Option::is_none")]
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

Rolling upgrade sequence:

1. Deploy readers that accept old and new formats.
2. Add a flag or config to opt into new writes.
3. Enable new writes after all active readers support them.
4. Make the new format default only after the fleet and persisted data are safe.
5. Remove old support later through a major release or explicit migration.

Serde rules:

- Use stable protocol names, not Rust type names.
- Use `#[serde(default)]` for newly added optional input fields.
- Use `#[serde(skip_serializing_if = "Option::is_none")]` for optional output fields.
- Avoid `deny_unknown_fields` for forward-compatible formats.
- Avoid untagged enums for long-lived protocols unless ambiguity is impossible and tested.
- Treat `bincode`, `postcard`, and other type-shape-coupled formats as fragile unless configuration and schemas are locked down.

Prefer schema-based formats for long-lived protocols:

| Format | Compatibility discipline |
|---|---|
| Protocol Buffers | Reserve removed field numbers and names; never reuse tags. |
| Avro / JSON Schema | Use schema registry rules and compatibility checks. |
| JSON DTOs | Define defaults, unknown-field policy, and stable tags. |
| MessagePack DTOs | Use explicit schema conventions; avoid implicit Rust shape coupling. |
| bincode/postcard | Use only for controlled environments or version every payload. |

## FFI and ABI

Public Rust functions are not a plugin ABI. For FFI, expose a C-compatible boundary.

```rust
#[repr(C)]
pub struct ApiResult {
    pub code: i32,
    pub data: *mut std::ffi::c_void,
}

#[no_mangle]
pub extern "C" fn client_create() -> ApiResult {
    // C-compatible boundary only.
}
```

FFI rules:

- Use `extern "C"` and `#[repr(C)]` or `#[repr(transparent)]` for layout-sensitive types.
- Do not expose Rust `String`, `Vec<T>`, `Result<T, E>`, trait objects, references with Rust lifetimes, or panics across FFI.
- Provide explicit create/free functions and document allocator ownership.
- Treat symbol names, struct layout, enum discriminants, error codes, and allocation rules as frozen API.
- Add ABI/link tests when consumers dynamically link.

## Compatibility Testing

Use tooling as a review gate, not as a substitute for judgment.

```bash
cargo install cargo-semver-checks
cargo semver-checks check-release
```

```bash
cargo install cargo-public-api
cargo public-api > public-api.txt
```

```bash
cargo install cargo-hack
cargo hack check --feature-powerset --no-dev-deps
```

Store wire fixtures from previous versions:

```rust
#[test]
fn reads_v1_heartbeat_payload() {
    let payload = include_str!("fixtures/heartbeat-v1.json");
    let message: WireMessage = serde_json::from_str(payload).unwrap();

    assert!(matches!(message, WireMessage::HeartbeatV1(_)));
}
```

Testing rules:

- Review a public API diff for stable crates.
- Run semver checks before publishing.
- Test feature combinations for shared crates.
- Test MSRV when promised.
- Keep old wire payload fixtures and new-write fixtures.
- Include compile-fail or downstream-style tests for trait object safety, sealed traits, and expected construction patterns when those are part of the contract.

## Review Checklist

Use this checklist for PRs that touch public APIs, wire formats, features, MSRV, or FFI:

- [ ] No removed, renamed, hidden, or moved public items without a major-version plan.
- [ ] No changed signatures, bounds, lifetimes, associated types, or return/error types without a new API and deprecation path.
- [ ] No new required public struct fields, required trait methods, or exhaustive enum variants.
- [ ] `#[non_exhaustive]` is used before release where future growth is expected.
- [ ] Traits are sealed when downstream implementations should not exist.
- [ ] New impls and blanket impls have been checked for coherence, inference, and downstream conflict risk.
- [ ] Feature changes are additive, documented, and tested across relevant combinations.
- [ ] MSRV changes are intentional, policy-compliant, tested, and in release notes.
- [ ] Defaults, ordering, error semantics, retries, timeouts, and validation behavior remain compatible or have a migration plan.
- [ ] Wire readers accept old payloads; new writes are staged for rolling upgrades.
- [ ] FFI symbols, layouts, ownership, allocator rules, and panic behavior remain compatible.
- [ ] Public API diff, semver check, changelog, and migration notes have been reviewed.

## Common Anti-Patterns

### Growing Public Config Structs

```rust
pub struct ClientConfig {
    pub endpoint: String,
    pub timeout: Duration,
}
```

Prefer private fields plus a builder for configuration expected to grow.

### Exhaustive Error Kinds

```rust
pub enum ClientErrorKind {
    Timeout,
    Unauthorized,
}
```

Use `#[non_exhaustive]` if new error kinds are plausible.

### Required Trait Methods Added Later

```rust
pub trait Store {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, Error>;
    fn delete(&self, key: &str) -> Result<(), Error>;
}
```

Use a default method when universally correct, or add a separate extension trait.

### Rust Type Names in Wire Formats

```json
{
  "type": "my_crate::orders::OrderCreated",
  "payload": { "id": "..." }
}
```

Use stable protocol names:

```json
{
  "type": "order.created.v1",
  "payload": { "id": "..." }
}
```

### Behavior Breaks Presented as Cleanup

Changing `ClientOptions::new()` from a 30 second timeout to a 5 second timeout is a behavior break. Add an explicit mode such as `ClientOptions::new().with_fast_fail_defaults()` instead.

## References

- Rust API Guidelines: https://rust-lang.github.io/api-guidelines/
- Cargo SemVer Compatibility: https://doc.rust-lang.org/cargo/reference/semver.html
- cargo-semver-checks: https://github.com/obi1kenobi/cargo-semver-checks
- cargo-public-api: https://github.com/Enselic/cargo-public-api
- SemVer: https://semver.org/
