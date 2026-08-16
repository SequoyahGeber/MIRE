class_name NetConfig
extends RefCounted

## Transport configuration for [NetTransport] — docs/ARCHITECTURE.md §2.3.
##
## Constants only, deliberately. Every value here has to be byte-identical in the host process and in
## every client process; the cheapest way to guarantee that is to have nothing in the file that could
## branch. If you find yourself wanting a function here, it belongs in NetTransport.
##
## Network authority (§2.2): none. This is a compile-time table, not state. It is never replicated
## because there is nothing to replicate — both sides already have it.


## Which wire we are on. NetTransport.current_mode() returns one of these.
enum Mode {
	OFFLINE = 0,  ## No session. Resting state, and what current_mode() returns after leave().
	LOCAL = 1,    ## ENetMultiplayerPeer on loopback. The daily dev loop: two windows, one machine.
	LAN = 2,      ## ENetMultiplayerPeer on a routable address. A second physical machine.
	STEAM = 3,    ## SteamMultiplayerPeer via GodotSteam. Real play with friends, and shipping.
}

## Indexed by Mode. A table rather than a match statement so this file stays logic-free.
const MODE_NAMES: PackedStringArray = ["OFFLINE", "LOCAL", "LAN", "STEAM"]

# ── Addressing ────────────────────────────────────────────────────────────────────────────────────

## Deliberately not 27015: that is the Source/Steam dedicated-server default, and the Steam client
## will be running on the dev machine for the whole of M1. Registered range, no common service on it.
const DEFAULT_PORT: int = 27515

const LOOPBACK_ADDRESS: String = "127.0.0.1"

## ENet's "bind to every interface". LAN hosts use this; LOCAL hosts deliberately do not.
const ANY_ADDRESS: String = "*"

const PORT_MIN: int = 1024
const PORT_MAX: int = 65535

# ── Session size ──────────────────────────────────────────────────────────────────────────────────

## DESIGN.md: 3–6 players.
const MAX_PLAYERS: int = 6

## What ENetMultiplayerPeer.create_server() wants — it counts clients, and the host is not one.
const MAX_CLIENTS: int = MAX_PLAYERS - 1

## Godot reserves peer id 1 for the server in every transport, including Steam.
const HOST_PEER_ID: int = 1

# ── Timeouts ──────────────────────────────────────────────────────────────────────────────────────

## How long join() waits for a handshake before giving up. ENet's own failure detection is slow and
## inconsistent across platforms, so NetTransport enforces this itself.
const CONNECT_TIMEOUT_SEC: float = 10.0

## Loopback either answers immediately or is not there at all. Failing fast is the difference between
## a 3-second dev loop and a 13-second one, and you hit this path every time you forget to start the
## host window first.
const LOCAL_CONNECT_TIMEOUT_SEC: float = 3.0

# ── Steam (task 1.4 consumes these; nothing references them until GodotSteam is installed) ─────────

## Valve's public test app (Spacewar). Lobbies and P2P work for anyone with a Steam account, without
## buying an App ID. Replaced by the real one at M7 — §2.4 says that must stay a one-line change.
const STEAM_APP_ID: int = 480

## Looked up through ClassDB / Engine by name so this project compiles with the addon absent.
const STEAM_PEER_CLASS: StringName = &"SteamMultiplayerPeer"
const STEAM_SINGLETON: StringName = &"Steam"

## SteamNetworkingMessages channel. 0 unless we ever run two sessions from one process.
const STEAM_VIRTUAL_PORT: int = 0

# ── Logging ───────────────────────────────────────────────────────────────────────────────────────

## MireLog channel. `log net off` in the debug console silences everything below WARN.
const LOG_CHANNEL: StringName = &"net"
