---
name: rust-concurrency-patterns
description: "Choose the right Rust concurrency abstraction: ordinary async/await for I/O, bounded channels for producer/consumer, Rayon for CPU parallelism, locks only for short critical sections, and actors/tasks for isolated state machines. Avoid Arc<Mutex<T>> business logic and unbounded queues by default."
invocable: false
---

# Rust Concurrency: Choosing the Right Tool

## When to Use This Skill

Use this skill when:

- Deciding how to run work concurrently in Rust
- Choosing between async/await, Tokio tasks, channels, locks, Rayon, and actors
- Reviewing code that uses `Arc<Mutex<T>>`, unbounded channels, or detached tasks
- Building producer/consumer pipelines with backpressure
- Managing shared state, state machines, or long-lived entities
- Mixing synchronous CPU work with async I/O

---

## The Philosophy

**Start with no concurrency. Add it only when there is measured or architectural need.**

Rust makes data races hard, but it does not make bad concurrency designs good. Most bugs come from unclear ownership, unbounded queues, missing shutdown, hidden blocking, and shared mutable state.

**Escalation order:**

1. Plain sequential code
2. `async`/`await` for I/O concurrency
3. `tokio::join!`, `try_join!`, `JoinSet`, or `FuturesUnordered` for multiple async operations
4. Bounded channels for producer/consumer and serialized state access
5. Rayon or worker pools for CPU-bound parallelism
6. Actors when a task owns state and receives commands over a channel
7. Locks only for small, boring, short critical sections

**Locks are not evil. Locks as architecture are evil.** Use locks for caches, counters, and short in-memory updates. Do not use `Arc<Mutex<DomainState>>` as your business workflow engine.

---

## Decision Tree

```text
What are you trying to do?
│
├─► Wait for I/O: HTTP, DB, socket, timer?
│   └─► Use async/await with Tokio or the runtime already in the project
│
├─► Run a fixed set of independent async calls?
│   └─► Use tokio::join! or tokio::try_join!
│
├─► Run many async jobs with bounded concurrency?
│   └─► Use JoinSet, FuturesUnordered, or stream.buffer_unordered(n)
│
├─► Process CPU-heavy data in parallel?
│   └─► Use Rayon, or spawn_blocking when called from async code
│
├─► Producer/consumer work queue?
│   └─► Use a bounded channel: tokio::sync::mpsc or crossbeam_channel
│
├─► Share small in-memory state?
│   ├─► Sync code only: std::sync::Mutex / RwLock or parking_lot
│   └─► Async code and guard crosses await: redesign; if unavoidable, tokio::sync::Mutex
│
├─► Stateful entity or workflow with serialized commands?
│   └─► Use an actor: one task owns state; callers send messages
│
├─► Broadcast latest value to many tasks?
│   ├─► Latest state: tokio::sync::watch
│   └─► Event fan-out: tokio::sync::broadcast
│
└─► Need distributed actors / supervision / clustering?
    └─► Consider a dedicated actor framework; do not hand-roll distributed systems casually
```

---

## Level 1: Plain Async/Await

**Use for:** I/O-bound operations, timers, network calls, database calls, and ordinary service code.

```rust
pub async fn get_order_summary(
    order_id: OrderId,
    orders: &OrderClient,
    customers: &CustomerClient,
) -> Result<OrderSummary, SummaryError> {
    let order = orders.get(order_id).await?;
    let customer = customers.get(order.customer_id()).await?;

    Ok(OrderSummary::new(order, customer))
}
```

Run independent calls together:

```rust
pub async fn load_dashboard(
    user_id: UserId,
    orders: &OrderClient,
    notifications: &NotificationClient,
    stats: &StatsClient,
) -> Result<Dashboard, DashboardError> {
    let (orders, notifications, stats) = tokio::try_join!(
        orders.recent(user_id),
        notifications.unread(user_id),
        stats.for_user(user_id),
    )?;

    Ok(Dashboard { orders, notifications, stats })
}
```

**Rules:**

- Do not block inside async code.
- Do not use async for pure CPU functions.
- Prefer `try_join!` when any failure should fail the whole operation.
- Prefer `join!` when all results should be collected regardless of individual failure.
- Make cancellation behavior explicit. Dropping a future cancels it; dropping a Tokio `JoinHandle` detaches it.

---

## Level 2: Many Async Tasks with Bounded Concurrency

**Use for:** calling many services, fetching many URLs, or processing many jobs concurrently without overwhelming dependencies.

```rust
use futures::{stream, StreamExt, TryStreamExt};

pub async fn fetch_all(
    ids: Vec<OrderId>,
    client: &OrderClient,
) -> Result<Vec<Order>, OrderClientError> {
    stream::iter(ids)
        .map(|id| async move { client.get(id).await })
        .buffer_unordered(32)
        .try_collect()
        .await
}
```

For owned spawned tasks, use `JoinSet` and always drain it:

```rust
use tokio::task::JoinSet;

pub async fn process_jobs(jobs: Vec<Job>) -> Result<(), JobError> {
    let mut set = JoinSet::new();

    for job in jobs {
        set.spawn(async move { process_job(job).await });
    }

    while let Some(result) = set.join_next().await {
        result.map_err(JobError::Join)??;
    }

    Ok(())
}
```

**Rules:**

- Bound concurrency. `for item in items { tokio::spawn(...) }` without a limit is a production incident waiting to happen.
- Always observe task results. A failed detached task is a silent bug.
- Keep task inputs owned or `Arc`-backed. Do not spawn tasks that borrow stack data unless scoped APIs guarantee lifetime safety.

---

## Level 3: CPU-Bound Parallelism

**Use for:** CPU-heavy loops, parsing, compression, image processing, crypto, scoring, and batch transformations.

Use Rayon in synchronous CPU code:

```rust
use rayon::prelude::*;

pub fn score_orders(orders: &[Order]) -> Vec<OrderScore> {
    orders
        .par_iter()
        .map(score_order)
        .collect()
}
```

From async code, move blocking work off the async scheduler:

```rust
pub async fn parse_large_file(bytes: Vec<u8>) -> Result<ParsedFile, ParseError> {
    tokio::task::spawn_blocking(move || parse_file(bytes))
        .await
        .map_err(ParseError::Join)?
}
```

**Rules:**

- Async runtimes are not CPU work schedulers.
- Use `spawn_blocking` for unavoidable blocking calls from async code.
- Use Rayon for data parallelism outside async request paths.
- Do not mix Rayon and Tokio casually in hot paths; measure and document the boundary.

---

## Level 4: Channels for Producer/Consumer

**Use for:** work queues, decoupling producers from consumers, serialized processing, fan-in, and backpressure.

Prefer bounded channels:

```rust
use tokio::sync::mpsc;

pub struct OrderQueue {
    sender: mpsc::Sender<OrderCommand>,
}

impl OrderQueue {
    pub fn new(buffer: usize) -> (Self, mpsc::Receiver<OrderCommand>) {
        let (sender, receiver) = mpsc::channel(buffer);
        (Self { sender }, receiver)
    }

    pub async fn submit(&self, command: OrderCommand) -> Result<(), QueueClosed> {
        self.sender
            .send(command)
            .await
            .map_err(|_| QueueClosed)
    }
}

pub async fn run_order_worker(mut receiver: mpsc::Receiver<OrderCommand>) {
    while let Some(command) = receiver.recv().await {
        if let Err(error) = handle_order_command(command).await {
            tracing::warn!(?error, "failed to process order command");
        }
    }
}
```

**Channel selection:**

| Need | Tool |
|---|---|
| Async MPSC work queue | `tokio::sync::mpsc::channel` |
| Sync MPMC work queue | `crossbeam_channel` or `std::sync::mpsc` for simple cases |
| One response from one task | `tokio::sync::oneshot` |
| Latest value observed by many tasks | `tokio::sync::watch` |
| Broadcast events to many subscribers | `tokio::sync::broadcast` |
| Sync/async bridge | Tokio `blocking_send`, `blocking_recv`, or a dedicated bridge task |

**Rules:**

- Bounded by default. Backpressure is a feature.
- Unbounded channels require a written reason and a shutdown story.
- Message types should be domain commands, not anonymous tuples.
- Include response channels for request/response actors.
- Define close behavior: who drops the sender, who drains the receiver, and how shutdown is signaled.

---

## Level 5: Locks for Short Critical Sections

**Use for:** small shared state, caches, counters, dedup maps, and state that is cheap to update in memory.

```rust
use std::{collections::HashMap, sync::Mutex};

pub struct CustomerCache {
    values: Mutex<HashMap<CustomerId, Customer>>,
}

impl CustomerCache {
    pub fn get(&self, id: CustomerId) -> Option<Customer> {
        let values = self.values.lock().expect("customer cache mutex poisoned");
        values.get(&id).cloned()
    }

    pub fn insert(&self, customer: Customer) {
        let mut values = self.values.lock().expect("customer cache mutex poisoned");
        values.insert(customer.id(), customer);
    }
}
```

In async code, avoid holding locks across `.await`:

```rust
// BAD: lock guard lives across .await.
async fn update_bad(state: Arc<tokio::sync::Mutex<State>>, client: Client) -> Result<(), Error> {
    let mut state = state.lock().await;
    let remote = client.fetch().await?;
    state.apply(remote);
    Ok(())
}

// GOOD: await first, lock briefly.
async fn update_good(state: Arc<tokio::sync::Mutex<State>>, client: Client) -> Result<(), Error> {
    let remote = client.fetch().await?;

    let mut state = state.lock().await;
    state.apply(remote);

    Ok(())
}
```

**Mutex choice:**

| Context | Prefer |
|---|---|
| Sync code | `std::sync::Mutex` or `parking_lot::Mutex` |
| Async code, no await while locked | Often `std::sync::Mutex` is fine |
| Async code, guard must wait asynchronously | `tokio::sync::Mutex`, but redesign first |
| Many reads, few writes | `RwLock`, but measure; it can starve or add overhead |
| Atomic counter/flag | `AtomicU64`, `AtomicBool`, etc. |

**Rules:**

- Lock only the data, not the world.
- Keep critical sections tiny and non-async.
- Do not call user-provided callbacks while holding a lock.
- Never use a lock to paper over unclear ownership.

---

## Level 6: Actors and State Ownership

**Use for:** long-lived state machines, entity-per-task state, serialized command handling, workflows, supervision, and command/query interactions.

A minimal actor is just a task that owns state and receives messages:

```rust
use tokio::sync::{mpsc, oneshot};

pub enum CartCommand {
    AddItem {
        item: CartItem,
        reply_to: oneshot::Sender<Result<CartSnapshot, CartError>>,
    },
    Checkout {
        reply_to: oneshot::Sender<Result<OrderId, CartError>>,
    },
}

pub struct CartActor {
    cart: Cart,
    receiver: mpsc::Receiver<CartCommand>,
}

impl CartActor {
    pub fn start(cart: Cart) -> mpsc::Sender<CartCommand> {
        let (sender, receiver) = mpsc::channel(64);
        let actor = Self { cart, receiver };

        tokio::spawn(async move {
            actor.run().await;
        });

        sender
    }

    async fn run(mut self) {
        while let Some(command) = self.receiver.recv().await {
            match command {
                CartCommand::AddItem { item, reply_to } => {
                    let result = self.cart.add_item(item).map(|_| self.cart.snapshot());
                    let _ = reply_to.send(result);
                }
                CartCommand::Checkout { reply_to } => {
                    let result = self.cart.checkout().await;
                    let _ = reply_to.send(result);
                }
            }
        }
    }
}
```

**Actor rules:**

- The actor owns its state. Callers do not get `Arc<Mutex<State>>` access.
- Messages are explicit domain commands.
- Bounded mailbox by default.
- Every request expecting a response carries a `oneshot::Sender`.
- Supervision is a design requirement. Decide what happens when the actor fails.
- Do not build a distributed actor runtime unless that is your product.

**When actors are worth it:**

- State transitions are complex and must be serialized.
- Each entity can be isolated independently.
- You need clear command ordering.
- You need a place to put timers, retries, and workflow state.

**When actors are overkill:**

- Stateless request/response services.
- Simple CRUD.
- Pure data transformations.
- A single cache protected by a short lock.

---

## Cancellation and Shutdown

Concurrency without shutdown is a leak.

```rust
use tokio_util::sync::CancellationToken;

pub async fn run_worker(
    mut receiver: mpsc::Receiver<Job>,
    shutdown: CancellationToken,
) {
    loop {
        tokio::select! {
            _ = shutdown.cancelled() => {
                break;
            }
            maybe_job = receiver.recv() => {
                let Some(job) = maybe_job else { break; };
                process(job).await;
            }
        }
    }
}
```

**Shutdown rules:**

- Store `JoinHandle`s for long-running tasks.
- Signal shutdown explicitly with channel close or `CancellationToken`.
- Drain queues when correctness requires it; drop queues when latency matters more.
- Use `JoinHandle::abort` only when abrupt cancellation is safe.
- Log task exits and errors.

---

## Anti-Patterns

### Arc<Mutex<T>> as Business Architecture

```rust
// BAD: every workflow step contends on shared mutable domain state.
type SharedOrders = Arc<tokio::sync::Mutex<HashMap<OrderId, Order>>>;

// GOOD: one task owns order state, callers send commands.
```

### Unbounded Channels by Habit

```rust
// BAD: no backpressure; memory is the queue.
let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

// GOOD: bounded mailbox with explicit capacity.
let (tx, rx) = tokio::sync::mpsc::channel(1024);
```

### Blocking Inside Async

```rust
// BAD: blocks runtime worker thread.
async fn wait_bad() {
    std::thread::sleep(std::time::Duration::from_secs(1));
}

// GOOD: yields to runtime.
async fn wait_good() {
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
}
```

### Spawn and Forget

```rust
// BAD: no error observation, no shutdown.
tokio::spawn(async move {
    process_forever().await;
});

// GOOD: store handle, signal shutdown, observe result.
let handle = tokio::spawn(async move { process_forever(shutdown).await });
```

### Holding Locks Across Await

```rust
// BAD: lock held while the task waits for remote I/O.
let mut guard = state.lock().await;
let value = client.fetch().await?;
guard.update(value);
```

---

## Quick Reference

| Need | Tool | Notes |
|---|---|---|
| Single I/O operation | `async`/`await` | Default async style |
| Fixed independent async operations | `tokio::join!`, `tokio::try_join!` | No task spawning required |
| Many async operations | `JoinSet`, `FuturesUnordered`, `buffer_unordered(n)` | Bound concurrency |
| CPU-bound parallel loops | Rayon | Keep out of async scheduler |
| Blocking from async | `spawn_blocking` | Boundary only, not everywhere |
| Work queue | Bounded `mpsc` | Backpressure by default |
| One-shot response | `oneshot` | Great for actor replies |
| Latest shared value | `watch` | Subscribers see newest value |
| Event fan-out | `broadcast` | Lagging receivers can miss messages |
| Small shared cache | `Mutex` / `RwLock` | Short critical sections only |
| Serialized state machine | Actor task + channel | State owned by task |
| Shared counter | Atomics | Keep memory ordering simple |

---

## Review Checklist

- [ ] Is concurrency necessary, or would sequential code be clearer?
- [ ] Is every queue bounded unless explicitly justified?
- [ ] Are task results observed?
- [ ] Is there a shutdown path?
- [ ] Are locks held only for short, non-async critical sections?
- [ ] Is CPU work kept off the async runtime?
- [ ] Are domain messages explicit types?
- [ ] Is shared mutable state avoided or isolated?
- [ ] Is cancellation behavior documented?

---

## Additional Resources

- Rust Book: Fearless Concurrency: https://doc.rust-lang.org/book/ch16-00-concurrency.html
- Tokio Tutorial: https://tokio.rs/tokio/tutorial
- Tokio mpsc: https://docs.rs/tokio/latest/tokio/sync/mpsc/
- Rayon: https://docs.rs/rayon/latest/rayon/
- Crossbeam channels: https://docs.rs/crossbeam/latest/crossbeam/channel/
