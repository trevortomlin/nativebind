# nativebind wire format (ABI version 2)

All integers are little-endian. Strings are UTF-8 with a `u32` byte length.

## Values

Every value starts with a one-byte tag.

| Tag | Name | Payload | C++ types |
|---|---|---|---|
| 0 | Void | — | method returning `void` |
| 1 | Bool | `u8` 0/1 | `bool` |
| 2 | Int | `i64` | all integer types (range-checked when decoded) |
| 3 | Double | `f64` | `float`, `double` (an Int is accepted when decoding) |
| 4 | String | `u32` length + bytes | `std::string` |
| 5 | Enum | `i32` | any `enum` / `enum class` |
| 6 | Struct | `u16` field count + field values in declaration order | structs (codec generated) |
| 7 | List | `u32` count + values | `std::vector<T>` |
| 8 | None | — | empty `std::optional<T>` (a present optional is just its value) |
| 9 | Time | `i64` µs since the Unix epoch, UTC | `std::chrono::system_clock::time_point` |
| 10 | Duration | `i64` µs | `std::chrono::duration` |

## Calls from Dart

| Function | Payload |
|---|---|
| `nativebind_write(instance, prop, value, len, seq)` | exactly one value |
| `nativebind_invoke(instance, method, args, len, call_id)` | the arguments, back to back, in declaration order |

Property, list, signal and method indexes are declaration order within the
module class (each kind counted separately). The generator emits the same
order on both sides, and the runtime verifies the property list when a module
is adopted.

## Change feed

`nativebind_drain` returns a sequence of records:

```
u8 kind | u32 payload length | payload
```

Consumers must skip unknown kinds using the length.

Within one drain, records are ordered: (Resync + full state, then the Signal
records queued meanwhile) **or** (queued events in order, then Meta records,
then Prop records), followed by Result records. Apply the whole batch before running signal handlers so that
handlers see the latest values.

| Kind | Name | Payload |
|---|---|---|
| 1 | Resync | — Forget all instances; the full state follows. |
| 2 | InstanceAdded | `u32 instance, u16 type, u64 key`. Idempotent. |
| 3 | InstanceRemoved | `u32 instance`. Ignore if unknown. |
| 4 | Prop | `u32 instance, u16 prop, u32 ackSeq, value` |
| 5 | Meta | `u32 instance, u16 prop, f64 min, f64 max, f64 step, u8 flags, string label, u16 attrCount, (string key, value)…` |
| 6 | ListReset | `u32 instance, u16 list, u32 version, u32 count, values…` |
| 7 | ListInsert | `u32 instance, u16 list, u32 version, u32 index, value` |
| 8 | ListRemove | `u32 instance, u16 list, u32 version, u32 index, u32 count` |
| 9 | ListUpdate | `u32 instance, u16 list, u32 version, u32 index, value` |
| 10 | ListMove | `u32 instance, u16 list, u32 version, u32 from, u32 to` (remove at `from`, insert at `to`) |
| 11 | Signal | `u32 instance, u16 signal, u8 argc, values…` |
| 12 | Result | `u32 callId, i32 status`, then a value if status is 0, else a string error message |

Meta `flags`: bit 0 writable, bit 1 enabled. The attributes are
`nativebind::Meta::attrs` in declaration order; each value is a tagged bool,
int (enums arrive as their integer value), double or string. nativebind does
not interpret them; libraries built on it (e.g. display units or
access requirements) do.

ABI version 2: Meta gained attributes and lost decimals/unit/access/confirm;
Prop lost the quality byte.

### Rules for consumers

- **Props** carry the latest value (coalesced). After a UI write with sequence
  number `s`, keep showing the optimistic value until a Prop record arrives
  with `ackSeq >= s`. The runtime always echoes a processed write, even a
  rejected one, so the UI reverts.
- **Lists**: apply an operation only if `version == known + 1`. Ignore
  `version <= known` (already contained in a reset). A larger version is a gap:
  call `nativebind_request_resync()`.
- **Wake-ups**: the runtime posts an integer to the attached port once per
  batch (not per change). Drain on wake; the runtime wakes again after the
  next change.
- **Attach** (`nativebind_attach_port`) drops queued events and results and
  makes the next drain a Resync. Call it on every isolate start, including
  hot restarts.
- **Signals** are queued only while a consumer is attached. A Resync
  supersedes queued state records but not signals: those emitted before it
  is drained (e.g. in `onStart`) follow the full state.
- If the consumer stops draining and more than 4 MB of events queue up, the
  queue, signals included, is dropped and the next drain is a Resync.
