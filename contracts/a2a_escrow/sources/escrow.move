/// A2A Escrow — non-custodial job escrow for agent-to-agent deliverable
/// work (SPEC_A2A_ESCROW + SPEC_ACP_SUI Phase 1).
///
/// One shared `Job<T>` per engagement. The funds live IN the object
/// (`Balance<T>`) — no treasury, no pool. Every transition is a pure function
/// of (state, clock, caller):
///
///   FUNDED ──deliver (seller, before deadline)──▶ DELIVERED
///   FUNDED ──release (buyer: goodwill/late-accept)──▶ RELEASED
///   FUNDED ──refund (ANYONE, after deadline)──▶ REFUNDED      → buyer
///   DELIVERED ──release (buyer accept)──▶ RELEASED            → seller
///   DELIVERED ──release (ANYONE, review window lapsed)──▶ RELEASED
///   DELIVERED ──reject (buyer, within review window)──▶ REJECTED
///                → split per `reject_split_bps` agreed at create
///
/// The two timeout paths are permissionless cranks: a ghosting buyer can't
/// strand a delivering seller (timeout-release), and a broken seller can never
/// keep committed funds (deadline-refund). t2000 operates NO part of this —
/// the gateway only reads the object + events for display.
///
/// Design notes (contract review + D-1, 2026-07-18):
/// - **Protocol fee (D-1):** `fee_bps` (2.5% at launch) snapshotted onto the
///   Job at create from the shared `FeeConfig` — terms can never move under a
///   funded job. Charged ONLY on seller-bound funds at settlement (release
///   payout AND the seller's share of a reject split — so a 0-split reject
///   can't dodge it). Refunds to the buyer are always fee-free. The receiver
///   is read from `FeeConfig` at settle time; only the `AdminCap` holder can
///   rotate it or change the bps (hard-capped at `MAX_FEE_BPS`).
/// - **Versioning:** shared `FeeConfig` carries a `version` + every entry
///   gates on it — the standard Sui upgrade pattern, so a future in-place
///   upgrade can invalidate stale package flows via `migrate`.
/// - **Bounded windows:** `review_window_ms` and the deliver horizon are
///   capped at create. Unbounded values would let a hostile buyer set
///   `review_window_ms` near u64::MAX and make `delivered_at_ms +
///   review_window_ms` overflow-abort — permanently locking a DELIVERED
///   job's funds (release and reject both hit that addition).
/// - **u128 bps math:** split/fee arithmetic widens to u128 before the
///   multiply, removing the theoretical `amount * bps` u64 overflow.
///
/// The x402 tie-in: a job-class 402 advertises `intent: "escrow"`; the
/// X-PAYMENT credential carries the Job object id, which the seller verifies
/// on-chain (funded, my address, right amount) before starting work —
/// chain-verified, so it works for every signer including zkLogin.
///
/// Generic over the coin type `T` (USDC in practice — the client caps job
/// value; the contract stays value-neutral).
module a2a_escrow::escrow;

use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;

/// Package flow version — bump on upgrades that must invalidate old flows.
/// v9 (S.1255, v14 package): decline frees the GLOBAL active seat —
/// claimed jobs decline through `reputation::decline_v2` (seller score
/// attached; same idempotent `ActiveFreedKey` pattern as deliver; still
/// no `no_delivery` — decline stays a clean walk for outcomes), and the
/// bare `escrow::decline` is a dead `EUseSettleV2` stub. The per-wave
/// batch hold still BURNS on decline (D13 — wave is now deliberately
/// STRICTER than the global counter). Adds the narrow AdminCap
/// `reputation::set_active_seller_jobs` reconcile door for healing the
/// pre-v14 decline over-counts. The cutover kills v13 bytecode whose
/// `escrow::decline` would keep burning global seats.
/// v8 (S.1210, v13 package): active cap frees on DELIVER — claimed jobs
/// deliver through `reputation::deliver_v2` / `batch::deliver_v2` (seller
/// score attached; wave hold frees too), settle paths skip the decrement
/// when the deliver already freed it, Level 4 review floor 20 → 10, and
/// `create_open_v2` / `create_batch_open` assert `claim_policy == 0`
/// (S.1209 made trustRequirement the one product gate; this closes the
/// direct-chain hole). The cutover kills v12 bytecode whose bare
/// `escrow::deliver` would leave seats occupied until settle.
/// v7 (S.1202, D23): batch active per-wave claims + batch-aware settle —
/// the cutover kills the v11 bytecode whose `create_batch_open` /
/// `batch_claim` / bare `release_v2` would still post un-branded waves,
/// claim with lifetime semantics, and settle batch Jobs without freeing
/// the wave hold. After migrate, batch Jobs settle ONLY through the
/// `batch::batch_release`/`batch_reject*`/`batch_refund` doors and every
/// pre-upgrade (non-origin) Job settles on THIS package's v2 doors.
/// v6 (S.1192): seller levels + active caps — claims and release settle
/// through `opening::claim_v2`/`claim_proven_v2` and
/// `reputation::release_v2` (all take the seller's `&mut AgentScore` so
/// the in-flight counter moves with the money); the frozen-signature
/// `claim`/`claim_proven`/`create_open`/`release` entries are deprecated
/// aborts, and the version cutover kills the v9 bytecode that would still
/// claim/release without the capacity gates. v5 (S.1063): reject/refund
/// settle THROUGH `reputation::reject_v2` / `refund_v2` so protocol
/// outcomes hit the seller's (and an Agent-ID buyer's) score. v4
/// (S.1062): Proven = distinct buyers. v3 (S.1019): open reject 100%
/// buyer. v2 (S.981): amount bounds.
const VERSION: u64 = 9;

// === States ===
const STATE_FUNDED: u8 = 0;
const STATE_DELIVERED: u8 = 1;
const STATE_RELEASED: u8 = 2;
const STATE_REFUNDED: u8 = 3;
const STATE_REJECTED: u8 = 4;

const BPS_DENOMINATOR: u64 = 10_000;
/// Protocol fee at launch (D-1, SPEC_ACP_SUI §7): 2.5%.
const FEE_BPS_DEFAULT: u64 = 250;
/// Hard ceiling on what the admin can ever set — 10%.
const MAX_FEE_BPS: u64 = 1_000;
/// Review window cap: 30 days. Bounds the overflow surface AND the worst-case
/// seller wait on a ghosting buyer.
const MAX_REVIEW_WINDOW_MS: u64 = 2_592_000_000;
/// Deliver deadline horizon cap: 365 days out from create.
const MAX_DELIVER_HORIZON_MS: u64 = 31_536_000_000;

// === Job amount bounds (S.981) — raw coin units, NOT display USDC ===
// The contract is coin-generic; these are raw `Coin::value()` units. The
// product runs USDC (6 decimals), so 50_000 = $0.05. Live values are
// AdminCap-tunable via dynamic fields on `FeeConfig.id` (a compatible
// upgrade CANNOT add struct fields — DF is the only storage that works on
// the live shared object); readers fall back to these package defaults
// when the DF is absent.
/// Launch minimum: 0.05 USDC.
const MIN_JOB_AMOUNT_DEFAULT: u64 = 50_000;
/// Launch maximum: 50 USDC (the former SDK-only `MAX_JOB_USDC`, now real).
const MAX_JOB_AMOUNT_DEFAULT: u64 = 50_000_000;
/// Hard rail: the admin can never set the min below 0.01 USDC.
const MIN_JOB_AMOUNT_FLOOR: u64 = 10_000;
/// Hard rail: the admin can never set the max above 100 USDC.
const MAX_JOB_AMOUNT_CEILING: u64 = 100_000_000;

// === Seller-level active caps (S.1192) — defaults when the DF is unset ===
// How many in-flight CLAIMED jobs (funded + delivered) a seller may hold,
// by `reputation::seller_level` 1..4. AdminCap-tunable per level via
// `TierActiveCapKey` DFs on `FeeConfig.id` — same house as the amount
// bounds above. Hire jobs never count (the buyer picked that seller
// deliberately; the cap exists to stop FCFS claim-hoarding).
const TIER1_ACTIVE_CAP_DEFAULT: u64 = 4;
const TIER2_ACTIVE_CAP_DEFAULT: u64 = 10;
const TIER3_ACTIVE_CAP_DEFAULT: u64 = 20;
const TIER4_ACTIVE_CAP_DEFAULT: u64 = 30;
/// `no_delivery >= floor` regresses a seller's EFFECTIVE level to 1
/// (`reputation::effective_seller_level`). AdminCap-tunable via
/// `NoDeliveryRegressionFloorKey`.
const NO_DELIVERY_REGRESSION_FLOOR_DEFAULT: u64 = 3;

// === Batch openings (S.1193) — slots-per-post bounds ===
/// Default max slots one `batch::create_batch_open` may post. Live value
/// is AdminCap-tunable via `MaxBatchSlotsKey` (founder posts 100–200
/// waves today, may want more tomorrow — never a frozen const alone).
const MAX_BATCH_SLOTS_DEFAULT: u64 = 250;
/// Hard ceiling the admin can never exceed (raising it needs an upgrade).
const MAX_BATCH_SLOTS_CEILING: u64 = 512;

// === Errors ===
const ENotAuthorized: u64 = 0;
const EWrongState: u64 = 1;
const EZeroAmount: u64 = 2;
const EDeadlineInPast: u64 = 3;
const EBadSplit: u64 = 4;
const EPastDeadline: u64 = 5;
const EReviewWindowOpen: u64 = 6;
const EReviewWindowClosed: u64 = 7;
const EDeadlineNotReached: u64 = 8;
const EBuyerIsSeller: u64 = 9;
const EReviewWindowTooLong: u64 = 10;
const EDeadlineTooFar: u64 = 11;
const EFeeTooHigh: u64 = 12;
const EWrongVersion: u64 = 13;
const ENotUpgrade: u64 = 14;
const EAmountTooSmall: u64 = 15;
const EAmountTooLarge: u64 = 16;
const EBadAmountBounds: u64 = 17;
/// S.1054b: the canonical ScoreBoard already exists — one per chain, ever.
const EScoreBoardExists: u64 = 18;
/// S.1063: reject/refund moved to `reputation::reject_v2`/`refund_v2`
/// (outcome counters ride settlement). These frozen-signature entries
/// abort with THIS code — a dedicated abort so ops can tell "deprecated
/// surface" from a real auth failure (the S.1032 registry pattern).
const EUseSettleV2: u64 = 19;
/// S.1192: `release` moved to `reputation::release_v2` (the active-job
/// counter rides settlement). Dedicated code, same S.1032/S.1063 pattern.
const EUseReleaseV2: u64 = 20;
/// S.1192: tier args out of range — level must be 1..4, a cap must be > 0
/// (cap 0 would freeze a level entirely), the regression floor > 0 (floor
/// 0 would regress everyone forever).
const EBadTierBounds: u64 = 21;
/// S.1193: batch-slot args out of range — the live max must be 1..ceiling.
const EBadBatchSlots: u64 = 22;
/// S.1202: this batch Job's wave hold was already freed — the one-shot
/// `BatchHoldReleasedKey` is belt + suspenders over the state machine
/// (a second settle already aborts `EWrongState` inside the settle body).
const EBatchHoldReleased: u64 = 23;
/// S.1210: second active-freed stamp on one Job (unreachable via the
/// guarded deliver hook).
const EActiveAlreadyFreed: u64 = 24;

// === Objects ===

/// Capability to administer `FeeConfig` (rotate receiver, adjust bps within
/// `MAX_FEE_BPS`, run version migrations). Held by the deployer wallet.
public struct AdminCap has key, store { id: UID }

/// Shared protocol-fee configuration. `version` is the upgrade gate: every
/// entry function asserts it matches the package `VERSION`, so a future
/// in-place upgrade + `migrate` call cuts old package flows over atomically.
public struct FeeConfig has key {
    id: UID,
    version: u64,
    /// Fee in basis points applied to seller-bound funds at settlement.
    /// Snapshotted onto each Job at create — never applied retroactively.
    fee_bps: u64,
    /// Where fees settle. Read at settle time (rotatable by AdminCap).
    fee_receiver: address,
}

/// Dynamic-field keys for the AdminCap-tunable job amount bounds on
/// `FeeConfig.id` (S.981). Values are `u64` raw coin units. Stored as DFs —
/// not struct fields — because the compatible-upgrade rules forbid layout
/// changes on the live shared object.
public struct MinJobAmountKey has copy, drop, store {}
public struct MaxJobAmountKey has copy, drop, store {}
/// S.1192 — per-level active-cap override on `FeeConfig.id` (value `u64`).
/// Missing ⇒ the `TIER*_ACTIVE_CAP_DEFAULT` package constant for that level.
public struct TierActiveCapKey has copy, drop, store { level: u8 }
/// S.1192 — regression-floor override on `FeeConfig.id` (value `u64`).
/// Missing ⇒ `NO_DELIVERY_REGRESSION_FLOOR_DEFAULT`.
public struct NoDeliveryRegressionFloorKey has copy, drop, store {}
/// S.1193 — max batch slots override on `FeeConfig.id` (value `u64`).
/// Missing ⇒ `MAX_BATCH_SLOTS_DEFAULT`.
public struct MaxBatchSlotsKey has copy, drop, store {}
/// S.1192 — marker DF on `Job.id`, set by `create_claimed` only: this Job
/// entered through the open board, so it counted +1 into the seller's
/// `active_seller_jobs` and must count −1 at terminal settle
/// (release/reject/refund). Hire jobs never carry it — they never
/// incremented, and an unconditional decrement would let a colluding
/// buyer reset a hunter's counter with a dust hire + instant release.
/// Pre-S.1192 claimed jobs also lack it, which IS the soft start: they
/// never incremented, so their settles must not decrement.
public struct ClaimedJobKey has copy, drop, store {}
/// S.1202 — origin DF on `Job.id` (value = the `BatchOpening`'s `ID`), set
/// by `create_claimed_from_batch` only: this Job was minted from a batch
/// slot, so its terminal settle MUST go through the batch-aware doors in
/// `batch` (which free the per-wave hold in the same tx) — the bare
/// `reputation::release_v2` / `reject_v2*` / `refund_v2` abort on it.
/// Single-opening and hire Jobs never carry it. Defining id = the S.1202
/// upgrade package (V12 pin).
public struct BatchOriginKey has copy, drop, store {}
/// S.1202 — one-shot marker on `Job.id`: this batch Job's per-wave hold
/// was freed (set by the batch settle doors via
/// `mark_batch_hold_released_pkg`). A second free aborts. Defining id =
/// the S.1202 upgrade package (V12 pin).
public struct BatchHoldReleasedKey has copy, drop, store {}
/// S.1210 (v13) — the seller's GLOBAL active seat for this Job was freed
/// at DELIVER (`reputation::on_job_delivered`) or — since S.1255 (v14) —
/// at DECLINE (`reputation::decline_v2`, same idempotent hook). Settle
/// paths skip their decrement when present, so deliver-then-settle never
/// double-frees — and a job delivered on a pre-v13 package (no marker)
/// still frees at settle, the straggler catch-up.
public struct ActiveFreedKey has copy, drop, store {}
/// DF key for the canonical `reputation::ScoreBoard` id on `FeeConfig.id`
/// (S.1054b). Value is the board `ID`. Its EXISTENCE is the single-instance
/// lock: `reputation::create_score_board` records it and aborts if it is
/// already set, so a second board (which would split the derived-address
/// score namespace) can never be shared.
public struct ScoreBoardKey has copy, drop, store {}

/// One escrowed job. Shared so buyer, seller, and cranks can all touch it;
/// the escrow balance is inside the object.
public struct Job<phantom T> has key {
    id: UID,
    buyer: address,
    seller: address,
    escrow: Balance<T>,
    /// Amount locked at create (immutable record for receipts — `escrow`
    /// drains to zero on settlement).
    amount: u64,
    /// Protocol fee bps agreed at create (snapshot of FeeConfig.fee_bps).
    fee_bps: u64,
    /// Hash of the job spec (the A2A Task message / offer terms).
    spec_hash: vector<u8>,
    /// Seller must deliver by this ms timestamp, else refund opens.
    deliver_by_ms: u64,
    /// Buyer's accept/reject window (ms) after delivery; lapse = release.
    review_window_ms: u64,
    /// Buyer's share in basis points if they reject — agreed AT CREATE so
    /// neither side can move the goalposts later. Seller gets the rest.
    reject_split_bps: u64,
    state: u8,
    /// Seller's proof-of-delivery commitment (e.g. Walrus blob hash).
    delivery_hash: vector<u8>,
    delivered_at_ms: u64,
    created_at_ms: u64,
}

// === Events (the activity feed / reputation read these) ===
public struct JobCreated has copy, drop {
    job_id: ID,
    buyer: address,
    seller: address,
    amount: u64,
    fee_bps: u64,
    deliver_by_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    timestamp_ms: u64,
}
public struct JobDelivered has copy, drop {
    job_id: ID,
    seller: address,
    delivery_hash: vector<u8>,
    timestamp_ms: u64,
}
public struct JobReleased has copy, drop {
    job_id: ID,
    buyer: address,
    seller: address,
    amount: u64,
    /// Protocol fee taken out of `amount` (seller received amount - fee).
    fee_amount: u64,
    /// True when the review window lapsed and a crank released (vs buyer accept).
    by_timeout: bool,
    timestamp_ms: u64,
}
public struct JobRejected has copy, drop {
    job_id: ID,
    buyer: address,
    seller: address,
    buyer_amount: u64,
    seller_amount: u64,
    /// Protocol fee taken out of the seller-bound share.
    fee_amount: u64,
    timestamp_ms: u64,
}
public struct JobDeclined has copy, drop {
    job_id: ID,
    buyer: address,
    seller: address,
    amount: u64,
    timestamp_ms: u64,
}
public struct JobRefunded has copy, drop {
    job_id: ID,
    buyer: address,
    seller: address,
    amount: u64,
    timestamp_ms: u64,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    let deployer = ctx.sender();
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, deployer);
    transfer::share_object(FeeConfig {
        id: object::new(ctx),
        version: VERSION,
        fee_bps: FEE_BPS_DEFAULT,
        fee_receiver: deployer,
    });
}

fun assert_version(cfg: &FeeConfig) {
    assert!(cfg.version == VERSION, EWrongVersion);
}

/// Live min job amount: the DF when set, else the package default.
public fun config_min_job_amount(cfg: &FeeConfig): u64 {
    if (df::exists(&cfg.id, MinJobAmountKey {})) {
        *df::borrow(&cfg.id, MinJobAmountKey {})
    } else {
        MIN_JOB_AMOUNT_DEFAULT
    }
}

/// Live max job amount: the DF when set, else the package default.
public fun config_max_job_amount(cfg: &FeeConfig): u64 {
    if (df::exists(&cfg.id, MaxJobAmountKey {})) {
        *df::borrow(&cfg.id, MaxJobAmountKey {})
    } else {
        MAX_JOB_AMOUNT_DEFAULT
    }
}

/// Live active-job cap for a seller level (1..4): the per-level DF when
/// set, else the package default. S.1192 — read at claim by
/// `reputation::active_cap_for_level`.
public fun config_tier_active_cap(cfg: &FeeConfig, level: u8): u64 {
    assert!(level >= 1 && level <= 4, EBadTierBounds);
    if (df::exists(&cfg.id, TierActiveCapKey { level })) {
        *df::borrow(&cfg.id, TierActiveCapKey { level })
    } else if (level == 1) {
        TIER1_ACTIVE_CAP_DEFAULT
    } else if (level == 2) {
        TIER2_ACTIVE_CAP_DEFAULT
    } else if (level == 3) {
        TIER3_ACTIVE_CAP_DEFAULT
    } else {
        TIER4_ACTIVE_CAP_DEFAULT
    }
}

/// Live no-delivery regression floor: the DF when set, else the default.
public fun config_no_delivery_regression_floor(cfg: &FeeConfig): u64 {
    if (df::exists(&cfg.id, NoDeliveryRegressionFloorKey {})) {
        *df::borrow(&cfg.id, NoDeliveryRegressionFloorKey {})
    } else {
        NO_DELIVERY_REGRESSION_FLOOR_DEFAULT
    }
}

/// Live max slots per batch post (S.1193): the DF when set, else the
/// package default. Read at `batch::create_batch_open`.
public fun config_max_batch_slots(cfg: &FeeConfig): u64 {
    if (df::exists(&cfg.id, MaxBatchSlotsKey {})) {
        *df::borrow(&cfg.id, MaxBatchSlotsKey {})
    } else {
        MAX_BATCH_SLOTS_DEFAULT
    }
}

/// Whether this Job was minted from a claimed Opening (S.1192) — the
/// active-counter settle paths decrement ONLY these.
public fun is_claimed_job<T>(job: &Job<T>): bool {
    df::exists(&job.id, ClaimedJobKey {})
}

/// Whether this Job was minted from a batch slot (S.1202). True ⇒ its
/// terminal settle must go through the batch-aware doors in `batch`.
public fun is_batch_origin_job<T>(job: &Job<T>): bool {
    df::exists(&job.id, BatchOriginKey {})
}

/// The `BatchOpening` id this Job was claimed from, when batch-origin
/// (S.1202) — clients read this at prepare time to attach the right batch
/// to the settle PTB. None for single-opening and hire Jobs.
public fun batch_origin<T>(job: &Job<T>): Option<ID> {
    if (df::exists(&job.id, BatchOriginKey {})) {
        option::some(*df::borrow(&job.id, BatchOriginKey {}))
    } else {
        option::none()
    }
}

/// Whether this batch Job's per-wave hold has been freed (S.1202).
public fun is_batch_hold_released<T>(job: &Job<T>): bool {
    df::exists(&job.id, BatchHoldReleasedKey {})
}

/// One-shot hold-released stamp (S.1202) — called only by the batch
/// settle doors after they free the wave hold. Abort-on-second-free is
/// the idempotency lock the SPEC asks for (loud, never a silent double
/// decrement).
public(package) fun mark_batch_hold_released_pkg<T>(job: &mut Job<T>) {
    assert!(!df::exists(&job.id, BatchHoldReleasedKey {}), EBatchHoldReleased);
    df::add(&mut job.id, BatchHoldReleasedKey {}, true);
}

/// Whether this Job's seller already freed their GLOBAL active seat at
/// deliver (S.1210 / v13). Missing ⇒ not freed — settle decrements.
public fun is_active_freed<T>(job: &Job<T>): bool {
    df::exists(&job.id, ActiveFreedKey {})
}

/// One-shot active-freed stamp (S.1210) — set only by
/// `reputation::on_job_delivered` (and, since S.1255, the decline hook in
/// `reputation::decline_v2`) right before the seat-freeing decrement.
/// Abort-on-second-set keeps the idempotency loud (both hooks guard with
/// `is_active_freed` first; this is the belt).
public(package) fun mark_active_freed_pkg<T>(job: &mut Job<T>) {
    assert!(!df::exists(&job.id, ActiveFreedKey {}), EActiveAlreadyFreed);
    df::add(&mut job.id, ActiveFreedKey {}, true);
}

/// Bounds gate for money ENTERING escrow — `create` and (via the package
/// accessor) `opening::create_open` only. Settlement verbs and
/// `create_claimed` never re-check: an Opening fixed its amount at post,
/// and funds already committed must always be able to settle out even if
/// the admin moves the bounds afterwards.
fun assert_amount_in_bounds(cfg: &FeeConfig, amount: u64) {
    assert!(amount >= config_min_job_amount(cfg), EAmountTooSmall);
    assert!(amount <= config_max_job_amount(cfg), EAmountTooLarge);
}

/// Floor(amount * bps / 10_000) with u128 intermediate — no overflow.
fun mul_bps(amount: u64, bps: u64): u64 {
    (((amount as u128) * (bps as u128)) / (BPS_DENOMINATOR as u128)) as u64
}

// === Create (buyer locks funds + terms in one call — one-PTB create+fund) ===

/// Buyer creates and funds a job in one step. Returns the job id so PTB
/// callers can reference it (e.g. to print / hand to the seller as the
/// X-PAYMENT credential).
public fun create<T>(
    seller: address,
    payment: Coin<T>,
    spec_hash: vector<u8>,
    deliver_by_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert_version(cfg);
    let buyer = ctx.sender();
    assert!(buyer != seller, EBuyerIsSeller);
    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
    assert_amount_in_bounds(cfg, amount);
    let now = clock.timestamp_ms();
    assert!(deliver_by_ms > now, EDeadlineInPast);
    assert!(deliver_by_ms <= now + MAX_DELIVER_HORIZON_MS, EDeadlineTooFar);
    assert!(review_window_ms <= MAX_REVIEW_WINDOW_MS, EReviewWindowTooLong);
    assert!(reject_split_bps <= BPS_DENOMINATOR, EBadSplit);
    let job = Job<T> {
        id: object::new(ctx),
        buyer,
        seller,
        escrow: payment.into_balance(),
        amount,
        fee_bps: cfg.fee_bps,
        spec_hash,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        state: STATE_FUNDED,
        delivery_hash: vector[],
        delivered_at_ms: 0,
        created_at_ms: now,
    };
    let job_id = job.id.to_inner();
    event::emit(JobCreated {
        job_id,
        buyer,
        seller,
        amount,
        fee_bps: cfg.fee_bps,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        timestamp_ms: now,
    });
    transfer::share_object(job);
    job_id
}

// === Create from a claimed Opening (SPEC_T2_AGENTS_OPEN_ONCHAIN §3a) ===

/// Package-internal constructor for `opening::claim` — `create` cannot be
/// reused there because it derives `buyer = ctx.sender()`, and at claim time
/// the sender is the claiming seller (wrong buyer + a self-trip on
/// `EBuyerIsSeller`). Takes the Opening's escrow `Balance` and its
/// **snapshotted** `fee_bps` (D-1: a fee change between post and claim must
/// never move terms under committed money — do NOT re-read `cfg.fee_bps`).
/// `cfg` is passed for the version gate only. Emits `JobCreated` exactly
/// like `create` — the indexer / feed / inbox / `t2 job watch` all key on it.
public(package) fun create_claimed<T>(
    buyer: address,
    seller: address,
    escrow: Balance<T>,
    fee_bps: u64,
    spec_hash: vector<u8>,
    deliver_by_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let job = new_claimed_job(
        buyer,
        seller,
        escrow,
        fee_bps,
        spec_hash,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        cfg,
        clock,
        ctx,
    );
    let job_id = job.id.to_inner();
    transfer::share_object(job);
    job_id
}

/// S.1202 sibling for `batch::batch_claim` — same claimed-Job constructor
/// plus the `BatchOriginKey` DF (value = the wave's id), stamped BEFORE
/// `share_object` (the batch module could not mutate the Job after share
/// without another package helper). The origin routes this Job's terminal
/// settle through the batch-aware doors, which free the per-wave hold in
/// the same tx.
public(package) fun create_claimed_from_batch<T>(
    batch_id: ID,
    buyer: address,
    seller: address,
    escrow: Balance<T>,
    fee_bps: u64,
    spec_hash: vector<u8>,
    deliver_by_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let mut job = new_claimed_job(
        buyer,
        seller,
        escrow,
        fee_bps,
        spec_hash,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        cfg,
        clock,
        ctx,
    );
    df::add(&mut job.id, BatchOriginKey {}, batch_id);
    let job_id = job.id.to_inner();
    transfer::share_object(job);
    job_id
}

/// The shared claimed-Job body — validates, brands `ClaimedJobKey`, emits
/// `JobCreated`, and hands the UNSHARED Job back so each caller can stamp
/// its own origin DFs before sharing.
fun new_claimed_job<T>(
    buyer: address,
    seller: address,
    escrow: Balance<T>,
    fee_bps: u64,
    spec_hash: vector<u8>,
    deliver_by_ms: u64,
    review_window_ms: u64,
    reject_split_bps: u64,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): Job<T> {
    assert_version(cfg);
    assert!(buyer != seller, EBuyerIsSeller);
    let amount = escrow.value();
    assert!(amount > 0, EZeroAmount);
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    let now = clock.timestamp_ms();
    assert!(deliver_by_ms > now, EDeadlineInPast);
    assert!(deliver_by_ms <= now + MAX_DELIVER_HORIZON_MS, EDeadlineTooFar);
    assert!(review_window_ms <= MAX_REVIEW_WINDOW_MS, EReviewWindowTooLong);
    assert!(reject_split_bps <= BPS_DENOMINATOR, EBadSplit);
    let mut job = Job<T> {
        id: object::new(ctx),
        buyer,
        seller,
        escrow,
        amount,
        fee_bps,
        spec_hash,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        state: STATE_FUNDED,
        delivery_hash: vector[],
        delivered_at_ms: 0,
        created_at_ms: now,
    };
    // S.1192: brand the Job as board-claimed so terminal settles know to
    // decrement the seller's active counter (hire jobs stay unbranded).
    df::add(&mut job.id, ClaimedJobKey {}, true);
    event::emit(JobCreated {
        job_id: job.id.to_inner(),
        buyer,
        seller,
        amount,
        fee_bps,
        deliver_by_ms,
        review_window_ms,
        reject_split_bps,
        timestamp_ms: now,
    });
    job
}

// === Package-visible guards (shared with `opening` — single source for
// === version gate + caps; no duplicated constants across modules) ===

public(package) fun assert_version_pkg(cfg: &FeeConfig) { assert_version(cfg) }

public(package) fun max_deliver_horizon_ms_pkg(): u64 { MAX_DELIVER_HORIZON_MS }

public(package) fun max_review_window_ms_pkg(): u64 { MAX_REVIEW_WINDOW_MS }

public(package) fun bps_denominator_pkg(): u64 { BPS_DENOMINATOR }

/// Bounds gate for `opening::create_open` — same money-entering rule as
/// `create` (fail-fast at post, never re-checked at claim: `create_claimed`
/// must always be able to mint the Job for an already-escrowed Opening).
public(package) fun assert_amount_in_bounds_pkg(cfg: &FeeConfig, amount: u64) {
    assert_amount_in_bounds(cfg, amount)
}

/// One-shot record of the canonical ScoreBoard id (S.1054b) — called only
/// by `reputation::create_score_board`. The abort-if-set is the on-chain
/// single-instance guarantee; the runbook's "call once" is now enforced,
/// not just documented.
public(package) fun record_score_board_pkg(cfg: &mut FeeConfig, board_id: ID) {
    assert!(!df::exists(&cfg.id, ScoreBoardKey {}), EScoreBoardExists);
    df::add(&mut cfg.id, ScoreBoardKey {}, board_id);
}

// === Deliver (seller posts proof before the deadline) ===
#[allow(lint(prefer_mut_tx_context))]
public fun deliver<T>(
    job: &mut Job<T>,
    delivery_hash: vector<u8>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_version(cfg);
    assert!(ctx.sender() == job.seller, ENotAuthorized);
    assert!(job.state == STATE_FUNDED, EWrongState);
    let now = clock.timestamp_ms();
    assert!(now <= job.deliver_by_ms, EPastDeadline);
    job.delivery_hash = delivery_hash;
    job.delivered_at_ms = now;
    job.state = STATE_DELIVERED;
    event::emit(JobDelivered {
        job_id: job.id.to_inner(),
        seller: job.seller,
        delivery_hash: job.delivery_hash,
        timestamp_ms: now,
    });
}

// === Release (funds → seller, minus the protocol fee) ===
/// DEPRECATED (S.1192) — always aborts `EUseReleaseV2`. The live path is
/// `reputation::release_v2`, which settles via `release_settle_pkg` below
/// AND decrements the seller's active-job counter on board-claimed jobs.
/// Signature survives (Sui compatible upgrades cannot remove public
/// functions); the body is dead.
public fun release<T>(
    _job: &mut Job<T>,
    cfg: &FeeConfig,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(cfg);
    abort EUseReleaseV2
}

/// The release settlement body (S.1192: package-visible so
/// `reputation::release_v2` — the only live caller — settles the money
/// HERE; coin/fee math never leaves this module). Three legitimate
/// callers, unchanged from v1 `release`:
/// 1. The buyer accepting a DELIVERED job.
/// 2. The buyer voluntarily paying a FUNDED job (goodwill / late-accept after
///    an off-band delivery) — it's the buyer's own money moving to the agreed
///    seller, always safe.
/// 3. ANYONE, once a DELIVERED job's review window has lapsed — the
///    permissionless crank that stops a ghosting buyer stranding the seller.
/// Emits `JobReleased` exactly as v1 did — defining id unchanged.
public(package) fun release_settle_pkg<T>(
    job: &mut Job<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(cfg);
    let sender = ctx.sender();
    let now = clock.timestamp_ms();
    let is_buyer = sender == job.buyer;
    let by_timeout = if (job.state == STATE_DELIVERED) {
        let window_lapsed = now > job.delivered_at_ms + job.review_window_ms;
        assert!(is_buyer || window_lapsed, EReviewWindowOpen);
        !is_buyer && window_lapsed
    } else if (job.state == STATE_FUNDED) {
        assert!(is_buyer, ENotAuthorized);
        false
    } else {
        abort EWrongState
    };
    job.state = STATE_RELEASED;
    let amount = job.escrow.value();
    let fee_amount = mul_bps(amount, job.fee_bps);
    if (fee_amount > 0) {
        let fee = coin::from_balance(job.escrow.split(fee_amount), ctx);
        transfer::public_transfer(fee, cfg.fee_receiver);
    };
    let payout = coin::from_balance(job.escrow.withdraw_all(), ctx);
    transfer::public_transfer(payout, job.seller);
    event::emit(JobReleased {
        job_id: job.id.to_inner(),
        buyer: job.buyer,
        seller: job.seller,
        amount,
        fee_amount,
        by_timeout,
        timestamp_ms: now,
    });
}

// === Reject (buyer, within the review window — split per create terms) ===
/// DEPRECATED (S.1063) — always aborts `EUseSettleV2`. The live path is
/// `reputation::reject_v2` / `reject_v2_agent_buyer`, which settles via
/// `reject_settle_pkg` below AND records the protocol outcome on the
/// seller's (and an Agent-ID buyer's) score. Signature survives (Sui
/// compatible upgrades cannot remove public functions); the body is dead.
public fun reject<T>(
    _job: &mut Job<T>,
    cfg: &FeeConfig,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(cfg);
    abort EUseSettleV2
}

/// The reject settlement body (S.1063: package-visible so
/// `reputation::reject_v2*` — the only live callers — settle the money
/// HERE; coin/fee math never leaves this module). The buyer's share is
/// fee-free; the protocol fee applies to the seller-bound share only (so
/// a 0-split reject can't dodge the fee). Emits `JobRejected` exactly as
/// v1 did — defining id unchanged, indexers keep working.
public(package) fun reject_settle_pkg<T>(
    job: &mut Job<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(cfg);
    assert!(ctx.sender() == job.buyer, ENotAuthorized);
    assert!(job.state == STATE_DELIVERED, EWrongState);
    let now = clock.timestamp_ms();
    assert!(now <= job.delivered_at_ms + job.review_window_ms, EReviewWindowClosed);
    job.state = STATE_REJECTED;
    let total = job.escrow.value();
    let buyer_amount = mul_bps(total, job.reject_split_bps);
    let seller_gross = total - buyer_amount;
    let fee_amount = mul_bps(seller_gross, job.fee_bps);
    let seller_amount = seller_gross - fee_amount;
    if (buyer_amount > 0) {
        let to_buyer = coin::from_balance(job.escrow.split(buyer_amount), ctx);
        transfer::public_transfer(to_buyer, job.buyer);
    };
    if (fee_amount > 0) {
        let fee = coin::from_balance(job.escrow.split(fee_amount), ctx);
        transfer::public_transfer(fee, cfg.fee_receiver);
    };
    if (seller_amount > 0) {
        let to_seller = coin::from_balance(job.escrow.withdraw_all(), ctx);
        transfer::public_transfer(to_seller, job.seller);
    };
    event::emit(JobRejected {
        job_id: job.id.to_inner(),
        buyer: job.buyer,
        seller: job.seller,
        buyer_amount,
        seller_amount,
        fee_amount,
        timestamp_ms: now,
    });
}

// === Decline (SELLER, before delivery — funds → buyer, fee-free) ===
/// DEPRECATED (S.1255) — always aborts `EUseSettleV2`. The live path is
/// `reputation::decline_v2`, which settles via `decline_settle_pkg` below
/// AND frees the seller's global active seat on board-claimed jobs (the
/// old rule — decline burns the seat forever — was the anti-churn lock;
/// S.1255 deliberately deletes it: the D13 wave hold plus deadline
/// `no_delivery` remain the anti-farm rails). Signature survives (Sui
/// compatible upgrades cannot remove public functions); the body is dead.
public fun decline<T>(
    _job: &mut Job<T>,
    cfg: &FeeConfig,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(cfg);
    abort EUseSettleV2
}

/// The decline settlement body (S.1255: package-visible so
/// `reputation::decline_v2` — the only live caller — settles the money
/// HERE; coin math never leaves this module). The seller's abort
/// (SPEC_T2_AGENTS_TRUST §B): an unwilling or unable seller returns the
/// escrow immediately instead of stranding the buyer until the deadline
/// refund. FUNDED only — after delivery the buyer's release/reject verbs
/// own the outcome. Fee-free (the protocol never earns on a failed job)
/// and terminal-state REFUNDED — a NEW state would break every published
/// reader that maps state numbers; `JobDeclined` (vs `JobRefunded`) is
/// how indexers tell a decline from a deadline refund. Emits
/// `JobDeclined` exactly as v3 did — defining id unchanged.
public(package) fun decline_settle_pkg<T>(
    job: &mut Job<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(cfg);
    assert!(ctx.sender() == job.seller, ENotAuthorized);
    assert!(job.state == STATE_FUNDED, EWrongState);
    job.state = STATE_REFUNDED;
    let amount = job.escrow.value();
    let payout = coin::from_balance(job.escrow.withdraw_all(), ctx);
    transfer::public_transfer(payout, job.buyer);
    event::emit(JobDeclined {
        job_id: job.id.to_inner(),
        buyer: job.buyer,
        seller: job.seller,
        amount,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Refund (ANYONE, after the deadline with no delivery — funds → buyer) ===
/// DEPRECATED (S.1063) — always aborts `EUseSettleV2`. The live path is
/// `reputation::refund_v2` (deadline no-delivery is a protocol outcome on
/// the seller's score). Signature survives; the body is dead.
public fun refund<T>(
    _job: &mut Job<T>,
    cfg: &FeeConfig,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(cfg);
    abort EUseSettleV2
}

/// The deadline-refund body (S.1063: package-visible — `reputation::
/// refund_v2` is the only live caller). Permissionless crank: funds can
/// only ever go back to the buyer, so open authorship is safe. Always
/// fee-free — the protocol never earns on a failed job. Emits
/// `JobRefunded` exactly as v1 did.
public(package) fun refund_settle_pkg<T>(
    job: &mut Job<T>,
    cfg: &FeeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(cfg);
    assert!(job.state == STATE_FUNDED, EWrongState);
    let now = clock.timestamp_ms();
    assert!(now > job.deliver_by_ms, EDeadlineNotReached);
    job.state = STATE_REFUNDED;
    let amount = job.escrow.value();
    let payout = coin::from_balance(job.escrow.withdraw_all(), ctx);
    transfer::public_transfer(payout, job.buyer);
    event::emit(JobRefunded {
        job_id: job.id.to_inner(),
        buyer: job.buyer,
        seller: job.seller,
        amount,
        timestamp_ms: now,
    });
}

// === Admin (AdminCap-gated fee administration) ===

public fun set_fee_bps(_: &AdminCap, cfg: &mut FeeConfig, fee_bps: u64) {
    assert_version(cfg);
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    cfg.fee_bps = fee_bps;
}

public fun set_fee_receiver(_: &AdminCap, cfg: &mut FeeConfig, receiver: address) {
    assert_version(cfg);
    cfg.fee_receiver = receiver;
}

/// Set (add or update) the live min job amount DF. Rails: never below the
/// package hard floor, never above the live max — `min ≤ max` always holds
/// after a set, so `create` can never become unsatisfiable.
public fun set_min_job_amount(_: &AdminCap, cfg: &mut FeeConfig, min_amount: u64) {
    assert_version(cfg);
    assert!(min_amount >= MIN_JOB_AMOUNT_FLOOR, EBadAmountBounds);
    assert!(min_amount <= config_max_job_amount(cfg), EBadAmountBounds);
    if (df::exists(&cfg.id, MinJobAmountKey {})) {
        *df::borrow_mut(&mut cfg.id, MinJobAmountKey {}) = min_amount;
    } else {
        df::add(&mut cfg.id, MinJobAmountKey {}, min_amount);
    }
}

/// Set (add or update) the live max job amount DF. Rails: never above the
/// package hard ceiling, never below the live min.
public fun set_max_job_amount(_: &AdminCap, cfg: &mut FeeConfig, max_amount: u64) {
    assert_version(cfg);
    assert!(max_amount <= MAX_JOB_AMOUNT_CEILING, EBadAmountBounds);
    assert!(max_amount >= config_min_job_amount(cfg), EBadAmountBounds);
    if (df::exists(&cfg.id, MaxJobAmountKey {})) {
        *df::borrow_mut(&mut cfg.id, MaxJobAmountKey {}) = max_amount;
    } else {
        df::add(&mut cfg.id, MaxJobAmountKey {}, max_amount);
    }
}

/// S.1192 — set (add or update) one level's live active cap. Level 1..4,
/// cap > 0 (a 0 cap would freeze the level entirely — deactivate agents
/// via the registry, not via capacity).
public fun set_tier_active_cap(_: &AdminCap, cfg: &mut FeeConfig, level: u8, cap: u64) {
    assert_version(cfg);
    assert!(level >= 1 && level <= 4, EBadTierBounds);
    assert!(cap > 0, EBadTierBounds);
    if (df::exists(&cfg.id, TierActiveCapKey { level })) {
        *df::borrow_mut(&mut cfg.id, TierActiveCapKey { level }) = cap;
    } else {
        df::add(&mut cfg.id, TierActiveCapKey { level }, cap);
    }
}

/// S.1192 — set (add or update) the live no-delivery regression floor.
/// Must be > 0 (a 0 floor would regress every seller forever).
public fun set_no_delivery_regression_floor(_: &AdminCap, cfg: &mut FeeConfig, n: u64) {
    assert_version(cfg);
    assert!(n > 0, EBadTierBounds);
    if (df::exists(&cfg.id, NoDeliveryRegressionFloorKey {})) {
        *df::borrow_mut(&mut cfg.id, NoDeliveryRegressionFloorKey {}) = n;
    } else {
        df::add(&mut cfg.id, NoDeliveryRegressionFloorKey {}, n);
    }
}

/// S.1193 — set (add or update) the live max batch slots. Rails: 1..
/// package hard ceiling (a 0 max would brick batch posting; raising the
/// ceiling itself needs a future upgrade).
public fun set_max_batch_slots(_: &AdminCap, cfg: &mut FeeConfig, n: u64) {
    assert_version(cfg);
    assert!(n >= 1 && n <= MAX_BATCH_SLOTS_CEILING, EBadBatchSlots);
    if (df::exists(&cfg.id, MaxBatchSlotsKey {})) {
        *df::borrow_mut(&mut cfg.id, MaxBatchSlotsKey {}) = n;
    } else {
        df::add(&mut cfg.id, MaxBatchSlotsKey {}, n);
    }
}

/// Version cutover after an in-place package upgrade: bumps the shared
/// config to the new package's VERSION, which makes every entry in the OLD
/// package abort with EWrongVersion.
public fun migrate(_: &AdminCap, cfg: &mut FeeConfig) {
    assert!(cfg.version < VERSION, ENotUpgrade);
    cfg.version = VERSION;
}

// === Read accessors (seller verification + composing contracts) ===
public fun buyer<T>(job: &Job<T>): address { job.buyer }
public fun seller<T>(job: &Job<T>): address { job.seller }
public fun amount<T>(job: &Job<T>): u64 { job.amount }
public fun fee_bps<T>(job: &Job<T>): u64 { job.fee_bps }
public fun escrow_value<T>(job: &Job<T>): u64 { job.escrow.value() }
public fun spec_hash<T>(job: &Job<T>): vector<u8> { job.spec_hash }
public fun deliver_by_ms<T>(job: &Job<T>): u64 { job.deliver_by_ms }
public fun review_window_ms<T>(job: &Job<T>): u64 { job.review_window_ms }
public fun reject_split_bps<T>(job: &Job<T>): u64 { job.reject_split_bps }
public fun state<T>(job: &Job<T>): u8 { job.state }
public fun delivery_hash<T>(job: &Job<T>): vector<u8> { job.delivery_hash }
public fun delivered_at_ms<T>(job: &Job<T>): u64 { job.delivered_at_ms }
public fun created_at_ms<T>(job: &Job<T>): u64 { job.created_at_ms }

public fun config_version(cfg: &FeeConfig): u64 { cfg.version }
public fun config_fee_bps(cfg: &FeeConfig): u64 { cfg.fee_bps }
public fun config_fee_receiver(cfg: &FeeConfig): address { cfg.fee_receiver }

/// The canonical reputation ScoreBoard id, once created (S.1054b) — clients
/// and ops can resolve the board from FeeConfig instead of trusting a pin.
public fun config_score_board_id(cfg: &FeeConfig): Option<ID> {
    if (df::exists(&cfg.id, ScoreBoardKey {})) {
        option::some(*df::borrow(&cfg.id, ScoreBoardKey {}))
    } else {
        option::none()
    }
}

public fun state_funded(): u8 { STATE_FUNDED }
public fun state_delivered(): u8 { STATE_DELIVERED }
public fun state_released(): u8 { STATE_RELEASED }
public fun state_refunded(): u8 { STATE_REFUNDED }
public fun state_rejected(): u8 { STATE_REJECTED }

// === Test hooks ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun set_version_for_testing(cfg: &mut FeeConfig, version: u64) {
    cfg.version = version;
}

#[test_only]
public fun current_version(): u64 { VERSION }

#[test_only]
public fun max_fee_bps(): u64 { MAX_FEE_BPS }
#[test_only]
public fun max_review_window_ms(): u64 { MAX_REVIEW_WINDOW_MS }
#[test_only]
public fun max_deliver_horizon_ms(): u64 { MAX_DELIVER_HORIZON_MS }
#[test_only]
public fun default_fee_bps(): u64 { FEE_BPS_DEFAULT }
/// Rail-free DF write so settlement-math tests (e.g. dust fees flooring to
/// zero) can still create sub-minimum jobs — production sets go through
/// `set_min_job_amount`'s rails.
#[test_only]
public fun set_min_job_amount_for_testing(cfg: &mut FeeConfig, min_amount: u64) {
    if (df::exists(&cfg.id, MinJobAmountKey {})) {
        *df::borrow_mut(&mut cfg.id, MinJobAmountKey {}) = min_amount;
    } else {
        df::add(&mut cfg.id, MinJobAmountKey {}, min_amount);
    }
}

#[test_only]
public fun default_min_job_amount(): u64 { MIN_JOB_AMOUNT_DEFAULT }
#[test_only]
public fun default_max_job_amount(): u64 { MAX_JOB_AMOUNT_DEFAULT }
#[test_only]
public fun min_job_amount_floor(): u64 { MIN_JOB_AMOUNT_FLOOR }
#[test_only]
public fun max_job_amount_ceiling(): u64 { MAX_JOB_AMOUNT_CEILING }
#[test_only]
public fun default_max_batch_slots(): u64 { MAX_BATCH_SLOTS_DEFAULT }
#[test_only]
public fun max_batch_slots_ceiling(): u64 { MAX_BATCH_SLOTS_CEILING }
