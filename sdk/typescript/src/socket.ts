/**
 * `@pweb/runtime` — the native socket door (CAP-15C).
 *
 * A socket object shaped like the browser's, over four `invoke` calls — `pweb.socketOpen`,
 * `pweb.socketSend`, `pweb.socketReceive`, `pweb.socketClose` — and nothing
 * else. The page opens no socket: `PWEB_NATIVE_CSP` keeps
 * `connect-src 'self'`, and the runtime opens the connection per the
 * `network.socket` capability and the origin allowlist compiled into the
 * host. A secure socket URL is authorised by a declared https origin, a plain
 * one only by a declared development loopback origin — see `docs/cli-contract.md` §5.
 *
 * This file constructs no URL, supplies no default origin, adds no header,
 * retries nothing and reconnects nothing. Every one of those is a native
 * decision or an application's, never this SDK's.
 *
 * THE RECEIVE LOOP. Protocol v1 has no server push, so each socket runs ONE
 * bounded long-poll after another: `pweb.socketReceive {id, waitMs}` answers
 * at once with what is queued, or waits for the first event. That loop is the
 * receive path, not a placeholder: CAP-12A measured WebView2 withholding a
 * streamed body from the page until it is complete, and ratified a data plane
 * Range-based, not streaming-based, so no streaming route exists to replace it.
 * Each receive in flight holds one native scheduler worker for up to `waitMs`.
 *
 * Browser-shaped, with the differences stated rather than hidden: messages
 * are `string` or `ArrayBuffer` (no `Blob`); there is no `bufferedAmount`,
 * no `extensions` and no `addEventListener` — the four handler properties
 * are the surface; `send` on a socket that is not open throws rather than
 * dropping the message; and a close event carries `category` (why) and
 * `undelivered` (how many received messages were discarded unread).
 */
import { invoke } from "./invoke.js";
import { PWebError, toPWebError } from "./errors.js";
import type { JsonValue } from "./types.js";

/** The runtime-owned methods, spelled once. */
export const PWEB_METHOD_SOCKET_OPEN = "pweb.socketOpen";
export const PWEB_METHOD_SOCKET_SEND = "pweb.socketSend";
export const PWEB_METHOD_SOCKET_RECEIVE = "pweb.socketReceive";
export const PWEB_METHOD_SOCKET_CLOSE = "pweb.socketClose";

/** The capability that authorizes all four. ADVISORY here: authorization is
 * native and per invocation. */
export const PWEB_CAP_NETWORK_SOCKET = "network.socket";

/** The native bounds this SDK must respect — cross-checked against
 * `src/rpc/pweb.rpc.socket.pas` by the CAP-15C contract gate. */
export const PWEB_SOCKET_RECEIVE_WAIT_MS = 25000;
export const PWEB_SOCKET_MAX_MESSAGE = 1048576;
export const PWEB_SOCKET_MAX_PROTOCOLS = 4;
export const PWEB_SOCKET_MAX_REASON_BYTES = 123;

export interface PWebSocketOptions {
  /** at most four RFC 7230 tokens; the server must select one of them */
  readonly protocols?: readonly string[];
  /** the fetch door's request-header allowlist, exactly */
  readonly headers?: Readonly<Record<string, string>>;
}

export interface PWebSocketOpenEvent {
  readonly protocol: string;
}

export interface PWebSocketMessageEvent {
  readonly data: string | ArrayBuffer;
}

export interface PWebSocketErrorEvent {
  /** the PWeb error code, or `service_error` for a transport failure */
  readonly code: string;
  /** the native category, when there is one */
  readonly category: string | null;
  /** the rejection behind it, when the error came from an invocation */
  readonly error: PWebError | null;
}

export interface PWebSocketCloseEvent {
  readonly code: number;
  readonly reason: string;
  readonly wasClean: boolean;
  /** remote | abnormal | page | idle | navigation | revoked | shutdown |
   * protocol_error | message_too_large | failed */
  readonly category: string;
  readonly undelivered: number;
}

interface WireEvent {
  readonly type: string;
  readonly protocol?: string;
  readonly text?: string;
  readonly base64?: string;
  readonly code?: number;
  readonly reason?: string;
  readonly wasClean?: boolean;
  readonly category?: string;
  readonly undelivered?: number;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function fromBase64(text: string): ArrayBuffer {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

export class PWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readonly url: string;
  readonly binaryType = "arraybuffer" as const;

  onopen: ((event: PWebSocketOpenEvent) => void) | null = null;
  onmessage: ((event: PWebSocketMessageEvent) => void) | null = null;
  onerror: ((event: PWebSocketErrorEvent) => void) | null = null;
  onclose: ((event: PWebSocketCloseEvent) => void) | null = null;

  private id: string | null = null;
  private state: number = PWebSocket.CONNECTING;
  private selected = "";
  private sendChain: Promise<void> = Promise.resolve();
  private closeWanted: { code: number | undefined; reason: string | undefined } | null = null;

  constructor(url: string, options?: PWebSocketOptions) {
    this.url = url;
    // an ABSENT option is absent rather than null: the native door refuses
    // an argument of the wrong type
    const args: Record<string, JsonValue> = { url };
    if (options?.protocols !== undefined) {
      args.protocols = [...options.protocols];
    }
    if (options?.headers !== undefined) {
      args.headers = options.headers as unknown as JsonValue;
    }
    invoke(PWEB_METHOD_SOCKET_OPEN, args).then(
      (value) => {
        this.id = (value as { id: string }).id;
        void this.receiveLoop();
        if (this.closeWanted !== null) {
          const wanted = this.closeWanted;
          this.closeWanted = null;
          this.requestClose(wanted.code, wanted.reason);
        }
      },
      (reason: unknown) => this.fail(toPWebError(reason)),
    );
  }

  get readyState(): number {
    return this.state;
  }

  get protocol(): string {
    return this.selected;
  }

  /** Queue one message, in order. Throws on a socket that is not open. */
  send(data: string | ArrayBuffer | ArrayBufferView): void {
    if (this.state !== PWebSocket.OPEN || this.id === null) {
      throw new PWebError("invalid_request", "The socket is not open");
    }
    const args: Record<string, JsonValue> = { id: this.id };
    if (typeof data === "string") {
      args.text = data;
    } else if (data instanceof ArrayBuffer) {
      args.base64 = toBase64(new Uint8Array(data));
    } else {
      args.base64 = toBase64(
        new Uint8Array(data.buffer, data.byteOffset, data.byteLength),
      );
    }
    // ONE send in flight at a time, so messages leave in the order given
    this.sendChain = this.sendChain
      .then(() => invoke(PWEB_METHOD_SOCKET_SEND, args))
      .then(
        () => undefined,
        (reason: unknown) => this.fail(toPWebError(reason)),
      );
  }

  /** Close with 1000 or an application code 3000–4999. Idempotent. */
  close(code?: number, reason?: string): void {
    if (this.state === PWebSocket.CLOSING || this.state === PWebSocket.CLOSED) {
      return;
    }
    if (this.id === null) {
      this.closeWanted = { code, reason };
      this.state = PWebSocket.CLOSING;
      return;
    }
    this.requestClose(code, reason);
  }

  private requestClose(code?: number, reason?: string): void {
    const args: Record<string, JsonValue> = { id: this.id as string };
    if (code !== undefined) {
      args.code = code;
    }
    if (reason !== undefined) {
      args.reason = reason;
    }
    this.state = PWebSocket.CLOSING;
    invoke(PWEB_METHOD_SOCKET_CLOSE, args).catch((r: unknown) =>
      this.fail(toPWebError(r)),
    );
  }

  // THE RECEIVE LOOP — one bounded long-poll after another (see the header)
  private async receiveLoop(): Promise<void> {
    while (this.state !== PWebSocket.CLOSED) {
      let value: JsonValue;
      try {
        value = await invoke(PWEB_METHOD_SOCKET_RECEIVE, {
          id: this.id as string,
          waitMs: PWEB_SOCKET_RECEIVE_WAIT_MS,
        });
      } catch (reason) {
        this.fail(toPWebError(reason));
        return;
      }
      const events = ((value as { events?: WireEvent[] }).events ?? []);
      for (const event of events) {
        this.dispatch(event);
      }
    }
  }

  private dispatch(event: WireEvent): void {
    switch (event.type) {
      case "open":
        if (this.state === PWebSocket.CONNECTING) {
          this.state = PWebSocket.OPEN;
        }
        this.selected = event.protocol ?? "";
        this.onopen?.({ protocol: this.selected });
        break;
      case "message":
        this.onmessage?.({
          data: event.base64 !== undefined ? fromBase64(event.base64) : (event.text ?? ""),
        });
        break;
      case "error":
        this.onerror?.({
          code: "service_error",
          category: event.category ?? null,
          error: null,
        });
        break;
      case "close":
        this.state = PWebSocket.CLOSED;
        this.onclose?.({
          code: event.code ?? 1005,
          reason: event.reason ?? "",
          wasClean: event.wasClean === true,
          category: event.category ?? "remote",
          undelivered: event.undelivered ?? 0,
        });
        break;
    }
  }

  private fail(error: PWebError): void {
    if (this.state === PWebSocket.CLOSED) {
      return;
    }
    this.state = PWebSocket.CLOSED;
    const data = error.data as { category?: string } | null;
    this.onerror?.({
      code: error.code,
      category: data !== null && typeof data === "object" && typeof data.category === "string"
        ? data.category
        : null,
      error,
    });
    this.onclose?.({
      code: 1006,
      reason: "",
      wasClean: false,
      category: "failed",
      undelivered: 0,
    });
  }
}
