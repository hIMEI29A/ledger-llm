# Prompt for Openspec Planner

**Role & Goal:**
You are the Openspec Planner. Your task is to kick off the formal specification and architecture breakdown for a new Go project under the working name **`ledger-llm`**. Begin by producing a high-level technical spec, a component inventory, and a phased implementation roadmap. Do not write production code yet — focus on structure, interfaces, concurrency model, and open questions.

---

**Project Identity**

- **Working name:** `ledger-llm`
- **Language:** Go
- **Category:** **Batch LLM Router** (this framing is the primary lens — every design decision should reinforce the "batch" nature: grouping, batching, throughput-oriented scheduling, async pipelines).
- **Form factor:** A high-performance HTTP/gRPC proxy server sitting in front of heterogeneous LLM backends.

---

**Core Concept**

`ledger-llm` is a Go-based proxy that intercepts incoming AI requests and—based on the task's complexity, determined by a lightweight (~1ms) Go-native classifier—routes each request to one of three tiers:

1. **Inexpensive local model** (self-hosted / on-prem)
2. **Mid-tier model** (e.g., GPT-4o-mini)
3. **High-end model** (e.g., Claude / GPT-4o)

The router is the open-source core, alongside a request-metrics tracking subsystem. Commercial layer on top: an integrated billing dashboard and cost-allocation engine for cross-department chargeback (FinOps for LLMs).

---

**Non-Negotiable Architectural Constraints**

- Designed as a **high-performance HTTP/gRPC proxy server** with an **asynchronous processing pipeline**.
- **Lock-free concurrency is the default**: rely on Go `chan` for inter-stage communication and `sync` primitives (`sync.Pool`, `sync/atomic`, `sync.Once`, `sync.WaitGroup`) only where strictly necessary. Explicitly avoid mutex-guarded hot paths.
- The pipeline must be **batch-oriented end to end**: requests are admitted, classified, grouped, dispatched to backends, and reconciled in batches — not one-by-one where avoidable.
- Classifier must be **sub-millisecond to ~1ms** and pure Go (no external inference call in the hot path).

---

**What I Need From You (Planner) in This First Pass**

Produce, in English:

1. **Problem statement & positioning** — why a *batch* LLM router (vs. a per-request router) matters, and what workloads it targets.
2. **System decomposition** — top-level components (ingress, classifier, batch scheduler, backend adapters, metrics tracker, billing/cost-allocation, admin API, config).
3. **Concurrency & data-flow design** — a stage-by-stage pipeline diagram described in text, naming the `chan` boundaries and where `sync` primitives are used; call out the lock-free invariants per stage.
4. **Routing policy spec** — classifier inputs/outputs, tier thresholds, batching keys (e.g., by tier + tenant + deadline), fallback and backpressure behavior.
5. **Open-source vs. commercial boundary** — which modules ship OSS (router + metrics) vs. which are gated (billing dashboard, FinOps allocation).
6. **Public interfaces sketch** — HTTP routes and gRPC service definitions (method names + request/response shapes, not full protos).
7. **Observability & metrics model** — what the metrics tracker records (latency per tier, classifier cost, batch sizes, cost per request) and how it feeds the FinOps layer.
8. **Phased roadmap** — Milestone 0 (skeleton + pipeline), Milestone 1 (classifier + single backend), Milestone 2 (multi-tier batch routing), Milestone 3 (metrics + OSS release), Milestone 4 (billing/FinOps).
9. **Risks & open questions** — batching latency vs. tail-latency tradeoffs, classifier accuracy vs. cost savings, tenant isolation, model-provider rate limits.

Keep the output structured with clear headings so it can be lifted directly into the spec repo. Flag any assumption you make about the classifier, backend adapters, or billing data model.  

