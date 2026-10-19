/// Agent reputation — thin on-chain score aggregates (S.1054, Phase C of
/// SPEC_AGENT_ID_REPUTATION).
///
/// One shared `AgentScore` per reviewed seller, created lazily on their first
/// review at a DETERMINISTIC address derived from the shared `ScoreBoard`
/// (`sui::derived_object`): no score object ⇔ zero reviews (Anyone-claims OK,
/// Proven claims abort). Aggregates only — `review_count` + `stars_sum` —
/// review TEXT stays off-chain (jobId-keyed); an average is integer math over
/// the two counters. Per-job stars live in a `Table` under the seller's own
/// score, so storage growth is per-agent, never global.
///
/// Parallelism, honestly (S.1054b): review EDITS and later reviews touch
/// only that seller's score (parallel across sellers), and Proven claims
/// take the claimer's score by IMMUTABLE reference (parallel with
/// everything). The exception is the FIRST review a seller ever gets:
/// `submit_first_review` needs `&mut ScoreBoard` for
/// `derived_object::claim`, so all new-score creates serialize on the one
/// board — an accepted v1 scale limit (first reviews are rare relative to
/// reviews). Two racers creating the same seller's score: one wins, the
/// loser aborts on the derived claim and retries with `submit_review`
/// against the score that now exists.
///
/// **Placement (documented deviation from SPEC_AGENT_ID_REPUTATION §3's
/// "prefer agent_id"):** the review writer must see `&Job<T>` to verify the
/// receipt, and `a2a_escrow` already depends on `agent_id` — storing the
/// score under `agent_id` would need either an illegal dependency cycle or a
/// hardcoded witness-package handshake (three ordered mainnet upgrades, since
/// the witness type's defining id doesn't exist until escrow republishes).
/// Parking storage AND writer here keeps the apply path unforgeable for free
/// (module-internal, `apply_review` is private) and the cutover to ONE
/// additive escrow upgrade. The SPEC/prompt explicitly allow this shape.
///
/// Write authority (all Move-enforced — reputation is receipts):
/// - sender == `Job.buyer` and `Job.state == RELEASED` **or REJECTED**
///   (S.1064 — both settled money paths on delivered work)
/// - the job was actually DELIVERED (`delivered_at_ms > 0`): a goodwill
///   release of an undelivered job is not a reviewable receipt (the on-chain
///   form of the API's no-goodwill-review rule)
/// - one contribution per `job_id`; resubmitting = star edit in place
///   (`stars_sum` adjusts, `review_count` doesn't)
/// - NO AdminCap / mint path: the protocol cannot gift stars. (The one
///   narrow S.1255 exception, `set_active_seller_jobs`, writes ONLY the
///   active-seat mirror — never stars, distinct, or outcome counters.)
module a2a_escrow::reputation;

use a2a_escrow::escrow::{Self, AdminCap, FeeConfig, Job};
use agent_id::registry::{Self, Registry};
use sui::clock::Clock;
use sui::derived_object;
use sui::dynamic_field as df;
use sui::event;
use sui::table::{Self, Table};

// === Proven thresholds (protocol constants, one SSOT) ===
/// `claim_policy = 1` (and the floor of `2`). Since S.1062 this is the
/// DISTINCT-BUYER floor (was raw review count in v1) — the numeric value
/// is unchanged at 3; the name survives for the published surface.
const PROVEN_MIN_REVIEWS: u64 = 3;
/// `claim_policy = 2`: minimum average stars, scaled ×10 (40 = 4.0★).
const PROVEN_MIN_AVG_STARS_X10: u64 = 40;
/// The ×10 scale used for the integer-math average compare.
const AVG_SCALE: u64 = 10;
/// Star bounds — a 0-star write would corrupt the average math.
const MIN_STARS: u8 = 1;
const MAX_STARS: u8 = 5;

// === Seller levels (S.1192) — protocol constants, one SSOT ===
/// Level 4 additionally needs this many reviews… (S.1210: 20 → 10 — the
/// young marketplace made Veteran feel unreachable).
const LEVEL4_MIN_REVIEWS: u64 = 10;
/// …and at most this many no-delivery outcomes.
const LEVEL4_MAX_NO_DELIVERY: u64 = 2;
/// `ActiveSellerJobsChanged.delta` values (u8 — Move has no signed ints;
/// same encoding house as `OutcomeRecorded.kind`).
const ACTIVE_DELTA_CLAIM: u8 = 0; // +1
const ACTIVE_DELTA_SETTLE: u8 = 1; // −1
/// S.1255 — AdminCap reconcile: the counter was SET to an absolute value
/// (healing pre-v14 decline burns), not moved by a money path.
const ACTIVE_DELTA_ADMIN_SET: u8 = 2;

// === Errors ===
const ENotBuyer: u64 = 0;
/// Not a reviewable state — reviews attach to RELEASED or (since S.1064)
/// REJECTED jobs only. Name kept from v1 for the stable abort code 1.
const ENotReleased: u64 = 1;
/// RELEASED but never DELIVERED = goodwill settle — not reviewable.
const ENotDelivered: u64 = 2;
const EBadStars: u64 = 3;
/// The passed `AgentScore` doesn't belong to this job's seller.
const EWrongScore: u64 = 4;
/// Structurally impossible (escrow::create asserts buyer != seller) —
/// asserted anyway so this module's invariant never depends on a sibling's.
const ESelfReview: u64 = 5;
/// S.1063: the passed buyer `AgentScore` doesn't belong to this job's buyer.
const EWrongBuyerScore: u64 = 6;
/// S.1063: this buyer is a registered Agent ID — reject must go through
/// `reject_v2_agent_buyer` (an agent buyer cannot dodge its own
/// `as_buyer_rejected` counter by picking the Passport variant).
const EBuyerIsAgent: u64 = 7;
/// S.1063: this buyer is NOT a registered Agent ID — use `reject_v2`
/// (Passport buyers never get a public chain counter).
const EBuyerNotAgent: u64 = 8;
/// S.1202: this Job carries `BatchOriginKey` — its terminal settle must
/// go through the batch-aware doors (`batch::batch_release` /
/// `batch_reject*` / `batch_refund`), which free the per-wave hold in the
/// same tx. A bare v2 settle would silently leak the wave seat, so it
/// aborts loudly here instead (the S.1032/S.1063 dedicated-code pattern).
const EUseBatchSettle: u64 = 9;
/// S.1210: this Job carries `BatchOriginKey` — deliver must go through
/// `batch::deliver_v2`, which also frees the per-wave hold in the same
/// tx (same loud-abort pattern as `EUseBatchSettle`).
const EUseBatchDeliver: u64 = 10;
/// S.1255: `set_active_seller_jobs` value above the Level 4 active cap —
/// the reconcile door only writes counts a seller could legitimately
/// hold; anything larger is a fat-fingered set, refused loudly.
const EActiveSetOutOfBounds: u64 = 11;

// === Objects ===

/// The one shared namespace parent for derived `AgentScore` addresses.
/// Created ONCE post-upgrade via `create_score_board` (module `init` does not
/// re-run on package upgrade) — single instance is CHAIN-ENFORCED via the
/// `ScoreBoardKey` DF on `FeeConfig` (S.1054b); the pinned client constant
/// mirrors `escrow::config_score_board_id`. Holds no table —
/// `derived_object::claim` markers on its UID are the per-agent uniqueness
/// guarantee, and it is only `&mut` on an agent's FIRST review.
public struct ScoreBoard has key {
    id: UID,
}

/// One seller's on-chain reputation. Shared, at
/// `derived_object::derive_address(board, agent)` — clients can compute the
/// id locally with no lookup. Aggregates only; per-job stars in `job_stars`
/// enforce one contribution per job and make edits update-in-place.
public struct AgentScore has key {
    id: UID,
    /// The reviewed seller (Agent ID address). Claim gates verify this
    /// matches the claimer — you cannot borrow someone else's score.
    agent: address,
    review_count: u64,
    stars_sum: u64,
    job_stars: Table<ID, u8>,
    created_at_ms: u64,
    updated_at_ms: u64,
}

// === v2 distinct-buyer state (S.1062) — DFs on `AgentScore.id` ===
// Live scores cannot grow struct fields under a compatible upgrade (the
// FeeConfig-DF house rule), and `submit_review`'s frozen signature only
// carries `&TxContext` — so instead of one Table-carrying DF (whose lazy
// create would need `&mut TxContext`), membership + count are plain
// dynamic fields on the score UID: same O(1)/unbounded properties (every
// Table entry IS a DF), zero signature changes, no migrate of live
// objects. NO GRANDFATHER: pre-S.1062 reviews never seed these — an
// agent's distinct count starts at 0 and grows only from post-upgrade
// review writes (founder lock: no AdminCap/backfill mint).

/// DF key → `u64`: how many distinct buyer addresses have contributed a
/// star review since S.1062. Missing ⇒ 0.
public struct DistinctCountKey has copy, drop, store {}
/// DF key → `bool`: this buyer has already counted toward distinct.
public struct BuyerSeenKey has copy, drop, store { buyer: address }

// === v2 protocol-outcome counters (S.1063) — DFs on `AgentScore.id` ===
// Outcomes are NOT stars: they never touch stars_sum / review_count /
// distinct buyers / meets_proven (display-only this rev — no gate reads
// them). No grandfather, no AdminCap repair. Missing DF ⇒ 0.

/// Seller was rejected AFTER delivering (buyer used `reject`).
public struct RejectedAfterDeliveryKey has copy, drop, store {}
/// Seller hit the deadline with NO delivery (permissionless `refund`).
/// A seller's own pre-delivery `decline` never pads this — clean walk.
public struct NoDeliveryKey has copy, drop, store {}
/// This agent, as a BUYER, rejected delivered work (Agent-ID buyers only —
/// Passport buyers never get a public chain counter: privacy lock).
public struct AsBuyerRejectedKey has copy, drop, store {}

// === v2 active-job counter (S.1192 · S.1210 · S.1255) — DF on
// === `AgentScore.id` ===
// FUNDED, UNDELIVERED board-claimed jobs this seller holds (S.1210: the
// seat frees at DELIVER — buyer settle latency no longer blocks a
// hunter's throughput). +1 in `opening::do_claim` / `batch::batch_claim`
// (via `increment_active`); −1 at deliver (`on_job_delivered`, v13
// packages mark `ActiveFreedKey` on the Job), at decline (`decline_v2`,
// S.1255 — the pre-v14 rule burned the seat forever) or — for goodwill
// releases on FUNDED, deadline refunds, and pre-v13 delivered
// stragglers — at the terminal settle of jobs carrying
// `escrow::ClaimedJobKey`. Hire jobs never move it — they never
// incremented, and an unconditional decrement would let a colluding
// buyer reset a hunter's counter with a dust hire. Missing ⇒ 0 (soft
// start — no backfill, pre-upgrade claims never count). One narrow
// non-money writer exists since S.1255: the AdminCap
// `set_active_seller_jobs` reconcile door, healing counts inflated by
// pre-v14 decline burns.

/// DF key → `u64`: this seller's live claimed-job count. Missing ⇒ 0.
public struct ActiveSellerJobsKey has copy, drop, store {}

// === Events (the indexer's score read-model is built from these) ===
public struct ScoreBoardCreated has copy, drop {
    board_id: ID,
    timestamp_ms: u64,
}
public struct ScoreCreated has copy, drop {
    score_id: ID,
    agent: address,
    timestamp_ms: u64,
}
/// Emitted on every review write, first OR edit — carries the post-write
/// aggregates so the read-model never has to fetch the object.
/// Layout FROZEN at v6 (event structs can't grow under compatible
/// upgrade) — v2 consumers read the `ReviewSubmittedV2` sibling.
public struct ReviewSubmitted has copy, drop {
    score_id: ID,
    agent: address,
    job_id: ID,
    buyer: address,
    stars: u8,
    /// 0 = first review for this job; non-zero = an edit replacing that value.
    previous_stars: u8,
    review_count: u64,
    stars_sum: u64,
    timestamp_ms: u64,
}

/// S.1062 sibling of `ReviewSubmitted` (same fields + `distinct_buyers`,
/// emitted together on every write) — a NEW struct because the v6 event's
/// layout is frozen. Defining id = the S.1062 upgrade package; indexers
/// pin that id and prefer this event.
public struct ReviewSubmittedV2 has copy, drop {
    score_id: ID,
    agent: address,
    job_id: ID,
    buyer: address,
    stars: u8,
    previous_stars: u8,
    review_count: u64,
    stars_sum: u64,
    /// Post-write distinct-buyer count (S.1062 — the Proven gate input).
    distinct_buyers: u64,
    timestamp_ms: u64,
}

// Outcome kinds carried by `OutcomeRecorded` (S.1063).
const OUTCOME_REJECTED_AFTER_DELIVERY: u8 = 0;
const OUTCOME_NO_DELIVERY: u8 = 1;
const OUTCOME_AS_BUYER_REJECTED: u8 = 2;

/// S.1063 — one protocol outcome landed on a score. `value` is the
/// POST-write counter, so the read-model mirrors without a fetch.
/// Defining id = the S.1063 upgrade package (V8 pin).
public struct OutcomeRecorded has copy, drop {
    score_id: ID,
    agent: address,
    job_id: ID,
    /// 0 = rejected_after_delivery · 1 = no_delivery · 2 = as_buyer_rejected
    kind: u8,
    value: u64,
    timestamp_ms: u64,
}

/// S.1192 — the seller's in-flight claimed-job counter moved.
/// `active_seller_jobs` is the POST-write value (read-model mirrors
/// without a fetch); `delta` is 0 = +1 (claim) · 1 = −1 (terminal
/// settle, deliver, or decline) · 2 = AdminCap reconcile set (S.1255 —
/// `job_id` is the 0x0 sentinel there: no job moved the counter).
/// Defining id = the S.1192 upgrade package (V10 pin).
public struct ActiveSellerJobsChanged has copy, drop {
    score_id: ID,
    agent: address,
    job_id: ID,
    active_seller_jobs: u64,
    /// 0 = +1 (claim) · 1 = −1 (deliver/decline/release/reject/refund of
    /// a claimed job) · 2 = absolute AdminCap set (reconcile)
    delta: u8,
    timestamp_ms: u64,
}

// === One-time setup (AdminCap — upgrade can't run `init`) ===

/// Share the score namespace parent — ONCE, chain-enforced (S.1054b): the
/// board id records into the `ScoreBoardKey` DF on `FeeConfig`, and a
/// second call aborts `escrow::EScoreBoardExists` (a second board would
/// split the derived-address namespace and fork the score SSOT).
/// AdminCap-gated so a stranger can't share a decoy board — but the cap
/// grants NO star authority: every star still requires a RELEASED job
/// receipt, and this function mints none.
public fun create_score_board(
    _: &AdminCap,
    cfg: &mut FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    let board = ScoreBoard { id: object::new(ctx) };
    let board_id = board.id.to_inner();
    escrow::record_score_board_pkg(cfg, board_id); // aborts if one exists
    event::emit(ScoreBoardCreated {
        board_id,
        timestamp_ms: clock.timestamp_ms(),
    });
    transfer::share_object(board);
}

// === Review writes (buyer, RELEASED receipt only) ===

/// First review a seller ever receives: lazily creates + shares their
/// `AgentScore` at its derived address. Aborts if the score already exists
/// (`derived_object::claim` is the uniqueness gate) — callers race-fall-back
/// to `submit_review`.
public fun submit_first_review<T>(
    board: &mut ScoreBoard,
    job: &Job<T>,
    stars: u8,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    let seller = validate_review(job, stars, ctx);
    let now = clock.timestamp_ms();
    let mut score = AgentScore {
        id: derived_object::claim(&mut board.id, seller),
        agent: seller,
        review_count: 0,
        stars_sum: 0,
        job_stars: table::new(ctx),
        created_at_ms: now,
        updated_at_ms: now,
    };
    event::emit(ScoreCreated {
        score_id: score.id.to_inner(),
        agent: seller,
        timestamp_ms: now,
    });
    apply_review(&mut score, object::id(job), ctx.sender(), stars, now);
    transfer::share_object(score);
}

/// Every later review — and star EDITS (same buyer re-rating the same job):
/// touches only this seller's score, so unrelated reviews run in parallel.
#[allow(lint(prefer_mut_tx_context))]
public fun submit_review<T>(
    score: &mut AgentScore,
    job: &Job<T>,
    stars: u8,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &TxContext,
) {
    escrow::assert_version_pkg(cfg);
    let seller = validate_review(job, stars, ctx);
    assert!(score.agent == seller, EWrongScore);
    apply_review(score, object::id(job), ctx.sender(), stars, clock.timestamp_ms());
}

// === Outcome settlement (S.1063) — the live reject/refund doors for
// === NON-batch jobs (S.1202: batch-origin jobs settle via `batch::*`) ===
// Money moves in `escrow::{reject,refund}_settle_pkg` (single source for
// coin/fee math + the frozen v1 events); the counters land here. Outcomes
// never touch stars/distinct/Proven — display-only protocol facts.

/// Lazily create an agent's zero score (permissionless — a zero score
/// grants NOTHING: no stars, no distinct, no Proven; UI must not imply
/// reviews from mere existence). Needed before an outcome verb when the
/// agent has no score yet — a shared object can't be created and then
/// passed as input inside one tx, so this is its own (sponsored) step.
/// Aborts if the score already exists (`derived_object::claim`).
public fun create_empty_score(
    board: &mut ScoreBoard,
    agent: address,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    let now = clock.timestamp_ms();
    let score = AgentScore {
        id: derived_object::claim(&mut board.id, agent),
        agent,
        review_count: 0,
        stars_sum: 0,
        job_stars: table::new(ctx),
        created_at_ms: now,
        updated_at_ms: now,
    };
    event::emit(ScoreCreated {
        score_id: score.id.to_inner(),
        agent,
        timestamp_ms: now,
    });
    transfer::share_object(score);
}

/// Buyer rejects delivered work — PASSPORT (unregistered) buyer variant:
/// settles the split and records `rejected_after_delivery` on the seller.
/// Aborts `EBuyerIsAgent` for registered buyers — an Agent-ID buyer must
/// use `reject_v2_agent_buyer` and accrue its own counter (no dodging).
public fun reject_v2<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    registry: &Registry,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!escrow::is_batch_origin_job(job), EUseBatchSettle); // S.1202
    assert!(!registry::is_registered(registry, escrow::buyer(job)), EBuyerIsAgent);
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    escrow::reject_settle_pkg(job, cfg, clock, ctx); // auth: sender==buyer, DELIVERED, in-window
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    record_outcome(
        seller_score,
        job_id,
        RejectedAfterDeliveryKey {},
        OUTCOME_REJECTED_AFTER_DELIVERY,
        now,
    );
    // S.1192/S.1210: a reject is always on DELIVERED work — on v13 the
    // seat already freed at deliver; the un-marked branch catches jobs
    // delivered on a pre-v13 package.
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        decrement_active(seller_score, job_id, now);
    };
}

/// Buyer rejects delivered work — AGENT-ID buyer variant: same settle +
/// seller counter, plus `as_buyer_rejected` on the buyer's OWN score
/// (transparency cuts both ways — SPEC v2 §2.3).
public fun reject_v2_agent_buyer<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    buyer_score: &mut AgentScore,
    registry: &Registry,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!escrow::is_batch_origin_job(job), EUseBatchSettle); // S.1202
    let buyer = escrow::buyer(job);
    assert!(registry::is_registered(registry, buyer), EBuyerNotAgent);
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    assert!(buyer_score.agent == buyer, EWrongBuyerScore);
    escrow::reject_settle_pkg(job, cfg, clock, ctx);
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    record_outcome(
        seller_score,
        job_id,
        RejectedAfterDeliveryKey {},
        OUTCOME_REJECTED_AFTER_DELIVERY,
        now,
    );
    record_outcome(
        buyer_score,
        job_id,
        AsBuyerRejectedKey {},
        OUTCOME_AS_BUYER_REJECTED,
        now,
    );
    // S.1192/S.1210: seller seat frees unless deliver already freed it
    // (the SELLER's counter only — a buyer's as_buyer facts never touch
    // capacity).
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        decrement_active(seller_score, job_id, now);
    };
}

/// Deadline refund (no delivery) — permissionless crank, plus
/// `no_delivery` on the seller. The seller's own pre-delivery `decline`
/// never lands here (decline is a clean walk, no reputation write).
public fun refund_v2<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!escrow::is_batch_origin_job(job), EUseBatchSettle); // S.1202
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    escrow::refund_settle_pkg(job, cfg, clock, ctx); // auth: FUNDED, past deadline
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    record_outcome(
        seller_score,
        job_id,
        NoDeliveryKey {},
        OUTCOME_NO_DELIVERY,
        now,
    );
    // S.1192: the abandoned claimed job frees its seat (the no_delivery
    // counter above is what costs the seller — via level regression). A
    // refund is definitionally undelivered, so `ActiveFreedKey` can never
    // be set here — the guard is uniformity, not a live branch.
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        decrement_active(seller_score, job_id, now);
    };
}

/// Seller's pre-delivery decline (S.1255 / v14) — the live decline door:
/// settles the fee-free full refund via `escrow::decline_settle_pkg`
/// (auth unchanged from v3: sender == seller, FUNDED only), then frees
/// the seller's GLOBAL active seat for board-claimed jobs — the same
/// idempotent `ActiveFreedKey` + decrement pattern as deliver. This is an
/// INTENTIONAL design change, not a bugfix: pre-v14, decline burned the
/// global seat forever (anti claim→decline churn); S.1255 deletes that
/// lock — what remains anti-farm is the D13 per-wave hold (deliberately
/// NOT freed here: batch-origin jobs decline through this same single
/// door, and their wave seat stays burned) plus the deadline
/// `no_delivery` outcome, which a decline still never writes (clean walk
/// for reputation). Hire jobs pass through — no `ClaimedJobKey`, no
/// counter move.
public fun decline_v2<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    escrow::decline_settle_pkg(job, cfg, clock, ctx);
    // Same shape as `on_job_delivered` — but a decline is terminal, so the
    // one-shot stamp here is uniformity + a loud lock against any future
    // path double-freeing this Job's seat.
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        escrow::mark_active_freed_pkg(job);
        decrement_active(seller_score, object::id(job), clock.timestamp_ms());
    };
}

/// Release — funds → seller minus the protocol fee (S.1192: the live
/// release door for every NON-batch job; S.1202: batch-origin jobs abort
/// here and settle via `batch::batch_release`, which also frees the
/// per-wave hold). Money settles in escrow's package-visible
/// `release_settle_pkg` (auth unchanged from v1: buyer accept, buyer
/// goodwill on FUNDED, or anyone after the review window lapses); the
/// seller's active-job counter decrements here for board-claimed jobs.
/// The permissionless-crank property survives: any sender may call this —
/// the score input is the SELLER's (verified against the job), not the
/// caller's.
public fun release_v2<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!escrow::is_batch_origin_job(job), EUseBatchSettle); // S.1202
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    escrow::release_settle_pkg(job, cfg, clock, ctx);
    // S.1210: on DELIVERED the seat freed at deliver (marker present);
    // a goodwill release on FUNDED (no delivery, no marker) still frees.
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        decrement_active(seller_score, object::id(job), clock.timestamp_ms());
    };
}

/// Deliver a NON-batch Job with the seller's score attached (S.1210 /
/// v13) — the live deliver door: posts the delivery via `escrow::deliver`
/// (auth unchanged: sender == seller, FUNDED, before deadline), then
/// frees the seller's global active seat for board-claimed jobs so buyer
/// settle latency never blocks throughput. Batch-origin jobs abort here
/// and deliver through `batch::deliver_v2` (which also frees the wave
/// hold). Hire jobs pass through — no `ClaimedJobKey`, no counter move.
public fun deliver_v2<T>(
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    delivery_hash: vector<u8>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(!escrow::is_batch_origin_job(job), EUseBatchDeliver);
    assert!(seller_score.agent == escrow::seller(job), EWrongScore);
    escrow::deliver(job, delivery_hash, cfg, clock, ctx);
    on_job_delivered(seller_score, job, clock.timestamp_ms());
}

/// The deliver-time seat release (S.1210) — package-visible so
/// `batch::deliver_v2` lands the SAME semantics. Idempotent: only
/// board-claimed jobs whose seat is still held move the counter, and the
/// one-shot `ActiveFreedKey` stamp makes the settle paths skip their
/// decrement afterwards.
public(package) fun on_job_delivered<T>(
    score: &mut AgentScore,
    job: &mut Job<T>,
    now: u64,
) {
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        escrow::mark_active_freed_pkg(job);
        decrement_active(score, object::id(job), now);
    };
}

/// The ONLY outcome mutator — private; a counter can never move except
/// through the settle-validated paths above.
fun record_outcome<K: copy + drop + store>(
    score: &mut AgentScore,
    job_id: ID,
    key: K,
    kind: u8,
    now: u64,
) {
    let value = if (df::exists(&score.id, key)) {
        let count: &mut u64 = df::borrow_mut(&mut score.id, key);
        *count = *count + 1;
        *count
    } else {
        df::add(&mut score.id, key, 1u64);
        1
    };
    score.updated_at_ms = now;
    event::emit(OutcomeRecorded {
        score_id: score.id.to_inner(),
        agent: score.agent,
        job_id,
        kind,
        value,
        timestamp_ms: now,
    });
}

// === Batch settle hooks (S.1202) — package-visible outcome recorders ===
// The batch-aware settle doors in `batch` must land the SAME counters the
// v2 doors do; `record_outcome` stays private (the typed DF keys are the
// authority), so `batch` gets these thin package-visible wrappers instead.
// No cycle: `batch` imports `reputation`, never the reverse.

/// `rejected_after_delivery` +1 — for `batch::batch_reject*` only.
public(package) fun record_rejected_after_delivery_pkg(
    score: &mut AgentScore,
    job_id: ID,
    now: u64,
) {
    record_outcome(
        score,
        job_id,
        RejectedAfterDeliveryKey {},
        OUTCOME_REJECTED_AFTER_DELIVERY,
        now,
    );
}

/// `no_delivery` +1 — for `batch::batch_refund` only.
public(package) fun record_no_delivery_pkg(score: &mut AgentScore, job_id: ID, now: u64) {
    record_outcome(score, job_id, NoDeliveryKey {}, OUTCOME_NO_DELIVERY, now);
}

/// `as_buyer_rejected` +1 — for `batch::batch_reject_agent_buyer` only.
public(package) fun record_as_buyer_rejected_pkg(
    score: &mut AgentScore,
    job_id: ID,
    now: u64,
) {
    record_outcome(score, job_id, AsBuyerRejectedKey {}, OUTCOME_AS_BUYER_REJECTED, now);
}

// === Active-job counter (S.1192) — package-private mutators ===
// Only `opening::do_claim` and `batch::batch_claim` increment; only the
// terminal settle paths decrement — the three v2 doors above for
// non-batch jobs, the `batch::batch_release`/`batch_reject*`/
// `batch_refund` doors for batch-origin jobs (claimed jobs only).
// Package-private, so the counter can never move except with the money.

/// +1 — called by `opening::do_claim` after the Job mints. Serializes
/// same-seller claims on the score object (correct: that IS the cap);
/// different sellers touch different scores and stay parallel (S.1054
/// model preserved across agents).
public(package) fun increment_active(score: &mut AgentScore, job_id: ID, now: u64) {
    let value = if (df::exists(&score.id, ActiveSellerJobsKey {})) {
        let count: &mut u64 = df::borrow_mut(&mut score.id, ActiveSellerJobsKey {});
        *count = *count + 1;
        *count
    } else {
        df::add(&mut score.id, ActiveSellerJobsKey {}, 1u64);
        1
    };
    score.updated_at_ms = now;
    event::emit(ActiveSellerJobsChanged {
        score_id: score.id.to_inner(),
        agent: score.agent,
        job_id,
        active_seller_jobs: value,
        delta: ACTIVE_DELTA_CLAIM,
        timestamp_ms: now,
    });
}

/// −1, saturating at 0 — belt + suspenders: the `ClaimedJobKey` guard at
/// every call site already scopes decrements to jobs that incremented, so
/// the 0 branch is a silent no-op (no event) rather than an abort that
/// could wedge a settlement.
public(package) fun decrement_active(score: &mut AgentScore, job_id: ID, now: u64) {
    if (!df::exists(&score.id, ActiveSellerJobsKey {})) {
        return
    };
    let count: &mut u64 = df::borrow_mut(&mut score.id, ActiveSellerJobsKey {});
    if (*count == 0) {
        return
    };
    *count = *count - 1;
    let value = *count;
    score.updated_at_ms = now;
    event::emit(ActiveSellerJobsChanged {
        score_id: score.id.to_inner(),
        agent: score.agent,
        job_id,
        active_seller_jobs: value,
        delta: ACTIVE_DELTA_SETTLE,
        timestamp_ms: now,
    });
}

/// S.1255 — the ONE AdminCap write this module allows, and it touches
/// ONLY the active-seat mirror: set a seller's `active_seller_jobs` DF to
/// an absolute value, for the one-shot reconcile that heals counts
/// inflated by pre-v14 decline burns (decline used to keep the seat
/// occupied forever; those phantom seats have no job left to free them).
/// Deliberately NOT a general repair door: stars, distinct buyers,
/// outcome counters (`no_delivery` & co.) and per-wave batch holds stay
/// AdminCap-free — reputation remains receipts. Bounds: the value must
/// not exceed the live Level 4 active cap (the most seats any seller can
/// legitimately hold), so the door can never GRANT capacity beyond what
/// claims could have seated. Emits the same `ActiveSellerJobsChanged`
/// event the indexer already mirrors (post-write value; `delta` 2 =
/// admin set; `job_id` = the 0x0 sentinel — no job moved this).
public fun set_active_seller_jobs(
    _: &AdminCap,
    score: &mut AgentScore,
    value: u64,
    cfg: &FeeConfig,
    clock: &Clock,
) {
    escrow::assert_version_pkg(cfg);
    assert!(value <= escrow::config_tier_active_cap(cfg, 4), EActiveSetOutOfBounds);
    if (df::exists(&score.id, ActiveSellerJobsKey {})) {
        *df::borrow_mut(&mut score.id, ActiveSellerJobsKey {}) = value;
    } else {
        df::add(&mut score.id, ActiveSellerJobsKey {}, value);
    };
    let now = clock.timestamp_ms();
    score.updated_at_ms = now;
    event::emit(ActiveSellerJobsChanged {
        score_id: score.id.to_inner(),
        agent: score.agent,
        job_id: object::id_from_address(@0x0),
        active_seller_jobs: value,
        delta: ACTIVE_DELTA_ADMIN_SET,
        timestamp_ms: now,
    });
}

/// The receipt gate — every review path funnels through here. S.1064:
/// RELEASED **or REJECTED** (both are settled money paths on delivered
/// work — a buyer who rejected junk may still leave the honest 1★; the
/// S.1063 outcome counter already landed at reject and never doubles
/// here). Goodwill RELEASED with no delivery stays unreviewable, and a
/// REJECTED job structurally always has a delivery (reject requires
/// DELIVERED) — the delivered check stays as belt + suspenders.
fun validate_review<T>(job: &Job<T>, stars: u8, ctx: &TxContext): address {
    assert!(stars >= MIN_STARS && stars <= MAX_STARS, EBadStars);
    let buyer = escrow::buyer(job);
    let seller = escrow::seller(job);
    assert!(ctx.sender() == buyer, ENotBuyer);
    assert!(buyer != seller, ESelfReview);
    let state = escrow::state(job);
    assert!(
        state == escrow::state_released() || state == escrow::state_rejected(),
        ENotReleased, // abort code 1 unchanged — "not a reviewable state"
    );
    assert!(escrow::delivered_at_ms(job) > 0, ENotDelivered);
    seller
}

/// The ONLY aggregate mutator — private, so a star can never enter a score
/// except through a validated RELEASED receipt above.
fun apply_review(score: &mut AgentScore, job_id: ID, buyer: address, stars: u8, now: u64) {
    let previous_stars = if (score.job_stars.contains(job_id)) {
        let prev = score.job_stars.remove(job_id);
        score.stars_sum = score.stars_sum - (prev as u64);
        prev
    } else {
        score.review_count = score.review_count + 1;
        0
    };
    // S.1062: distinct-buyer tracking — first CONTRIBUTION for a job only
    // (star edits never move distinct), and each buyer counts once ever.
    if (previous_stars == 0 && !df::exists(&score.id, BuyerSeenKey { buyer })) {
        df::add(&mut score.id, BuyerSeenKey { buyer }, true);
        if (df::exists(&score.id, DistinctCountKey {})) {
            let count: &mut u64 = df::borrow_mut(&mut score.id, DistinctCountKey {});
            *count = *count + 1;
        } else {
            df::add(&mut score.id, DistinctCountKey {}, 1u64);
        }
    };
    score.job_stars.add(job_id, stars);
    score.stars_sum = score.stars_sum + (stars as u64);
    score.updated_at_ms = now;
    let score_id = score.id.to_inner();
    event::emit(ReviewSubmitted {
        score_id,
        agent: score.agent,
        job_id,
        buyer,
        stars,
        previous_stars,
        review_count: score.review_count,
        stars_sum: score.stars_sum,
        timestamp_ms: now,
    });
    event::emit(ReviewSubmittedV2 {
        score_id,
        agent: score.agent,
        job_id,
        buyer,
        stars,
        previous_stars,
        review_count: score.review_count,
        stars_sum: score.stars_sum,
        distinct_buyers: distinct_buyers(score),
        timestamp_ms: now,
    });
}

// === Proven predicates (read by `opening::claim_proven`) ===

/// `claim_policy = 1` — Proven (v2, S.1062): reviews from at least
/// `PROVEN_MIN_REVIEWS` DISTINCT buyers — one friendly buyer ×3 no longer
/// unlocks Proven. No score object ⇒ the claim entry can't even be
/// called — the correct "zero" outcome. NO GRANDFATHER: distinct starts
/// at 0 for pre-S.1062 scores and grows only from new review writes.
public fun meets_proven(score: &AgentScore): bool {
    distinct_buyers(score) >= PROVEN_MIN_REVIEWS
}

/// v1 name — kept because published public signatures are frozen; same
/// predicate as `meets_proven` since S.1062 (never the old review_count
/// floor: that would let old callers bypass distinct buyers).
public fun meets_min_reviews(score: &AgentScore): bool { meets_proven(score) }

/// `claim_policy = 2` — Proven · 4★+: Proven (distinct floor) AND average
/// ≥ 4.0 over `review_count`/`stars_sum` (star math unchanged). Strictly
/// stronger than plain Proven. Integer math — `sum × 10 ≥ count × 40` —
/// no division, no rounding. (Distinct ≥ 3 implies review_count ≥ 3.)
public fun meets_min_avg(score: &AgentScore): bool {
    meets_proven(score) &&
        score.stars_sum * AVG_SCALE >= score.review_count * PROVEN_MIN_AVG_STARS_X10
}

// === Seller levels (S.1192) — capacity labels, separate from claim policy ===

/// Computed Level 1..4 (SPEC_MARKETPLACE_REPUTATION_V2_TIERS, locked):
/// 1 default · 2 Proven (≥3 distinct buyers) · 3 4.0★+ average ·
/// 4 = Level 3 + ≥20 reviews + ≤2 no-delivery. Levels reuse the SAME
/// predicates the claim policies read — one SSOT for every threshold.
public fun seller_level(score: &AgentScore): u8 {
    if (meets_min_avg(score)) {
        if (
            score.review_count >= LEVEL4_MIN_REVIEWS &&
            no_delivery(score) <= LEVEL4_MAX_NO_DELIVERY
        ) { 4 } else { 3 }
    } else if (meets_proven(score)) {
        2
    } else {
        1
    }
}

/// The level capacity actually gates on: `no_delivery >= floor` (default
/// 3, AdminCap-tunable on `FeeConfig`) regresses to Level 1 regardless of
/// stars — reliability caps capacity without touching star math (display
/// ≠ gate). Takes `cfg` because the floor is a live FeeConfig DF, not a
/// package constant (spec sketch showed score-only; the tunable floor
/// requires the config).
public fun effective_seller_level(score: &AgentScore, cfg: &FeeConfig): u8 {
    if (no_delivery(score) >= escrow::config_no_delivery_regression_floor(cfg)) {
        1
    } else {
        seller_level(score)
    }
}

/// The live active-job cap for a level — thin wrapper over the FeeConfig
/// read so claim-side callers stay in one module's vocabulary.
public fun active_cap_for_level(cfg: &FeeConfig, level: u8): u64 {
    escrow::config_tier_active_cap(cfg, level)
}

/// Whether this seller clears an opening's `min_seller_level` floor —
/// on the EFFECTIVE level, so a regressed seller cannot pass a Level 2+
/// floor on stars alone (takes `cfg` for the tunable regression floor).
public fun meets_min_seller_level(score: &AgentScore, cfg: &FeeConfig, min_level: u8): bool {
    effective_seller_level(score, cfg) >= min_level
}

// === Read accessors (clients, indexer, composing modules) ===
public fun agent(score: &AgentScore): address { score.agent }
public fun review_count(score: &AgentScore): u64 { score.review_count }
public fun stars_sum(score: &AgentScore): u64 { score.stars_sum }

/// Distinct buyer addresses that have contributed a review since S.1062
/// (missing DF ⇒ 0 — pre-upgrade reviews never grandfather in).
public fun distinct_buyers(score: &AgentScore): u64 {
    if (df::exists(&score.id, DistinctCountKey {})) {
        *df::borrow(&score.id, DistinctCountKey {})
    } else {
        0
    }
}

/// Whether this buyer already counts toward the seller's distinct total.
public fun has_buyer_reviewed(score: &AgentScore, buyer: address): bool {
    df::exists(&score.id, BuyerSeenKey { buyer })
}

fun outcome_count<K: copy + drop + store>(score: &AgentScore, key: K): u64 {
    if (df::exists(&score.id, key)) { *df::borrow(&score.id, key) } else { 0 }
}

/// Times this agent (as seller) was rejected after delivering (S.1063).
public fun rejected_after_delivery(score: &AgentScore): u64 {
    outcome_count(score, RejectedAfterDeliveryKey {})
}

/// Times this agent (as seller) hit the deadline with no delivery.
public fun no_delivery(score: &AgentScore): u64 {
    outcome_count(score, NoDeliveryKey {})
}

/// Jobs this agent (as an Agent-ID buyer) rejected after delivery.
public fun as_buyer_rejected(score: &AgentScore): u64 {
    outcome_count(score, AsBuyerRejectedKey {})
}

/// This seller's live board-claimed job count (S.1192). Missing DF ⇒ 0 —
/// the soft start: pre-upgrade claims never counted in, and their settles
/// never count out (no `ClaimedJobKey` marker).
public fun active_seller_jobs(score: &AgentScore): u64 {
    if (df::exists(&score.id, ActiveSellerJobsKey {})) {
        *df::borrow(&score.id, ActiveSellerJobsKey {})
    } else {
        0
    }
}
public fun has_job_review(score: &AgentScore, job_id: ID): bool {
    score.job_stars.contains(job_id)
}
public fun job_stars(score: &AgentScore, job_id: ID): u8 {
    *score.job_stars.borrow(job_id)
}

/// Whether an agent has a score yet (board-side check, no score fetch).
public fun has_score(board: &ScoreBoard, agent: address): bool {
    derived_object::exists(&board.id, agent)
}

/// The deterministic address an agent's score lives (or will live) at.
public fun score_address(board: &ScoreBoard, agent: address): address {
    derived_object::derive_address(board.id.to_inner(), agent)
}

public fun proven_min_reviews(): u64 { PROVEN_MIN_REVIEWS }
public fun proven_min_avg_stars_x10(): u64 { PROVEN_MIN_AVG_STARS_X10 }
public fun level4_min_reviews(): u64 { LEVEL4_MIN_REVIEWS }
public fun level4_max_no_delivery(): u64 { LEVEL4_MAX_NO_DELIVERY }
public fun avg_scale(): u64 { AVG_SCALE }
public fun min_stars(): u8 { MIN_STARS }
public fun max_stars(): u8 { MAX_STARS }
