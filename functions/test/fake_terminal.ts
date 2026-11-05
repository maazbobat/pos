import type Stripe from "stripe";
import {
  type CreateIntent,
  type ReaderAddress,
  type ReaderSetupApi,
  type TerminalApi,
  TerminalError,
  type TerminalIntent,
} from "../src/payments/stripe_terminal.js";

interface Stored extends TerminalIntent {
  account: string;
}

/**
 * Stripe's side of Stripe Terminal, in memory: PaymentIntents per connected
 * account, readers that are online, offline or busy, idempotency keys, and
 * a guest who taps (tap), gets declined (decline) or pays with Interac.
 */
export class FakeTerminalApi implements TerminalApi {
  readonly intents = new Map<string, Stored>();
  readonly byKey = new Map<string, string>();
  readonly refunds = new Map<string, { id: string; intentId: string; amountCents: number }>();
  readonly onReader = new Map<string, string>();
  readerState: "online" | "offline" | "busy" | "timeout" = "online";
  calls: string[] = [];
  private n = 0;

  private get(account: string, id: string): Stored {
    const pi = this.intents.get(id);
    if (!pi || pi.account !== account) throw new Error(`No such payment_intent: ${id}`);
    return pi;
  }

  private view(pi: Stored): TerminalIntent {
    const { account: _account, ...rest } = pi;
    return { ...rest, metadata: { ...rest.metadata } };
  }

  async createIntent(account: string, req: CreateIntent, idempotencyKey: string): Promise<TerminalIntent> {
    this.calls.push("createIntent");
    const existing = this.byKey.get(`${account}:${idempotencyKey}`);
    if (existing) return this.view(this.get(account, existing));
    const id = `pi_${++this.n}`;
    const pi: Stored = {
      id, account, status: "requires_payment_method", amount: req.amountCents, metadata: req.metadata,
      lastErrorCode: null, chargeMethod: null,
    };
    this.intents.set(id, pi);
    this.byKey.set(`${account}:${idempotencyKey}`, id);
    return this.view(pi);
  }

  async retrieveIntent(account: string, id: string): Promise<TerminalIntent> {
    return this.view(this.get(account, id));
  }

  async findIntentByKey(account: string, key: string): Promise<TerminalIntent | null> {
    for (const pi of this.intents.values()) {
      if (pi.account === account && pi.metadata.idempotencyKey === key) return this.view(pi);
    }
    return null;
  }

  async cancelIntent(account: string, id: string): Promise<TerminalIntent> {
    this.calls.push("cancelIntent");
    const pi = this.get(account, id);
    if (pi.status === "succeeded") throw new Error("This PaymentIntent has already succeeded.");
    pi.status = "canceled";
    return this.view(pi);
  }

  async processOnReader(account: string, readerId: string, intentId: string): Promise<void> {
    this.calls.push("processOnReader");
    this.get(account, intentId);
    if (this.readerState === "offline") throw new TerminalError("terminal_reader_offline", "Reader is offline.");
    if (this.readerState === "busy") throw new TerminalError("terminal_reader_busy", "Reader is busy.");
    if (this.readerState === "timeout") {
      this.onReader.set(readerId, intentId);
      throw new TerminalError("terminal_reader_timeout", "Reader timed out.");
    }
    this.onReader.set(readerId, intentId);
  }

  async cancelReaderAction(_account: string, readerId: string): Promise<void> {
    this.calls.push("cancelReaderAction");
    this.onReader.delete(readerId);
  }

  async refund(account: string, intentId: string, amountCents: number, idempotencyKey: string) {
    this.calls.push("refund");
    const existing = this.refunds.get(idempotencyKey);
    if (existing) return { id: existing.id, status: "succeeded" };
    this.get(account, intentId);
    const r = { id: `re_${++this.n}`, intentId, amountCents };
    this.refunds.set(idempotencyKey, r);
    return { id: r.id, status: "succeeded" };
  }

  /** The guest at the reader: taps a card, has it declined, or pays with Interac debit. */
  guest(readerId: string, outcome: "tap" | "decline" | "interac"): void {
    const id = this.onReader.get(readerId);
    if (!id) throw new Error(`Nothing on reader ${readerId}`);
    const pi = this.intents.get(id)!;
    if (outcome === "decline") {
      pi.lastErrorCode = "insufficient_funds";
    } else {
      pi.status = "succeeded";
      pi.lastErrorCode = null;
      pi.chargeMethod = outcome === "interac" ? "interac_present" : "card_present";
    }
    this.onReader.delete(readerId);
  }

  intentFor(key: string): Stored | undefined {
    for (const pi of this.intents.values()) if (pi.metadata.idempotencyKey === key) return pi;
    return undefined;
  }
}

export class FakeReaderSetupApi implements ReaderSetupApi {
  locations: { account: string; name: string; address: ReaderAddress }[] = [];
  readers: { account: string; code: string; label: string; location: string }[] = [];
  validCodes = new Set(["simulated-wpe", "quick-brown-fox"]);

  async createLocation(account: string, name: string, address: ReaderAddress): Promise<string> {
    this.locations.push({ account, name, address });
    return `tml_${this.locations.length}`;
  }

  async registerReader(account: string, code: string, label: string, location: string) {
    if (!this.validCodes.has(code)) throw new Error("Invalid registration code");
    this.readers.push({ account, code, label, location });
    return { id: `tmr_${this.readers.length}`, deviceType: "stripe_s700" as Stripe.Terminal.Reader.DeviceType };
  }
}
