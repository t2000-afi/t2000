/// Batch openings — wave post (SPEC_MARKETPLACE_BATCH_OPENINGS, Phase D /
/// S.1193; active per-wave claims + batch-aware settle, S.1202). ONE post
/// = N homogeneous slots on the open board, backed by a SINGLE escrow
/// balance of `amount × slots_total`. Each claimed slot splits `amount`
/// out and mints a normal `escrow::Job` (ClaimedJobKey + BatchOriginKey
/// stamped by `create_claimed_from_batch`), and that Job settles through
/// THIS module's batch-aware doors so the per-wave hold frees with the
/// money.
///
///   create_batch_open ──batch_claim × N (sellers, FCFS)──▶ N normal Jobs
///   Job ──batch_release / batch_reject* / batch_refund──▶ money settles,
///     global seat −1, per-wave hold −1 (the bare v2 doors abort on
///     batch-origin Jobs — `EUseBatchSettle`)
///   create_batch_open ──cancel_batch_open (buyer)──▶ refund remainder, fee-free
///   create_batch_open ──refund_batch_expired (ANYONE, past open_until)──▶ same
///
/// Design notes (annex + Build risk control, locked):
/// - **VERSION cutover (S.1192-style, D23).** New entries + new DF keys,
///   no live signature changes — but the S.1202 upgrade ships with
///   `escrow::VERSION` 6→7 + an immediate `migrate`, because leaving old
///   bytecode callable would let v11 `create_batch_open` / `batch_claim` /
///   bare `release_v2` bypass active-claim semantics and origin settle.
///   Every entry gates on the live VERSION via
///   `escrow::assert_version_pkg` like every sibling.
/// - **Escrow invariant** — `escrow.value() == amount * slots_remaining`,
///   asserted after every mutation (claim / cancel / refund). The last
///   claim drains the balance to zero.
/// - **Filled batches are NOT deleted in v1.** `claims_by_agent` is a
///   `Table` that cannot be dropped while non-empty; a drained batch stays
///   shared with `slots_remaining == 0` and an empty balance (the
///   invariant holds at 0 × amount). The indexer derives `filled`.
/// - **Phase C gates reused verbatim at claim**: claimer's OWN
///   `&mut AgentScore` (ownership asserted), claim policy 0/1/2,
///   `min_seller_level` on the EFFECTIVE level, and the per-level active
///   cap — a batch slot occupies a seat exactly like a single claim.
/// - **Per-wave claims are ACTIVE holds, Level-scaled (S.1202, D11–D16).**
///   `claims_by_agent[agent]` counts this agent's IN-FLIGHT slots of THIS
///   wave — release / reject / refund free one (saturating −1, row removed
///   at 0); a finisher may claim the same wave again while slots remain.
///   The claim gate is `min(max_claims_per_agent, active_cap_for_level)`:
///   the buyer's `max_claims_per_agent` is a diversity CEILING (post 1 for
///   spread), and seller Level scales how much of a high ceiling one agent
///   may hold concurrently. Decline does NOT free the wave seat — and
///   since S.1255 (v14) that is deliberately STRICTER than the global
///   counter, which decline now frees: the burned wave hold is the one
///   remaining claim→decline anti-farm rail. Do NOT "restore parity" by
///   freeing wave holds on decline.
/// - **Legacy batches reject new claims (D21).** Pre-S.1202 waves carry
///   lifetime rows that would lock finishers out forever; `batch_claim`
///   aborts `ELegacyBatch` when `ActiveClaimsSemanticsKey` is missing.
///   Cancel / expired-refund on legacy batches stay allowed, and their
///   in-flight Jobs (no `BatchOriginKey`) keep settling via the v2 doors.
/// - **One claim per tx (v1 lock, founder 2026-08-25)** — no multi-claim
///   PTBs; a claimer below their wave cap claims again in a new tx.
/// - **Per-slot amount bounds only.** `amount` obeys the live min/max job
///   bounds; the TOTAL (`amount × slots`) is deliberately unbounded here —
///   the wallet balance and the desk's own budget bound it.
module a2a_escrow::batch;

use a2a_escrow::escrow::{Self, FeeConfig, Job};
use a2a_escrow::reputation::{Self, AgentScore};
use agent_id::registry::{Self, Registry};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::table::{Self, Table};

/// Claim policies mirror `opening` (0 Anyone · 1 Proven · 2 Proven·4★+).
const CLAIM_POLICY_ANY_ACTIVE: u8 = 0;
const CLAIM_POLICY_MIN_AVG: u8 = 2;
/// Board TTL cap — same 30 days as single openings.
const MAX_OPEN_WINDOW_MS: u64 = 2_592_000_000;

// === Errors ===
const EBadSlots: u64 = 0;
const EBadClaimPolicy: u64 = 1;
const EBadMinSellerLevel: u64 = 2;
const EBadMaxClaims: u64 = 3;
/// Payment must be an EXACT multiple of a non-zero per-slot amount.
const EBadPayment: u64 = 4;
const EOpenWindowInPast: u64 = 5;
const EOpenWindowTooFar: u64 = 6;
const ESlaOutOfRange: u64 = 7;
const EReviewWindowTooLong: u64 = 8;
/// Open-board rule (S.1019): reject pays the buyer in full — batches too.
const EOpenRejectMustBeFullBuyer: u64 = 9;
const EBatchExpired: u64 = 10;
const ENoSlotsRemaining: u64 = 11;
/// This agent already holds `max_claims_per_agent` slots of THIS batch.
const EMaxClaimsReached: u64 = 12;
const EClaimerIsBuyer: u64 = 13;
const ENotActiveAgent: u64 = 14;
/// The passed `AgentScore` is not the claimer's own.
const EScoreNotClaimer: u64 = 15;
const EClaimPolicyUnmet: u64 = 16;
const EMinSellerLevelUnmet: u64 = 17;
/// The claimer is at their Level's global active-job cap (Phase C).
const EActiveJobCap: u64 = 18;
const ENotBuyer: u64 = 19;
const ENotExpired: u64 = 20;
/// Defensive: the escrow invariant broke (should be unreachable).
const EEscrowInvariant: u64 = 21;
/// S.1202 (D21): this `BatchOpening` predates active-claim semantics
/// (no `ActiveClaimsSemanticsKey`) — its lifetime `claims_by_agent` rows
/// can never free, so NEW claims are refused. Cancel / expired-refund
/// still work; in-flight Jobs settle via the v2 doors.
const ELegacyBatch: u64 = 22;
/// S.1202: the Job passed to a batch settle door has no `BatchOriginKey` —
/// it was not minted from a batch; settle it via the v2 doors.
const ENotBatchJob: u64 = 23;
/// S.1202: the Job's `BatchOriginKey` names a DIFFERENT batch than the
/// one passed — the crank/client attached the wrong wave.
const EWrongBatch: u64 = 24;
/// S.1202: the passed seller `AgentScore` is not this Job's seller's.
const EWrongSellerScore: u64 = 25;
/// S.1202: the passed buyer `AgentScore` is not this Job's buyer's.
const EWrongBuyerScore: u64 = 26;
/// S.1202: registered Agent-ID buyer — use `batch_reject_agent_buyer`
/// (an agent buyer cannot dodge its own `as_buyer_rejected` counter).
const EBuyerIsAgent: u64 = 27;
/// S.1202: unregistered (Passport) buyer — use `batch_reject`.
const EBuyerNotAgent: u64 = 28;

// === Objects ===

/// One wave posting. Shared so any seller can race per slot; the whole
/// wave's escrow lives inside from the moment of posting. Unlike
/// `Opening`, existence is NOT the state — `slots_remaining` is (the
/// object persists after fill/cancel; see the module note).
public struct BatchOpening<phantom T> has key {
    id: UID,
    buyer: address,
    escrow: Balance<T>,
    /// Per-slot escrow (raw units) — immutable once posted.
    amount: u64,
    slots_total: u64,
    slots_remaining: u64,
    /// Protocol fee bps snapshotted at post — travels into every Job.
    fee_bps: u64,
    /// One spec envelope for every slot (homogeneous wave).
    spec_hash: vector<u8>,
    open_until_ms: u64,
    sla_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    claim_policy: u8,
    /// 0 = no floor · 1..4 = minimum EFFECTIVE seller level (Phase C).
    min_seller_level: u8,
    /// Slots one agent may claim of THIS batch (≥1; default posture 1).
    max_claims_per_agent: u8,
    claims_by_agent: Table<address, u8>,
    created_at_ms: u64,
}

/// S.1202 (D21) — semantics marker DF on `BatchOpening.id`, stamped by
/// `create_batch_open` from this package version on: `claims_by_agent`
/// rows on this wave are ACTIVE holds that free at settle. `batch_claim`
/// aborts `ELegacyBatch` when it is missing (pre-S.1202 waves have
/// lifetime rows that can never free). Defining id = the S.1202 upgrade
/// package (V12 pin).
public struct ActiveClaimsSemanticsKey has copy, drop, store {}

// === Events (defining id = the S.1193 upgrade package — V11 pin) ===

public struct BatchOpeningCreated has copy, drop {
    batch_id: ID,
    buyer: address,
    amount: u64,
    slots_total: u64,
    fee_bps: u64,
    spec_hash: vector<u8>,
    open_until_ms: u64,
    sla_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    claim_policy: u8,
    min_seller_level: u8,
    max_claims_per_agent: u8,
    timestamp_ms: u64,
}
/// One slot claimed → one normal Job. `slots_remaining` is the POST-claim
/// value — the indexer sets its column from THIS, never a SQL decrement.
public struct BatchSlotClaimed has copy, drop {
    batch_id: ID,
    job_id: ID,
    buyer: address,
    claimer: address,
    amount: u64,
    slots_remaining: u64,
    timestamp_ms: u64,
}
public struct BatchOpeningCancelled has copy, drop {
    batch_id: ID,
    buyer: address,
    refunded: u64,
    slots_cancelled: u64,
    timestamp_ms: u64,
}
public struct BatchOpeningRefunded has copy, drop {
    batch_id: ID,
    buyer: address,
    refunded: u64,
    slots_refunded: u64,
    timestamp_ms: u64,
}
/// S.1202 — a settle freed one per-wave hold (sibling event; the frozen
/// `BatchSlotClaimed` never grows). `claims_remaining_for_agent` is the
/// POST-write value — the read model mirrors it, never decrements.
/// Defining id = the S.1202 upgrade package (V12 pin).
public struct BatchSlotHoldReleased has copy, drop {
    batch_id: ID,
    job_id: ID,
    agent: address,
    claims_remaining_for_agent: u8,
    timestamp_ms: u64,
}

// === Create (buyer locks amount × slots in ONE tx) ===

/// Post a wave: `payment` must be an exact multiple of `slots_total`; the
/// per-slot `amount` derives from the division and must satisfy the SAME
/// live min/max job bounds as a single post. Returns the batch id.
public fun create_batch_open<T>(
    payment: Coin<T>,
    slots_total: u64,
    spec_hash: vector<u8>,
    open_until_ms: u64,
    sla_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    claim_policy: u8,
    min_seller_level: u8,
    max_claims_per_agent: u8,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    escrow::assert_version_pkg(cfg);
    // S.1210 hardening: the product's one gate is `min_seller_level`
    // (trustRequirement, S.1209) — new waves must post claim_policy 0;
    // legacy Proven policies survive read-only on pre-v13 objects.
    assert!(claim_policy == CLAIM_POLICY_ANY_ACTIVE, EBadClaimPolicy);
    do_create_batch_open(
        payment,
        slots_total,
        spec_hash,
        open_until_ms,
        sla_ms,
        review_window_ms,
        reject_split_bps,
        claim_policy,
        min_seller_level,
        max_claims_per_agent,
        cfg,
        clock,
        ctx,
    )
}

#[test_only]
/// Test-only mirror of a PRE-v13 gated wave (`claim_policy` 1/2) —
/// keeps the legacy-policy claim gates tested even though v13 creates
/// assert `claim_policy == 0`.
public fun create_batch_open_legacy_for_testing<T>(
    payment: Coin<T>,
    slots_total: u64,
    spec_hash: vector<u8>,
    open_until_ms: u64,
    sla_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    claim_policy: u8,
    min_seller_level: u8,
    max_claims_per_agent: u8,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    escrow::assert_version_pkg(cfg);
    assert!(claim_policy <= CLAIM_POLICY_MIN_AVG, EBadClaimPolicy);
    do_create_batch_open(
        payment,
        slots_total,
        spec_hash,
        open_until_ms,
        sla_ms,
        review_window_ms,
        reject_split_bps,
        claim_policy,
        min_seller_level,
        max_claims_per_agent,
        cfg,
        clock,
        ctx,
    )
}

/// The shared create body — version + policy already asserted above.
fun do_create_batch_open<T>(
    payment: Coin<T>,
    slots_total: u64,
    spec_hash: vector<u8>,
    open_until_ms: u64,
    sla_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    claim_policy: u8,
    min_seller_level: u8,
    max_claims_per_agent: u8,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(
        slots_total >= 1 && slots_total <= escrow::config_max_batch_slots(cfg),
        EBadSlots,
    );
    assert!(min_seller_level <= 4, EBadMinSellerLevel);
    assert!(max_claims_per_agent >= 1, EBadMaxClaims);
    let total = payment.value();
    let amount = total / slots_total;
    assert!(amount > 0 && amount * slots_total == total, EBadPayment);
    // Per-slot bounds only — the wave total is bounded by the wallet.
    escrow::assert_amount_in_bounds_pkg(cfg, amount);
    let now = clock.timestamp_ms();
    assert!(open_until_ms > now, EOpenWindowInPast);
    assert!(open_until_ms <= now + MAX_OPEN_WINDOW_MS, EOpenWindowTooFar);
    assert!(
        sla_ms > 0 && sla_ms <= escrow::max_deliver_horizon_ms_pkg(),
        ESlaOutOfRange,
    );
    assert!(
        review_window_ms <= escrow::max_review_window_ms_pkg(),
        EReviewWindowTooLong,
    );
    assert!(
        reject_split_bps == escrow::bps_denominator_pkg(),
        EOpenRejectMustBeFullBuyer,
    );
    let mut batch = BatchOpening<T> {
        id: object::new(ctx),
        buyer: ctx.sender(),
        escrow: payment.into_balance(),
        amount,
        slots_total,
        slots_remaining: slots_total,
        fee_bps: escrow::config_fee_bps(cfg),
        spec_hash,
        open_until_ms,
        sla_ms,
        review_window_ms,
        reject_split_bps,
        claim_policy,
        min_seller_level,
        max_claims_per_agent,
        claims_by_agent: table::new(ctx),
        created_at_ms: now,
    };
    // S.1202 (D21): brand active-claim semantics before share — claims on
    // un-branded (pre-upgrade) waves abort `ELegacyBatch`.
    df::add(&mut batch.id, ActiveClaimsSemanticsKey {}, true);
    let batch_id = batch.id.to_inner();
    event::emit(BatchOpeningCreated {
        batch_id,
        buyer: batch.buyer,
        amount,
        slots_total,
        fee_bps: batch.fee_bps,
        spec_hash: batch.spec_hash,
        open_until_ms,
        sla_ms,
        review_window_ms,
        reject_split_bps,
        claim_policy,
        min_seller_level,
        max_claims_per_agent,
        timestamp_ms: now,
    });
    transfer::share_object(batch);
    batch_id
}

// === Claim (one slot per tx — v1 lock) ===

/// Claim ONE slot: every Phase C single-claim gate, plus the wave's own
/// slot + per-agent limits. Mints a normal funded Job (ClaimedJobKey +
/// BatchOriginKey stamped inside `create_claimed_from_batch`) and seats
/// the claimer's global active counter. FCFS per slot — losers of a
/// same-slot race abort on the shared-object version, exactly like
/// single openings.
///
/// S.1202 wave gate: `claims_by_agent[claimer]` counts ACTIVE holds of
/// this wave, and the limit is `min(max_claims_per_agent,
/// active_cap_for_level)` — asserted BEFORE the global `EActiveJobCap`
/// (locked abort priority; MCP maps both).
public fun batch_claim<T>(
    batch: &mut BatchOpening<T>,
    registry: &Registry,
    score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    escrow::assert_version_pkg(cfg);
    // S.1202 (D21): lifetime-semantics waves never accept new claims.
    assert!(has_active_claims_semantics(batch), ELegacyBatch);
    let now = clock.timestamp_ms();
    let claimer = ctx.sender();
    // Locked check order (annex §batch_claim + S.1202 claim gate).
    assert!(now <= batch.open_until_ms, EBatchExpired);
    assert!(batch.slots_remaining > 0, ENoSlotsRemaining);
    assert!(claimer != batch.buyer, EClaimerIsBuyer);
    assert!(registry::is_registered(registry, claimer), ENotActiveAgent);
    let record = registry::borrow_record(registry, claimer);
    assert!(registry::is_active(record), ENotActiveAgent);
    // Phase C gates, same order as opening::do_claim — except the wave cap
    // needs the claimer's EFFECTIVE level, so the level computes first.
    assert!(reputation::agent(score) == claimer, EScoreNotClaimer);
    let level = reputation::effective_seller_level(score, cfg);
    let cap = reputation::active_cap_for_level(cfg, level);
    // S.1202 (D15): active holds of THIS wave < min(buyer ceiling, level cap).
    let already = claims_of(batch, claimer) as u64;
    let wave_cap = (batch.max_claims_per_agent as u64).min(cap);
    assert!(already < wave_cap, EMaxClaimsReached);
    let policy = batch.claim_policy;
    if (policy != CLAIM_POLICY_ANY_ACTIVE) {
        if (policy == CLAIM_POLICY_MIN_AVG) {
            assert!(reputation::meets_min_avg(score), EClaimPolicyUnmet);
        } else {
            assert!(reputation::meets_proven(score), EClaimPolicyUnmet);
        };
    };
    assert!(reputation::active_seller_jobs(score) < cap, EActiveJobCap);
    if (batch.min_seller_level > 0) {
        assert!(
            reputation::meets_min_seller_level(score, cfg, batch.min_seller_level),
            EMinSellerLevelUnmet,
        );
    };
    // Split ONE slot's escrow → normal Job (ClaimedJobKey + the S.1202
    // BatchOriginKey inside — settles via THIS module's doors).
    let batch_id = batch.id.to_inner();
    let slot_escrow = batch.escrow.split(batch.amount);
    let job_id = escrow::create_claimed_from_batch(
        batch_id,
        batch.buyer,
        claimer,
        slot_escrow,
        batch.fee_bps,
        batch.spec_hash,
        now + batch.sla_ms,
        batch.review_window_ms,
        batch.reject_split_bps,
        cfg,
        clock,
        ctx,
    );
    if (table::contains(&batch.claims_by_agent, claimer)) {
        let count = table::borrow_mut(&mut batch.claims_by_agent, claimer);
        *count = *count + 1;
    } else {
        table::add(&mut batch.claims_by_agent, claimer, 1);
    };
    batch.slots_remaining = batch.slots_remaining - 1;
    assert_invariant(batch);
    reputation::increment_active(score, job_id, now);
    event::emit(BatchSlotClaimed {
        batch_id: batch.id.to_inner(),
        job_id,
        buyer: batch.buyer,
        claimer,
        amount: batch.amount,
        slots_remaining: batch.slots_remaining,
        timestamp_ms: now,
    });
    job_id
}

// === Batch-aware settle (S.1202) — the ONLY terminal doors for Jobs ===
// === carrying `BatchOriginKey` (the v2 doors abort `EUseBatchSettle`) ===
// Each door is the v2 door's exact mirror — money settles in escrow's
// `*_settle_pkg` (auth + coin/fee math + frozen events, single source),
// outcome counters land via reputation's package hooks, the global seat
// frees via `decrement_active` — PLUS the per-wave hold frees in the SAME
// tx (D12). Permissionless-crank properties survive unchanged: the batch
// and score inputs are verified against the Job, never the caller.

/// Release a batch-origin Job — funds → seller minus the protocol fee.
/// Same three legitimate callers as `release_v2` (buyer accept, buyer
/// goodwill on FUNDED, anyone after the review window lapses); the wave
/// hold frees either way — a goodwill release is still this slot leaving
/// flight (SPEC §batch-aware settle table).
public fun batch_release<T>(
    batch: &mut BatchOpening<T>,
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    assert_batch_origin(batch, job);
    assert!(reputation::agent(seller_score) == escrow::seller(job), EWrongSellerScore);
    escrow::release_settle_pkg(job, cfg, clock, ctx);
    let now = clock.timestamp_ms();
    // S.1210: skip when deliver already freed the seat (marker present).
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        reputation::decrement_active(seller_score, object::id(job), now);
    };
    // S.1210: on v13 the wave hold freed at deliver — free here only
    // for goodwill-FUNDED releases, refunds, and pre-v13 stragglers.
    if (!escrow::is_batch_hold_released(job)) {
        free_wave_hold(batch, job, now);
    };
}

/// Buyer rejects delivered batch work — PASSPORT (unregistered) buyer
/// variant: split settles (open-board lock: 100% buyer), the seller's
/// `rejected_after_delivery` counter lands, seat + wave hold free.
public fun batch_reject<T>(
    batch: &mut BatchOpening<T>,
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    registry: &Registry,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    assert_batch_origin(batch, job);
    assert!(!registry::is_registered(registry, escrow::buyer(job)), EBuyerIsAgent);
    assert!(reputation::agent(seller_score) == escrow::seller(job), EWrongSellerScore);
    escrow::reject_settle_pkg(job, cfg, clock, ctx); // auth: sender==buyer, DELIVERED, in-window
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    reputation::record_rejected_after_delivery_pkg(seller_score, job_id, now);
    // S.1210: skip when deliver already freed the seat (marker present).
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        reputation::decrement_active(seller_score, job_id, now);
    };
    // S.1210: on v13 the wave hold freed at deliver — free here only
    // for goodwill-FUNDED releases, refunds, and pre-v13 stragglers.
    if (!escrow::is_batch_hold_released(job)) {
        free_wave_hold(batch, job, now);
    };
}

/// Buyer rejects delivered batch work — AGENT-ID buyer variant: same as
/// `batch_reject` plus `as_buyer_rejected` on the buyer's OWN score
/// (transparency cuts both ways — the v2 routing locks apply verbatim).
public fun batch_reject_agent_buyer<T>(
    batch: &mut BatchOpening<T>,
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    buyer_score: &mut AgentScore,
    registry: &Registry,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    assert_batch_origin(batch, job);
    let buyer = escrow::buyer(job);
    assert!(registry::is_registered(registry, buyer), EBuyerNotAgent);
    assert!(reputation::agent(seller_score) == escrow::seller(job), EWrongSellerScore);
    assert!(reputation::agent(buyer_score) == buyer, EWrongBuyerScore);
    escrow::reject_settle_pkg(job, cfg, clock, ctx);
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    reputation::record_rejected_after_delivery_pkg(seller_score, job_id, now);
    reputation::record_as_buyer_rejected_pkg(buyer_score, job_id, now);
    // S.1210: skip when deliver already freed the seat (marker present).
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        reputation::decrement_active(seller_score, job_id, now);
    };
    // S.1210: on v13 the wave hold freed at deliver — free here only
    // for goodwill-FUNDED releases, refunds, and pre-v13 stragglers.
    if (!escrow::is_batch_hold_released(job)) {
        free_wave_hold(batch, job, now);
    };
}

/// Deadline refund (no delivery) of a batch-origin Job — permissionless
/// crank; `no_delivery` lands on the seller, seat + wave hold free (the
/// no_delivery counter is what costs the seller — via level regression).
public fun batch_refund<T>(
    batch: &mut BatchOpening<T>,
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    assert_batch_origin(batch, job);
    assert!(reputation::agent(seller_score) == escrow::seller(job), EWrongSellerScore);
    escrow::refund_settle_pkg(job, cfg, clock, ctx); // auth: FUNDED, past deadline
    let now = clock.timestamp_ms();
    let job_id = object::id(job);
    reputation::record_no_delivery_pkg(seller_score, job_id, now);
    // S.1210: skip when deliver already freed the seat (marker present).
    if (escrow::is_claimed_job(job) && !escrow::is_active_freed(job)) {
        reputation::decrement_active(seller_score, job_id, now);
    };
    // S.1210: on v13 the wave hold freed at deliver — free here only
    // for goodwill-FUNDED releases, refunds, and pre-v13 stragglers.
    if (!escrow::is_batch_hold_released(job)) {
        free_wave_hold(batch, job, now);
    };
}

/// Deliver a batch-origin Job (S.1210 / v13) — the live deliver door for
/// wave slots: posts the delivery via `escrow::deliver` (auth unchanged:
/// sender == seller, FUNDED, before deadline), frees the seller's GLOBAL
/// active seat (`reputation::on_job_delivered`) AND this wave's per-agent
/// hold in the same tx — a `maxClaimsPerAgent: 1` wave becomes
/// re-claimable the moment the work ships, not when the buyer settles.
#[allow(lint(prefer_mut_tx_context))]
public fun deliver_v2<T>(
    batch: &mut BatchOpening<T>,
    job: &mut Job<T>,
    seller_score: &mut AgentScore,
    delivery_hash: vector<u8>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_batch_origin(batch, job);
    assert!(reputation::agent(seller_score) == escrow::seller(job), EWrongSellerScore);
    escrow::deliver(job, delivery_hash, cfg, clock, ctx);
    let now = clock.timestamp_ms();
    reputation::on_job_delivered(seller_score, job, now);
    free_wave_hold(batch, job, now);
}

/// The Job must carry `BatchOriginKey` AND it must name THIS batch —
/// a crank passing the wrong wave aborts instead of mutating a stranger's
/// `claims_by_agent` table.
fun assert_batch_origin<T>(batch: &BatchOpening<T>, job: &Job<T>) {
    let mut origin = escrow::batch_origin(job);
    assert!(origin.is_some(), ENotBatchJob);
    assert!(origin.extract() == batch.id.to_inner(), EWrongBatch);
}

/// Free ONE per-wave hold for this Job's seller: saturating −1 on
/// `claims_by_agent` (row removed at 0 — the Table stays droppable in
/// spirit), one-shot `BatchHoldReleasedKey` on the Job (a second free
/// aborts in escrow — belt + suspenders over the settle state machine),
/// and the sibling event. Called at DELIVER since S.1210 (settle doors
/// only catch goodwill-FUNDED / refund / pre-v13 stragglers). NOT called
/// on decline (D13: decline burns the wave seat — since S.1255
/// deliberately STRICTER than the global counter, which decline frees;
/// the wave burn is the remaining claim→decline anti-farm rail).
fun free_wave_hold<T>(batch: &mut BatchOpening<T>, job: &mut Job<T>, now: u64) {
    escrow::mark_batch_hold_released_pkg(job);
    let agent = escrow::seller(job);
    let remaining = if (table::contains(&batch.claims_by_agent, agent)) {
        let current = table::remove(&mut batch.claims_by_agent, agent);
        if (current > 1) {
            table::add(&mut batch.claims_by_agent, agent, current - 1);
            current - 1
        } else {
            0
        }
    } else {
        // Saturating: unreachable through the doors above (every origin
        // Job added a row at claim), kept as a no-abort floor so a
        // settlement can never wedge on counter drift.
        0
    };
    event::emit(BatchSlotHoldReleased {
        batch_id: batch.id.to_inner(),
        job_id: object::id(job),
        agent,
        claims_remaining_for_agent: remaining,
        timestamp_ms: now,
    });
}

// === Cancel (buyer withdraws the unclaimed remainder — fee-free) ===

/// Buyer-only, any time while slots remain. Claimed slots are already
/// normal Jobs and are untouched; the batch object persists at 0 slots.
public fun cancel_batch_open<T>(
    batch: &mut BatchOpening<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    assert!(ctx.sender() == batch.buyer, ENotBuyer);
    let (refunded, slots) = drain_remainder(batch, ctx);
    event::emit(BatchOpeningCancelled {
        batch_id: batch.id.to_inner(),
        buyer: batch.buyer,
        refunded,
        slots_cancelled: slots,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Refund (ANYONE, after open_until — fee-free crank) ===

/// Permissionless: the remainder can only ever go back to the buyer.
public fun refund_batch_expired<T>(
    batch: &mut BatchOpening<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    escrow::assert_version_pkg(cfg);
    let now = clock.timestamp_ms();
    assert!(now > batch.open_until_ms, ENotExpired);
    let (refunded, slots) = drain_remainder(batch, ctx);
    event::emit(BatchOpeningRefunded {
        batch_id: batch.id.to_inner(),
        buyer: batch.buyer,
        refunded,
        slots_refunded: slots,
        timestamp_ms: now,
    });
}

/// Return the whole unclaimed remainder to the buyer and zero the slots.
/// Aborts when nothing remains (already filled / cancelled / refunded) so
/// replays and double-cancels fail loudly instead of minting empty events.
fun drain_remainder<T>(batch: &mut BatchOpening<T>, ctx: &mut TxContext): (u64, u64) {
    let slots = batch.slots_remaining;
    assert!(slots > 0, ENoSlotsRemaining);
    batch.slots_remaining = 0;
    let refunded = batch.escrow.value();
    let payout = coin::from_balance(batch.escrow.withdraw_all(), ctx);
    transfer::public_transfer(payout, batch.buyer);
    assert_invariant(batch);
    (refunded, slots)
}

/// `escrow.value() == amount * slots_remaining` — after every mutation.
fun assert_invariant<T>(batch: &BatchOpening<T>) {
    assert!(
        batch.escrow.value() == batch.amount * batch.slots_remaining,
        EEscrowInvariant,
    );
}

fun claims_of<T>(batch: &BatchOpening<T>, agent: address): u8 {
    if (table::contains(&batch.claims_by_agent, agent)) {
        *table::borrow(&batch.claims_by_agent, agent)
    } else {
        0
    }
}

// === Read accessors (clients, indexer, prepare preflight) ===
public fun buyer<T>(batch: &BatchOpening<T>): address { batch.buyer }
public fun amount<T>(batch: &BatchOpening<T>): u64 { batch.amount }
public fun slots_total<T>(batch: &BatchOpening<T>): u64 { batch.slots_total }
public fun slots_remaining<T>(batch: &BatchOpening<T>): u64 {
    batch.slots_remaining
}
public fun fee_bps<T>(batch: &BatchOpening<T>): u64 { batch.fee_bps }
public fun spec_hash<T>(batch: &BatchOpening<T>): vector<u8> { batch.spec_hash }
public fun open_until_ms<T>(batch: &BatchOpening<T>): u64 { batch.open_until_ms }
public fun sla_ms<T>(batch: &BatchOpening<T>): u64 { batch.sla_ms }
public fun review_window_ms<T>(batch: &BatchOpening<T>): u64 {
    batch.review_window_ms
}
public fun reject_split_bps<T>(batch: &BatchOpening<T>): u64 {
    batch.reject_split_bps
}
public fun claim_policy<T>(batch: &BatchOpening<T>): u8 { batch.claim_policy }
public fun min_seller_level<T>(batch: &BatchOpening<T>): u8 {
    batch.min_seller_level
}
public fun max_claims_per_agent<T>(batch: &BatchOpening<T>): u8 {
    batch.max_claims_per_agent
}
/// ACTIVE holds `agent` currently has of this batch (S.1202) — 0 when
/// never claimed or when every claimed slot has settled. On a legacy
/// (pre-S.1202) wave the rows are lifetime counts that never free.
public fun claims_by_agent<T>(batch: &BatchOpening<T>, agent: address): u8 {
    claims_of(batch, agent)
}
/// Whether this wave runs active-claim semantics (S.1202) — false only
/// for pre-upgrade batches, which no longer accept new claims (D21).
public fun has_active_claims_semantics<T>(batch: &BatchOpening<T>): bool {
    df::exists(&batch.id, ActiveClaimsSemanticsKey {})
}
public fun created_at_ms<T>(batch: &BatchOpening<T>): u64 { batch.created_at_ms }
public fun escrow_value<T>(batch: &BatchOpening<T>): u64 { batch.escrow.value() }

// === Test hooks ===

/// Simulate a PRE-S.1202 wave: strip the semantics marker so legacy-batch
/// behavior (`ELegacyBatch` on claim, cancel/refund still allowed) is
/// testable without deploying old bytecode.
#[test_only]
public fun strip_active_claims_semantics_for_testing<T>(batch: &mut BatchOpening<T>) {
    let _: bool = df::remove(&mut batch.id, ActiveClaimsSemanticsKey {});
}
