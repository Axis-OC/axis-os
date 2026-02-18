## 7. Synapse Tokens (sMLTR)

### 7.1 What is sMLTR?

**Synapse Message Layer Token Randomization** (sMLTR) is AxisOS's handle authentication mechanism. Every process receives a unique, randomly-generated token at creation time. Every handle is bound to the process's synapse token. When a process attempts to use a handle, the kernel validates that the handle's token matches the caller's token.

### 7.2 Token Format

```
SYN-4a2b-c7e9-1f3d-8b5a
 │    │    │    │    │
 │    └────┴────┴────┘
 │    4 hex segments (mixed entropy)
 │
 └── Prefix identifier
```

Tokens are generated using a combination of:
- `raw_computer.uptime()` — wall-clock entropy
- `math.random()` — PRNG
- `g_nSynapseCounter` — monotonic counter
- Bit mixing across segments

### 7.3 Security Model

```
  Process A (SYN-aaaa-...)          Process B (SYN-bbbb-...)
  ┌─────────────────────┐          ┌─────────────────────┐
  │ Handle H-1234-...   │          │                     │
  │ (bound to SYN-aaaa) │          │ Tries to use H-1234 │
  └──────────┬──────────┘          └──────────┬──────────┘
             │                                │
             │ ob_reference_by_handle()       │ ob_reference_by_handle()
             ▼                                ▼
        ┌─────────┐                      ┌─────────┐
        │ MATCH ✓ │                      │ DENY ✗  │
        │ SYN-aaaa│                      │ SYN-bbbb│
        │ == aaaa │                      │ != aaaa │
        └─────────┘                      └─────────┘
```

### 7.4 Bypass Rules

- **PID < 20** — system processes bypass sMLTR validation (they are trusted kernel components).
- **Ring 0** — kernel always has full access.

### 7.5 Token Rotation

On privilege elevation (`su`), the synapse token is **rotated**:

```lua
-- In process_elevate syscall:
kernel.tProcessTable[nPid].synapseToken = fGenerateSynapseToken()
```

This invalidates all handles bound to the old token, forcing re-acquisition.

---