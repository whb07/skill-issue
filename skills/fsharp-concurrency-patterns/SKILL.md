---
name: fsharp-concurrency-patterns
description: Choose and review F# concurrency designs using sequential code, Async, task computation expressions, Task and ValueTask, bounded channels, MailboxProcessor agents, TPL, Parallel.ForEachAsync, cancellation tokens, locks, immutable snapshots, ConcurrentDictionary, Interlocked, and backpressure. Use when deciding how F# work should run concurrently, fixing shared mutable state, bounding fan-out, designing producer/consumer pipelines, bridging Async and Task, preventing blocking in async code, handling shutdown, or choosing between tasks, agents, channels, locks, and data parallelism.
---

# F# Concurrency Patterns

## Operating Model

Start with no concurrency. Add it only for measured performance, I/O concurrency, responsiveness, or a real state-ownership boundary.

F# makes concurrent workflows pleasant; it does not remove architecture problems. Most production bugs come from unbounded fan-out, unobserved tasks, missing cancellation, hidden blocking, long-held locks, unclear ownership, and shared mutable domain state.

Default escalation order:

1. Sequential code.
2. `task {}` or `async {}` for I/O concurrency.
3. `Task.WhenAll`, `Async.Parallel`, or bounded traversal for independent operations.
4. Bounded `System.Threading.Channels` for producer/consumer pipelines and backpressure.
5. `Parallel.ForEachAsync`, TPL, PLINQ, or `Array.Parallel` for CPU-bound parallelism.
6. `MailboxProcessor` when one agent should own state and process messages serially.
7. Locks, `ConcurrentDictionary`, or `Interlocked` for small, boring shared state.

Locks are fine for caches, counters, and short in-memory updates. Do not use a globally shared mutable object as the business workflow engine.

## Decision Guide

| Need | Prefer | Avoid |
|---|---|---|
| One I/O operation | Plain `task {}` or `async {}` | Starting a background task for no reason |
| Fixed independent task calls | `Task.WhenAll` | Manual task plumbing |
| Fixed independent async calls | `Async.Parallel` | Sequential `let!` when calls are independent |
| Many async jobs | Bounded traversal or `Parallel.ForEachAsync` | Unbounded `List.map Task.Run` |
| CPU-heavy parallel work | TPL, PLINQ, `Array.Parallel`, measured loops | Running CPU loops in async workflows |
| Blocking API from async code | Dedicated scheduler or `Task.Run` with bounds | Blocking thread-pool threads casually |
| Producer/consumer queue | Bounded `Channel<T>` | Unbounded channels by habit |
| Serialized state machine | `MailboxProcessor` plus bounded or controlled mailbox | Shared mutable domain state |
| Small shared cache | `ConcurrentDictionary` or short `lock` | Locking around I/O |
| Shared counter or flag | `Interlocked` or volatile read/write | Locking hot counters |

Ask these questions before choosing:

1. Is the work I/O-bound, CPU-bound, or state-serialization-bound?
2. Who owns the data?
3. What bounds memory growth?
4. How are errors observed?
5. How does shutdown happen?
6. What happens on cancellation?

## Async and Task

Use `task {}` for .NET-facing asynchronous APIs and interop with `Task`. Use `async {}` when the codebase already uses F# `Async` workflows or needs F# async composition.

```fsharp
let getOrderSummary orderId (orders: IOrderClient) (customers: ICustomerClient) =
    task {
        let! order = orders.Get(orderId)
        let! customer = customers.Get(order.CustomerId)
        return OrderSummary.create order customer
    }
```

Run independent calls together:

```fsharp
let loadDashboard userId (orders: IOrderClient) (notifications: INotificationClient) (stats: IStatsClient) =
    task {
        let ordersTask = orders.Recent(userId)
        let notificationsTask = notifications.Unread(userId)
        let statsTask = stats.ForUser(userId)

        let! recentOrders = ordersTask
        let! unreadNotifications = notificationsTask
        let! userStats = statsTask

        return
            { Orders = recentOrders
              Notifications = unreadNotifications
              Stats = userStats }
    }
```

Async rules:

- Use `Task.WhenAll` or `Async.Parallel` when independent operations should run concurrently and have a compatible shape.
- For heterogeneous task results, start the tasks first, then await each named task as shown above.
- Do not make pure CPU functions async.
- Do not block with `.Result`, `.Wait()`, `Async.RunSynchronously`, `Thread.Sleep`, or blocking I/O inside async workflows.
- Pass `CancellationToken` through long-running and I/O APIs.
- Convert explicitly at boundaries with `Async.AwaitTask` or `Async.StartAsTask`.
- Know cancellation semantics; cancellation is cooperative and must be passed into work.

## Bounded Fan-Out

Bound concurrency when processing many jobs.

```fsharp
open System.Collections.Generic
open System.Threading
open System.Threading.Tasks

let fetchAll (maxConcurrency: int) (client: IOrderClient) (ids: IReadOnlyCollection<OrderId>) =
    task {
        use gate = new SemaphoreSlim(maxConcurrency)
        let results = ResizeArray<Order>()

        let fetchOne id =
            task {
                do! gate.WaitAsync()
                try
                    let! order = client.Get(id)
                    lock results (fun () -> results.Add order)
                finally
                    gate.Release() |> ignore
            }

        do! ids |> Seq.map fetchOne |> Task.WhenAll
        return results |> Seq.toList
    }
```

Fan-out rules:

- Set an explicit concurrency limit for variable-size work.
- Observe every task result.
- Decide whether partial failure cancels remaining work or lets it drain.
- Prefer `Parallel.ForEachAsync` when it fits the workload and target framework.
- Avoid starting more work than downstream systems can absorb.

## CPU-Bound Work

Use parallel CPU tools for CPU-heavy loops, parsing, compression, image processing, scoring, and batch transformations.

```fsharp
let scoreOrders (orders: Order[]) =
    orders
    |> Array.Parallel.map scoreOrder
```

For async entry points, keep CPU work explicit:

```fsharp
let parseLargeFile bytes =
    Task.Run(fun () -> parseFile bytes)
```

CPU rules:

- Async workflows are not CPU schedulers.
- Use `Array.Parallel`, `Parallel.ForEach`, PLINQ, or `Task.Run` only when CPU work is substantial enough to justify overhead.
- Bound CPU parallelism when work competes with request handling.
- Avoid nested parallelism without measuring.
- Prefer ordinary loops for small collections and hot paths where overhead dominates.

## Channels and Backpressure

Use bounded channels for producer/consumer work, fan-in, fan-out, decoupling, and backpressure.

```fsharp
open System.Threading
open System.Threading.Channels

type OrderQueue(capacity: int) =
    let options = BoundedChannelOptions(capacity)

    do
        options.SingleReader <- true
        options.SingleWriter <- false

    let channel =
        Channel.CreateBounded<OrderCommand>(options)

    member _.Submit(command: OrderCommand, cancellationToken: CancellationToken) =
        channel.Writer.WriteAsync(command, cancellationToken).AsTask()

    member _.Reader = channel.Reader
    member _.Complete() = channel.Writer.Complete()

let runOrderWorker (reader: ChannelReader<OrderCommand>) cancellationToken =
    task {
        let mutable keepReading = true

        while keepReading && not cancellationToken.IsCancellationRequested do
            let! hasItem = reader.WaitToReadAsync(cancellationToken).AsTask()
            keepReading <- hasItem

            let mutable drain = hasItem
            while drain do
                match reader.TryRead() with
                | true, command ->
                    do! handleOrderCommand command
                | false, _ ->
                    drain <- false
    }
```

Channel rules:

- Use bounded channels by default; backpressure is a feature.
- Require a written reason for unbounded channels.
- Make messages domain commands or events, not anonymous tuples.
- Define close behavior: who completes the writer, who drains the reader, and which messages may be lost.
- Treat write/read failure as shutdown unless the domain has a stronger meaning.
- Prefer channels over ad hoc shared queues plus locks.

## MailboxProcessor Agents

Use `MailboxProcessor` for long-lived state machines, serialized command handling, entity-local state, timers, retries, and command/query interactions.

```fsharp
type CartReply = AsyncReplyChannel<Result<CartSnapshot, CartError>>

type CartCommand =
    | AddItem of CartItem * CartReply
    | Checkout of AsyncReplyChannel<Result<OrderId, CartError>>
    | Stop

let startCartAgent initialCart =
    MailboxProcessor.Start(fun inbox ->
        let rec loop cart =
            async {
                let! command = inbox.Receive()
                match command with
                | AddItem(item, reply) ->
                    match Cart.addItem item cart with
                    | Ok updatedCart ->
                        reply.Reply(Ok(Cart.snapshot updatedCart))
                        return! loop updatedCart
                    | Error error ->
                        reply.Reply(Error error)
                        return! loop cart
                | Checkout reply ->
                    let! result = Cart.checkout cart
                    reply.Reply result
                    return! loop cart
                | Stop ->
                    return ()
            }

        loop initialCart)
```

Agent rules:

- The agent owns its state; callers do not mutate it directly.
- Use explicit domain messages.
- Use `PostAndAsyncReply` or reply channels for request/response interactions.
- Decide what happens when the agent fails, exits, or falls behind.
- Consider bounded channels instead when mailbox growth must be strictly bounded.
- Store and supervise agent lifetimes when failure matters.
- Do not build a distributed actor runtime unless that is the product.

Agents are useful when state transitions are complex, command ordering matters, timers and retries belong with state, or each entity can be isolated independently. They are overkill for stateless request/response code, simple CRUD, pure transformations, or a single cache.

## Locks and Shared State

Use locks for small shared state, caches, counters, dedup maps, and cheap in-memory updates.

```fsharp
type CustomerCache() =
    let gate = obj()
    let values = Dictionary<CustomerId, Customer>()

    member _.TryGet(id) =
        lock gate (fun () ->
            match values.TryGetValue id with
            | true, value -> Some value
            | false, _ -> None)

    member _.Put(customer) =
        lock gate (fun () ->
            values[Customer.id customer] <- customer)
```

Lock rules:

- Lock only the data needed for the operation.
- Keep critical sections tiny and synchronous.
- Do not perform I/O while holding a lock.
- Do not call user callbacks while holding a lock.
- Do not await inside a lock; use `SemaphoreSlim` for async gates when necessary.
- Prefer immutable snapshots when readers need stable views.
- Use `ConcurrentDictionary` for straightforward concurrent maps.
- Use `Interlocked` for independent counters and flags.

## Cancellation and Shutdown

Every long-running workflow needs a shutdown path.

```fsharp
let runWorker (reader: ChannelReader<Job>) (ct: CancellationToken) =
    task {
        try
            let mutable keepReading = true

            while keepReading && not ct.IsCancellationRequested do
                let! hasItem = reader.WaitToReadAsync(ct).AsTask()
                keepReading <- hasItem

                let mutable drain = hasItem
                while drain do
                    match reader.TryRead() with
                    | true, job ->
                        do! process job ct
                    | false, _ ->
                        drain <- false
        with
        | :? OperationCanceledException when ct.IsCancellationRequested ->
            ()
    }
```

Shutdown rules:

- Store task, agent, and worker handles when failure matters.
- Signal shutdown explicitly with channel completion, cancellation tokens, or stop messages.
- Drain queues when correctness matters; drop queues when latency matters more.
- Log worker exits and errors.
- Test shutdown paths for workers, agents, and queues.
- Avoid fire-and-forget `Async.Start` or ignored tasks in production paths.

## Review Checklist

Use this checklist for F# concurrency design and PR review:

- [ ] Concurrency is necessary and its purpose is clear.
- [ ] Work is classified as I/O-bound, CPU-bound, or state-serialization-bound.
- [ ] Fan-out and queues are bounded unless explicitly justified.
- [ ] Task and async results are observed.
- [ ] Cancellation tokens flow through long-running and I/O work.
- [ ] Long-running workers have shutdown paths.
- [ ] CPU or blocking work does not accidentally block async request paths.
- [ ] Locks guard small data and are not held across awaits, I/O, or callbacks.
- [ ] Shared mutable domain state is isolated behind an agent, channel, or narrow lock.
- [ ] Channel or agent messages are explicit domain types.
- [ ] Backpressure, overload, and dropped-message behavior are documented.
- [ ] Tests cover shutdown, cancellation, and error propagation where behavior is important.

## Common Anti-Patterns

### Unbounded Task Fan-Out

```fsharp
items |> List.map (fun item -> Task.Run(fun () -> process item))
```

Use bounded traversal or `Parallel.ForEachAsync`.

### Blocking Inside Async

```fsharp
task {
    let result = client.GetAsync(uri).Result
    return result
}
```

Await instead.

### Shared Mutable Workflow State

```fsharp
let mutable currentOrderState = Map.empty
```

Prefer an owner agent, channel worker, or explicit state transition pipeline.

### Fire and Forget

```fsharp
Async.Start(runForever())
```

Store the handle or cancellation source, define shutdown, and observe errors.

### Lock Around I/O

```fsharp
lock gate (fun () ->
    client.SendAsync(message).Wait())
```

Do I/O outside the lock and update shared state briefly.

## References

- F# async workflows: https://learn.microsoft.com/dotnet/fsharp/language-reference/async-expressions
- Task expressions: https://learn.microsoft.com/dotnet/fsharp/language-reference/task-expressions
- System.Threading.Channels: https://learn.microsoft.com/dotnet/core/extensions/channels
- Task Parallel Library: https://learn.microsoft.com/dotnet/standard/parallel-programming/task-parallel-library-tpl
