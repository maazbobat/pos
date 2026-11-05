/**
 * Subscription state to access level. Pure, so the rules of the grace
 * period are tested without Stripe or Firestore.
 *
 * orgs/{orgId}/billing/subscription is the server-side source of truth. It's
 * written only by the Stripe webhook, the platform admin's manual plan
 * Functions and the hourly enforcement job. org.accessLevel is derived from
 * it, and firestore.rules turns `read_only` into "everyone reads, nobody
 * writes": billing problems never lock anyone out of their own data.
 *
 *   trial or active          full
 *   lapsed (payment failed,  full until GRACE_DAYS after the lapse,
 *   cancelled, trial over)   then read_only
 *   paid again               full, and the lapse is forgotten
 */

export const PLANS = ["trial", "starter", "professional", "franchise"] as const;
export type Plan = (typeof PLANS)[number];

/** Plans an owner can buy through Stripe Checkout. Franchise is custom, set by the platform admin. */
export const SELF_SERVE_PLANS = ["starter", "professional"] as const;
export type SelfServePlan = (typeof SELF_SERVE_PLANS)[number];

/**
 * Stripe price lookup keys. The prices themselves (Starter ~$79 CAD/mo,
 * Professional ~$149) live in Stripe so they can change without a deploy;
 * create them with these lookup keys.
 */
export const PRICE_LOOKUP_KEYS: Record<SelfServePlan, string> = {
  starter: "pos_starter_monthly_cad",
  professional: "pos_professional_monthly_cad",
};

export function planForLookupKey(key: string | null | undefined): SelfServePlan | null {
  const hit = Object.entries(PRICE_LOOKUP_KEYS).find(([, k]) => k === key);
  return hit ? (hit[0] as SelfServePlan) : null;
}

export const TRIAL_DAYS = 30;
export const GRACE_DAYS = 14;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Where the plan came from: the platform's free trial, Stripe, or a deal set by hand. */
export type BillingSource = "trial" | "stripe" | "manual";

/** Stripe's subscription statuses, which manual and trial plans reuse. */
export type BillingStatus =
  | "trialing"
  | "active"
  | "past_due"
  | "unpaid"
  | "canceled"
  | "incomplete"
  | "incomplete_expired"
  | "paused";

export type AccessLevel = "full" | "read_only";

/** The parts of the subscription doc that decide access. Times are epoch ms. */
export interface BillingState {
  source: BillingSource;
  status: BillingStatus;
  trialEndsAt: number | null;
  lapsedAt: number | null;
}

export interface Access {
  accessLevel: AccessLevel;
  inGoodStanding: boolean;
  /** When the lapse started, kept so a later webhook doesn't restart the grace period. */
  lapsedAt: number | null;
  graceEndsAt: number | null;
  /** When the enforcement job must look again, or null if nothing changes on its own. */
  accessReviewAt: number | null;
}

export function deriveAccess(state: BillingState, now: number): Access {
  const trialOver = state.source === "trial" && state.trialEndsAt !== null && state.trialEndsAt <= now;
  const good = (state.status === "active" || state.status === "trialing") && !trialOver;

  if (good) {
    const reviewAt = state.source === "trial" ? state.trialEndsAt : null;
    return { accessLevel: "full", inGoodStanding: true, lapsedAt: null, graceEndsAt: null, accessReviewAt: reviewAt };
  }

  const lapsedAt = state.lapsedAt ?? (trialOver ? state.trialEndsAt! : now);
  const graceEndsAt = lapsedAt + GRACE_DAYS * DAY_MS;
  const inGrace = now < graceEndsAt;
  return {
    accessLevel: inGrace ? "full" : "read_only",
    inGoodStanding: false,
    lapsedAt,
    graceEndsAt,
    accessReviewAt: inGrace ? graceEndsAt : null,
  };
}

export function trialEnd(now: number, days = TRIAL_DAYS): number {
  return now + days * DAY_MS;
}
