---
name: rust-concurrency-patterns
description: Choose and review Rust concurrency designs using sequential code, async/await, Tokio tasks, bounded channels, cancellation, locks, Rayon, atomics, and actor-style state ownership. Use when deciding how work should run concurrently, fixing shared mutex business logic, bounding task fan-out, designing producer/consumer pipelines, preventing blocking in async code, handling shutdown, or choosing between channels, locks, actors, Rayon, and async streams.
---

# Rust Concurrency Patterns

## Operating Model

Start with no concurrency. Add it only when there is a measured performance need, an I/O concurrency need, or a real architectural boundary.

Rust prevents data races; it does not prevent poor concurrency architecture. Most production bugs come from unbounded queues, detached tasks, missing shutdown, hidden blocking, long-held locks, unclear ownership, and shared mutable domain state.

Default escalation order:

1. Sequential code.
2. `async`/`await` for I/O concurrency.
3. `join!`, `try_join!`, `JoinSet`, `FuturesUnordered`, or `buffer_unordered(n)` for multiple async operations.
4. Bounded channels for producer/consumer work and backpressure.
5. Rayon or explicit worker pools for CPU-bound parallelism.
6. Actor-style tasks when one task should own state and process commands serially.
7. Locks for small, boring, short critical sections.

Locks are fine for caches, counters, and short in-memory updates. Do not use `Arc<Mutex<DomainState>>` as the business workflow engine.

## Decision Guide

| Need | Prefer | Avoid |
|---|---|---|
| One I/O operation | Plain `async`/`await` | Spawning a task for no reason |
| Fixed independent async calls | `tokio::join!` or `tokio::try_join!` | Manual task plumbing |
| Many async jobs | `buffer_unordered(n)`, `JoinSet`, `FuturesUnordered` | Unbounded `tokio::spawn` loops |
| CPU-heavy parallel work | Rayon | Running CPU loops on async runtime workers |
| Blocking API from async code | `tokio::task::spawn_blocking` | Calling blocking code directly |
| Producer/consumer queue | Bounded `mpsc` | Unbounded channels by habit |
| One request/response reply | `oneshot` | Shared mutable response slots |
| Latest value for many tasks | `watch` | Polling a locked value |
| Event fan-out | `broadcast` | Pretending every receiver sees every event |
| Small shared cache | `Mutex` or `RwLock` | Holding locks across `.await` |
| Shared counter or flag | Atomics | Locking hot counters |
| Serialized state machine | Actor task plus bounded mailbox | `Arc<Mutex<State>>` exposed to callers |

Ask these questions before choosing:

1. Is the work I/O-bound, CPU-bound, or state-serialization-bound?
2. Who owns the data?
3. What bounds memory growth?
4. How are errors observed?
5. How does shutdown happen?
6. What happens on cancellation?

## Async I/O

Use async for I/O-bound operations, timers, network calls, database calls, and ordinary service orchestration.

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

Run independent calls together without spawning:

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

Async rules:

- Use `try_join!` when any failure should fail the combined operation.
- Use `join!` when every result should be collected.
- Do not make pure CPU functions async.
- Do not block runtime worker threads with `std::thread::sleep`, blocking file I/O, blocking database clients, or long CPU loops.
- Know cancellation semantics: dropping a future cancels it; dropping a Tokio `JoinHandle` detaches the task.

## Many Async Jobs

Bound fan-out when processing many async jobs.

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

Use `JoinSet` for owned spawned tasks and drain every result:

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

Task rules:

- Set an explicit concurrency limit.
- Observe every task result.
- Prefer structured concurrency: keep handles in scope and await them.
- Move owned values or `Arc` handles into spawned tasks.
- Do not spawn tasks that borrow stack data unless a scoped API guarantees safety.
- Decide whether partial failure cancels remaining work or lets it drain.

## CPU-Bound Work

Use Rayon for CPU-heavy loops, parsing, compression, image processing, crypto, scoring, and batch transformations.

```rust
use rayon::prelude::*;

pub fn score_orders(orders: &[Order]) -> Vec<OrderScore> {
    orders.par_iter().map(score_order).collect()
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

CPU rules:

- Async runtimes are not CPU work schedulers.
- Use `spawn_blocking` for unavoidable blocking calls from async code.
- Use Rayon for data parallelism outside latency-sensitive async request paths.
- Avoid mixing Rayon and Tokio in hot paths without measuring.
- Bound CPU parallelism when work competes with request handling.

## Channels and Backpressure

Use channels for work queues, decoupling producers from consumers, serialized processing, fan-in, and backpressure. Prefer bounded channels.

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
        self.sender.send(command).await.map_err(|_| QueueClosed)
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

Channel selection:

| Need | Tool |
|---|---|
| Async MPSC work queue | `tokio::sync::mpsc::channel` |
| Sync MPMC work queue | `crossbeam_channel` |
| Simple sync one-producer queue | `std::sync::mpsc` |
| One response from one task | `tokio::sync::oneshot` |
| Latest value observed by many tasks | `tokio::sync::watch` |
| Event fan-out | `tokio::sync::broadcast` |
| Sync/async bridge | Tokio `blocking_send`, `blocking_recv`, or a bridge task |

Channel rules:

- Use bounded channels by default; backpressure is a feature.
- Require a written reason for unbounded channels.
- Make messages domain commands or events, not anonymous tuples.
- Include response channels for request/response interactions.
- Define close behavior: who drops senders, who drains receivers, and which messages may be lost.
- Treat send failure as a shutdown signal unless there is a stronger domain meaning.

## Locks and Shared State

Use locks for small shared state, caches, counters, dedup maps, and cheap in-memory updates.

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

Avoid holding locks across `.await`:

```rust
async fn update_good(state: Arc<tokio::sync::Mutex<State>>, client: Client) -> Result<(), Error> {
    let remote = client.fetch().await?;

    let mut state = state.lock().await;
    state.apply(remote);

    Ok(())
}
```

Mutex choice:

| Context | Prefer |
|---|---|
| Sync code | `std::sync::Mutex` or `parking_lot::Mutex` |
| Async code, no await while locked | Often `std::sync::Mutex` is fine |
| Async code, asynchronous waiting for lock is required | `tokio::sync::Mutex`, but reconsider design first |
| Many reads, few writes | `RwLock`, after considering starvation and overhead |
| Hot counter or flag | Atomics |

Lock rules:

- Lock only the data needed for the operation.
- Put fields behind one lock when they are usually accessed together; avoid multiple wrappers that force repeated locking.
- Keep critical sections tiny and non-async.
- Do not call user callbacks while holding a lock.
- Do not perform I/O while holding a lock.
- Use poisoning intentionally: recover, clear, or fail loudly.
- Treat `parking_lot` as an option to measure, not an automatic upgrade over standard-library locks.
- Do not use locks to avoid designing ownership.

## Actors and State Ownership

Use an actor-style task for long-lived state machines, entity-per-task state, serialized command handling, workflows, timers, retries, and command/query interactions.

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

Actor rules:

- The actor owns its state; callers do not get `Arc<Mutex<State>>` access.
- Use explicit domain commands.
- Use a bounded mailbox by default.
- Put `oneshot::Sender` in messages that expect replies.
- Decide what happens when the actor fails, exits, or falls behind.
- Store or supervise actor task handles when failure matters.
- Do not build a distributed actor runtime unless that is the product.

Actors are useful when state transitions are complex, command ordering matters, timers/retries belong with state, or each entity can be isolated independently. They are overkill for stateless request/response code, simple CRUD, pure transformations, or a single cache.

## Cancellation and Shutdown

Every long-running task needs a shutdown path.

```rust
use tokio::sync::mpsc;
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

Shutdown rules:

- Store `JoinHandle`s for long-running tasks.
- Signal shutdown explicitly with channel close, a command message, or `CancellationToken`.
- Drain queues when correctness matters; drop queues when latency matters more.
- Use `JoinHandle::abort` only when abrupt cancellation is safe.
- Log task exits and errors.
- Test shutdown paths for workers, actors, and queues.

## Atomics

Use atomics for small independent counters, flags, and sequence numbers.

Atomic rules:

- Prefer locks when multiple fields must change together.
- Keep memory ordering simple; use `Relaxed` only when ordering truly does not matter.
- Use `SeqCst` when correctness is more important than squeezing performance and the ordering model is not obvious.
- Do not build complex lock-free data structures unless that is the point of the code and tests prove it.

## Review Checklist

Use this checklist for concurrency design and PR review:

- [ ] Concurrency is necessary and its purpose is clear.
- [ ] Work is classified correctly as I/O-bound, CPU-bound, or state-serialization-bound.
- [ ] Fan-out and queues are bounded unless explicitly justified.
- [ ] Task results are observed.
- [ ] Long-running tasks have shutdown and cancellation paths.
- [ ] CPU or blocking work stays off async runtime workers.
- [ ] Locks guard small data and are not held across `.await`, I/O, or callbacks.
- [ ] Shared mutable domain state is isolated behind an owner task or narrow lock.
- [ ] Channel messages are explicit domain types.
- [ ] Actor mailboxes are bounded and actor failure behavior is defined.
- [ ] Backpressure, overload, and dropped-message behavior are documented.
- [ ] Tests cover shutdown, cancellation, and error propagation where behavior is important.

## Common Anti-Patterns

### `Arc<Mutex<T>>` as Business Architecture

```rust
type SharedOrders = Arc<tokio::sync::Mutex<HashMap<OrderId, Order>>>;
```

Prefer one owner task with domain commands when workflows and state transitions matter.

### Unbounded Channels by Habit

```rust
let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
```

Prefer a bounded mailbox with an explicit capacity.

### Blocking Inside Async

```rust
async fn wait_bad() {
    std::thread::sleep(std::time::Duration::from_secs(1));
}
```

Use runtime-aware async operations such as `tokio::time::sleep`.

### Spawn and Forget

```rust
tokio::spawn(async move {
    process_forever().await;
});
```

Store the handle, signal shutdown, and observe the result when failure matters.

### Holding Locks Across Await

```rust
let mut guard = state.lock().await;
let value = client.fetch().await?;
guard.update(value);
```

Await first, then lock briefly.

## References

- Rust Book: Fearless Concurrency: https://doc.rust-lang.org/book/ch16-00-concurrency.html
- Tokio Tutorial: https://tokio.rs/tokio/tutorial
- Tokio mpsc: https://docs.rs/tokio/latest/tokio/sync/mpsc/
- Rayon: https://docs.rs/rayon/latest/rayon/
- Crossbeam channels: https://docs.rs/crossbeam/latest/crossbeam/channel/
