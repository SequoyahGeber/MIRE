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

## Steam's own budget, separate from ENet's because it is a different mechanism, not a slower one.
## An ENet client already knows where it is going: create_client() is a couple of round trips to a
## machine we can name. A Steam client has to be rendezvoused instead — SteamNetworkingSockets tries
## direct NAT traversal first and falls back to Valve's relay network, and the fallback is where the
## tail sits. F-023 watched a Windows first join miss the shared 10 s deadline twice and then connect
## immediately on a retry, which is the signature of a rendezvous still in progress rather than of a
## host that is not there.
##
## PROVISIONAL — this is an allowance, not a measurement. No first-join latency had ever been recorded
## when it was chosen. [method NetTransport.last_connect_msec] now records one on every successful
## join, so task 1.12's next run produces the real distribution across all three platforms; set this
## from the observed tail then, and say in the commit what the tail was.
const STEAM_CONNECT_TIMEOUT_SEC: float = 20.0

# ── Steam (task 1.4 consumes these; nothing references them until GodotSteam is installed) ─────────

## Valve's public test app (Spacewar). Lobbies and P2P work for anyone with a Steam account, without
## buying an App ID. Replaced by the real one at M7 — §2.4 says that must stay a one-line change.
const STEAM_APP_ID: int = 480

## Looked up through ClassDB / Engine by name so this project compiles with the addon absent.
const STEAM_PEER_CLASS: StringName = &"SteamMultiplayerPeer"
const STEAM_SINGLETON: StringName = &"Steam"

## SteamNetworkingMessages channel. 0 unless we ever run two sessions from one process.
const STEAM_VIRTUAL_PORT: int = 0

# Values below are Steamworks' own, read off the INSTALLED GodotSteam 4.21 build rather than from
# documentation (D-022 pins that build). They are mirrored here so nothing outside the Steam seam has
# to reference the `Steam` singleton — a file that names Steam directly stops parsing when the addon
# is absent, which is the whole reason NetTransport goes through ClassDB.

## ELobbyType.k_ELobbyTypeFriendsOnly. Never PUBLIC: App ID 480's public list is worldwide junk, and
## STEAM.md §2 is explicit that we join by invite or lobby id only.
const STEAM_LOBBY_TYPE_FRIENDS_ONLY: int = 1

## EResult.k_EResultOK. Note it is 1, not 0 — Steam's success value is not C's.
const STEAM_RESULT_OK: int = 1

## EAccountType.k_EAccountTypeChat. Lobby ids carry this in bits 52-55; a player's id carries
## k_EAccountTypeIndividual (1) instead. That is how one 64-bit number tells us which it is.
const STEAM_ACCOUNT_TYPE_CHAT: int = 8
const STEAM_ACCOUNT_TYPE_SHIFT: int = 52
const STEAM_ACCOUNT_TYPE_MASK: int = 0xF

## Lobby metadata. Set by the host, readable by anyone who can see the lobby — a joiner checks this
## before connecting so a stray App ID 480 lobby from another developer fails fast and legibly.
const STEAM_LOBBY_KEY_GAME: String = "game"
const STEAM_LOBBY_GAME_VALUE: String = "mire"
const STEAM_LOBBY_KEY_HOST: String = "host"

## createLobby and joinLobby answer by callback with no failure timeout of their own. If Steam never
## calls back — offline, logged out mid-call — this is when we give up and say so.
const STEAM_LOBBY_TIMEOUT_SEC: float = 15.0

## Steam appends this to the launch arguments when a friend's invite is accepted while the game is
## closed: `+connect_lobby <lobby_id>`. The running-game case arrives as a signal instead.
const STEAM_CONNECT_LOBBY_ARG: String = "+connect_lobby"

# ── Replication: players (task 1.5) ───────────────────────────────────────────────────────────────

# Node names under the PlayerNet autoload. The high-level multiplayer API matches nodes by path, so
# host and client must arrive at identical names — they are named once, here, rather than spelled out
# at each construction site (D-023).

## Container every networked player is spawned into: /root/PlayerNet/Players.
const PLAYER_CONTAINER_NODE: StringName = &"Players"

## The MultiplayerSpawner itself: /root/PlayerNet/PlayerSpawner.
const PLAYER_SPAWNER_NODE: StringName = &"PlayerSpawner"

## The MultiplayerSynchronizer PlayerController builds as its own child.
const PLAYER_SYNC_NODE: StringName = &"NetSync"

## CONVENTION (F-013): every MultiplayerSynchronizer this project builds joins this group, and
## nothing else does. One synchronizer, one member — so the debug panel's "synced" line counts what
## actually costs bandwidth rather than how many entities happen to exist. An entity carrying two
## synchronizers is two, correctly: it sends twice. Added at construction, alongside the authority
## the synchronizer is built with, so a site that builds one cannot forget.
const SYNCED_GROUP: StringName = &"synced"

## §2.5: players replicate at 30Hz.
const PLAYER_SYNC_HZ: float = 30.0
const PLAYER_SYNC_INTERVAL_SEC: float = 1.0 / PLAYER_SYNC_HZ

# ── Replication: interest management (task 1.8, §2.5) ─────────────────────────────────────────────
#
# The per-class table §2.5 asks for. NetInterest.configure() is what reads it — these are the numbers,
# core/net/net_interest.gd is the mechanism. They live here because every value below has to be
# byte-identical in the host process and in every client process: a client whose enter radius differs
# from the host's would disagree about which entities it should have, and disagree silently.
#
# What 1.9 measured, so the next person does not have to re-derive the budget: unfiltered 30Hz cost
# 918 KB/s host-up against a 125 KB/s ceiling; the same load with these filters on cost 105 KB/s at
# 30Hz and 57 KB/s at 15Hz. Filtering is what makes M1 fit — see docs/DELEGATION.md.

## Enemies: half the player rate. They are host-simulated and there are more of them, and 15Hz plus
## interpolation (1.6) is indistinguishable from 30Hz on something that is not under your own hand.
const ENEMY_SYNC_HZ: float = 15.0
const ENEMY_SYNC_INTERVAL_SEC: float = 1.0 / ENEMY_SYNC_HZ

## Props and containers: "on-change only" (§2.5) is a property-mode decision — every property on a
## prop is REPLICATION_MODE_ON_CHANGE, so nothing is sent while nothing changes and the interval below
## never fires. It is set to a full second anyway, deliberately: if someone later adds an ALWAYS
## property to a prop by mistake, the cost of the mistake is 1Hz rather than every frame (which is
## what an interval of 0.0 means to the engine).
const PROP_SYNC_INTERVAL_SEC: float = 1.0

## How often a synchronizer CHECKS its on-change properties. 10Hz: a chopped tree or an opened
## container reaches every player within 100 ms, which is imperceptible for a state change, and the
## check costs nothing when the answer is "unchanged".
const PROP_DELTA_INTERVAL_SEC: float = 0.1

## §2.5's ~120 m, as the radius at which an entity BECOMES visible to a peer.
const INTEREST_ENTER_RADIUS_M: float = 120.0

## And the larger radius at which it stops being visible again. The gap is hysteresis, and it is not
## cosmetic: losing visibility despawns the entity on that client and regaining it respawns it, so an
## entity sitting exactly on a single radius flaps a despawn+respawn per peer per evaluation. 1.9 saw
## the bill for that — clustered players measured CHEAPER (100 KB/s) than spread ones (180 KB/s) at an
## identical 11.6% visible fraction, with the difference falling on the reliable channel, which is
## where spawn traffic lives. 20% of the enter radius is 24 m: two players closing on each other at
## sprint speed take ~2 s to cross it, so the worst case is one transition every couple of seconds
## instead of one every physics tick.
const INTEREST_LEAVE_RADIUS_M: float = 144.0

# ── Host speed sanity check (§2.2 row 1) ──────────────────────────────────────────────────────────

## How often the host measures a remote player's implied speed. Well below the sync rate, so each
## sample spans several replicated positions and a single dropped packet cannot inflate one.
const SPEED_CHECK_INTERVAL_SEC: float = 0.25

## Multiple of sprint_speed that counts as impossible. Generous on purpose: slopes, stairs and
## knockback all move a player faster than sprint_speed legitimately.
const SPEED_CHECK_TOLERANCE: float = 1.8

## Consecutive over-limit samples before we say anything. One sample is a lag spike or a teleport;
## four in a row is a second of sustained impossible movement.
const SPEED_CHECK_STRIKES: int = 4

# ── Logging ───────────────────────────────────────────────────────────────────────────────────────

## MireLog channel. `log net off` in the debug console silences everything below WARN.
const LOG_CHANNEL: StringName = &"net"
