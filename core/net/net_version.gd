class_name NetVersion
extends RefCounted

## Protocol/build version handshake — docs/ARCHITECTURE.md §2.2, task 1.11.
##
## The problem this exists to prevent: two builds that disagree about the wire format (a replicated
## property added/removed/reordered, an RPC signature change, a SceneReplicationConfig change) do not
## fail loudly. They connect fine at the ENet/Steam layer — that handshake only agrees on transport,
## never on payload shape — and then desync silently: wrong values read off the wire, or a client that
## quietly drops every packet from the mismatched peer. That failure mode is expensive to diagnose,
## because everything upstream of it (host(), join(), connected_to_host) reports success.
##
## Constants only, deliberately — same reasoning as NetConfig: this has to be byte-identical in the
## host process and every client process, so nothing here should be able to branch or drift.
##
## Network authority (§2.2): none of its own — this is infrastructure, not simulated state. The one
## authority fact worth stating: the HOST is the arbiter. A client never rejects the host for running a
## different version; it only ever reports itself and accepts whatever the host decides, because the
## host is what the rest of §2.2's table already trusts to be right.


## Bump this whenever a change would desync two builds without either side noticing on its own:
##   · a replicated property added, removed, reordered, or its REPLICATION_MODE changed
##   · an RPC's name, argument order, or @rpc config (any_peer/authority, reliable/unreliable) changed
##   · SceneReplicationConfig itself changed for any synced node
## Bump it even when nothing else about the release changed — a stale peer must never connect to a
## maintained one and desync instead of being told to update. There is no compatibility window: this
## project ships from source control, not distributed binaries with staggered rollout, so "N and N+1
## interoperate" is a guarantee nobody needs and nobody should spend effort keeping true.
const PROTOCOL_VERSION: int = 1

## Wire-format tag for the client→host hello RPC, kept separate from the reason string format so a
## mismatch renders identically everywhere it's read (a log line, a UI error, a check-tool assertion).
const _MISMATCH_FMT: String = "protocol mismatch: host is v%d, you are v%d — update your build"


## Pure — no node, no network, so it is testable without a session and reusable by whichever side ends
## up owning the RPC (see the drop-in note in docs/DELEGATION.md for where that lands). Returns "" when
## the versions agree, or a reason string ready to hand to a rejected client otherwise.
static func mismatch_reason(local_version: int, remote_version: int) -> String:
	if local_version == remote_version:
		return ""
	return _MISMATCH_FMT % [local_version, remote_version]
