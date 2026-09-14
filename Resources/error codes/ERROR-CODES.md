# LLM router error codes

Every response this router produces carries a numeric code beside the HTTP status — successes as
well as errors. The status says
*whose fault it was*; the code says *what actually happened* and *whether trying again will help*.
Those are different questions, and an HTTP status answers only the first.

Generated from `router/errcodes.go`, which is the source of truth. If the two disagree, the code is
right and this file is stale.

## Where to read it

| | |
|---|---|
| `X-LLMR-Code` | the number, e.g. `112` |
| `X-LLMR-Reason` | the one-line meaning, e.g. `backend not responding` |
| `error.router_code` | the number, in the JSON body (OpenAI and Anthropic surfaces) |
| `error.router_reason` | the meaning, in the JSON body |

The **header is set on every response**, success or failure, including streamed ones. That matters: once a response has
started, the status line is already sent and the body is a token stream, so for anything that fails
mid-stream the header is the only place a machine-readable reason can go.

The Ollama surface gets the **headers only**. Its error shape is a single `{"error": "..."}` field
and stock clients parse it strictly, so nothing is added to the body there.

The existing OpenAI `type` and `code` strings are unchanged. A client that knows nothing about this
scheme sees exactly what it saw before.

## How the numbering works

The tens digit is the subsystem, so a code can be triaged before it is looked up:

| group | | |
|---|---|---|
| `10x` | **Success** | the request was served; the code says what kind of reply, or what it took |
| `11x` | **Upstream** | the route was chosen and the backend failed |
| `12x` | **Request** | the request is malformed or not acceptable |
| `13x` | **Auth** | who is asking, and whether they may |
| `14x` | **Model** | the model, the route and their limits |
| `15x` | **Limits** | rate limiting, quota and capacity |
| `16x` | **Router** | faults in this process |
| `17x` | **Stream** | failures after the response has started |
| `18x` | **Content** | filters and refusals, decided by the provider |
| `19x` | **Capability** | the model or target cannot do what was asked |

**Codes are stable once assigned.** A new condition takes a new number; it never reuses a retired
one and never narrows an existing one, because somewhere an alert is keyed on it. Each group is
exactly ten and all ten groups are currently full — the next group is `20x`.

These are **router codes, not HTTP statuses**. They never appear on a status line, only in
`X-LLMR-Code` and `error.router_code`, so the numeric overlap with HTTP's own `1xx` informational
range is not a collision: a `100` here means *served cleanly*, and has nothing to do with
`100 Continue`.

## The retry column

This is the part worth wiring into a client.

| value | meaning |
|---|---|
| **no** | resending the identical request cannot succeed. Surface it. |
| **wait** | transient. The same request may succeed later, with backoff. |
| **failover** | this target will keep failing; a different target may not. |

The distinction the scheme exists for: `112` and `113` are both `11x`, both answer HTTP 502, and
they are **opposites**. A backend that timed out is worth another attempt. A backend that rejected
*our* API key will reject it however many times it is sent — and note that it is our credential for
the provider that failed, not the caller's, which is why the caller still sees a 502 rather than a
401. Sending someone to check the wrong key is exactly what a flat 502 used to do.

Anything not listed in `retryPolicy` defaults to **no**. A new code fails closed rather than causing
a client to hammer a backend that has already said no.

## The codes

### 10x — Success

The request was served. The code says what kind of reply it is, or what it took to produce.

| code | meaning | retry |
|---|---|---|
| `100` | ok | — |
| `101` | ok, streaming response | — |
| `102` | ok, chunked response | — |
| `103` | ok, link to a further response | — |
| `104` | ok, streaming; hold for reply | — |
| `105` | served from cache | — |
| `106` | served after retry or failover | — |
| `107` | served after output truncated or trimmed | — |
| `108` | served with a warning | — |
| `109` | unsupported parameters dropped | — |

`100`–`105` describe the **shape** of the reply. `106`–`109` describe something **notable** about how
it was produced. When both apply the notable one wins: that a reply is streamed is already stated by
`Content-Type`, whereas a failover is not visible to the client anywhere else.

`106` is the one worth alerting on. Every request still returns 200, so nothing else fires — but the
router is routinely working around a backend that is failing. It catches a degrading provider before
it becomes an outage.

**Timing.** These ride in the same header, and for a **streamed** reply that header is written before
the first token — so only what is known at that moment can appear there. `100`–`106` are known then.
`107` is not: whether the output gets truncated depends on generation that has not happened yet, so
for a stream it appears in the request log only. For a non-streamed reply everything is known before
anything is written, and the header carries the most specific code.

**Not yet emitted:** `103`, `104`, `105`, `108`, `109`. There is no cache, no deferred-response API
and no parameter-drop reporting in the router today. They are reserved with fixed meanings so that
adding any of them is a code change rather than a renumbering — and a renumbering breaks whatever is
keyed on the old value.

The retry column is `—` for this group: there is nothing to retry, and asking is a sign of a caller
treating a success as an error. `RouterCode.OK()` separates them.

### 11x — Upstream

The route was chosen and the backend failed. The router reached a decision; what happened next was not its doing.

| code | meaning | retry |
|---|---|---|
| `110` | upstream failed | failover |
| `111` | backend down | failover |
| `112` | backend not responding | failover |
| `113` | backend refusing | no |
| `114` | backend not allowed | no |
| `115` | backend name does not resolve | failover |
| `116` | backend TLS rejected | no |
| `117` | backend unreachable | failover |
| `118` | backend circuit open | failover |
| `119` | backend retry budget exhausted | failover |

This group is why the scheme exists. Every one of these was previously HTTP 502 `upstream_error/bad_gateway` with the reason in English inside the message, so *switched off*, *wedged* and *rejected our key* paged identically.

### 12x — Request

The request is malformed, oversized, or aimed at something this router does not serve.

| code | meaning | retry |
|---|---|---|
| `120` | request body unreadable | wait |
| `121` | request body is not valid JSON | no |
| `122` | format not allowed | no |
| `123` | required field missing | no |
| `124` | request body too large | no |
| `125` | unknown endpoint | no |
| `126` | method not allowed | no |
| `127` | parameter not supported | no |
| `128` | streaming not supported by this target | no |
| `129` | content encoding not supported | no |

Nothing here improves by waiting. The caller has to change the request.

### 13x — Auth

Who is asking, and whether they may.

| code | meaning | retry |
|---|---|---|
| `130` | no credential presented | no |
| `131` | invalid API key | no |
| `132` | API key disabled | no |
| `133` | model not allowed for this key | no |
| `134` | route token required | no |
| `135` | route token invalid | no |
| `136` | admin credential required | no |
| `137` | admin session expired | no |
| `138` | request signature missing or invalid | no |
| `139` | origin not allowed | no |

`130` and `131` are split deliberately: *sent nothing* is a client that was never configured, *sent the wrong thing* is a key that is wrong, disabled or revoked. Both are HTTP 401 and they are different tickets.

### 14x — Model

The model, the route that names it, and their limits.

| code | meaning | retry |
|---|---|---|
| `140` | model not found | no |
| `141` | model disabled | no |
| `142` | model has no usable target | no |
| `143` | model does not support this operation | no |
| `144` | context too large for the model | no |
| `145` | requested completion length too large for the model | no |
| `146` | model name is ambiguous | no |
| `147` | model retired upstream | no |
| `148` | model still loading | wait |
| `149` | model not present on the backend | no |

`144` is the most common recoverable failure in day-to-day use. Providers report it as prose in a 200 or a 400, so the router reads the message to recognise it — see `upstreamMessageCode`.

### 15x — Limits

Rate limiting, quota and capacity — here and at the provider.

| code | meaning | retry |
|---|---|---|
| `150` | too many failed authentication attempts | wait |
| `151` | client rate limited | wait |
| `152` | quota exhausted | no |
| `153` | backend rate limited | wait |
| `154` | too many concurrent requests | wait |
| `155` | backend account quota exhausted | no |
| `156` | spend limit reached | no |
| `157` | request queue full | wait |
| `158` | backend overloaded | wait |
| `159` | shed under backpressure | wait |

`152` vs `155`: a budget configured *in this router* against a budget on the *provider account*. And `153` vs `158`: rate limited is quota, overloaded is capacity. Different people fix them.

### 16x — Router

Faults in this process, rather than in the request or the backend.

| code | meaning | retry |
|---|---|---|
| `160` | internal router error | wait |
| `161` | configuration invalid | no |
| `162` | sealed secret could not be opened | no |
| `163` | router shutting down | wait |
| `164` | router not ready | wait |
| `165` | storage error | wait |
| `166` | required dependency not configured | no |
| `167` | API translation failed | no |
| `168` | backend response malformed | failover |
| `169` | routing loop | no |

If you are seeing these, the thing to read is this router's log, not the provider's status page.

### 17x — Stream

Failures after the response has started, where the status line is already sent.

| code | meaning | retry |
|---|---|---|
| `170` | stream interrupted | wait |
| `171` | backend closed the stream | failover |
| `172` | client disconnected | no |
| `173` | stream idle too long | failover |
| `174` | stream framing malformed | failover |
| `175` | backend sent an error mid-stream | failover |
| `176` | response cannot be flushed | no |
| `177` | stream translation failed | no |
| `178` | stream truncated | wait |
| `179` | budget exceeded mid-stream | no |

For these the **header is the only machine-readable channel** — the body is a token stream and the status was committed before the failure happened. `176` is worth knowing: it means something in front of the router buffers responses, so streaming will never work through that path however healthy everything else is.

### 18x — Content

Filters, refusals and jurisdiction — decided by the provider, not by this router.

| code | meaning | retry |
|---|---|---|
| `180` | prompt blocked by a content filter | no |
| `181` | completion blocked by a content filter | no |
| `182` | refused by provider policy | no |
| `183` | blocked for personal data | no |
| `184` | blocked for copyrighted material | no |
| `185` | not available in this region | no |
| `186` | provider terms violation | no |
| `187` | safety classifier failed | wait |
| `188` | moderation required first | no |
| `189` | output truncated by policy | no |

A refusal is a decision, not a fault. All of these default to no-retry: resending a refused prompt is how you get rate limited.

### 19x — Capability

The request asks for something the model or target cannot do.

| code | meaning | retry |
|---|---|---|
| `190` | tool calling not supported | failover |
| `191` | tool schema invalid | no |
| `192` | tool call malformed | no |
| `193` | JSON mode not supported | failover |
| `194` | response schema not supported | failover |
| `195` | modality not supported | failover |
| `196` | attachment too large | no |
| `197` | attachment format not supported | no |
| `198` | embeddings not supported | failover |
| `199` | batch requests not supported | failover |

Almost all of these advise **failover**: another target in the same route may have the capability this one lacks. That is the case where the retry column earns its keep.

## Using them

**In a client.** Read `X-LLMR-Code`, branch on the retry advice, log the number. Aggregate by group:
`c / 10` gives `11` for upstream, `15` for limits, and "how many 11x today" is a question about the
backends rather than about any one request.

**As an operator.** The router records the code on every request (`router_code` in the request log),
so *"show me every 112 in the last hour"* is answerable. It is not answerable from an HTTP status,
which is the whole point.

**Four worth alerting on specifically:**

- `106` sustained — every request is still succeeding, so nothing else will alert, but a backend is
  failing often enough that the router is retrying or failing over routinely. This is the one that
  catches a degrading provider before it becomes an outage.

- `113` — the router's credential for a provider has been rejected. Nothing will work through that
  backend until someone rotates a key, and no amount of retrying changes it.
- `176` — something in front of the router buffers responses. Streaming will not work through that
  path no matter how healthy the router and backends are.
- `158` sustained — the provider is at capacity rather than out of quota. Backoff is correct, but a
  sustained run means the failover targets are worth revisiting.
