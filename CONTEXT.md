# WireProxy Toolkit

This context names the user-facing concepts for managing scoped, user-space WireGuard proxy access for coding-agent command-line tools.

## Language

**Toolkit**:
The public, provider-neutral product that installs and manages user-space WireGuard proxy access for selected commands. Its first supported product boundary is Linux.
_Avoid_: WireProxy setup, Mullvad setup

**Tunnel Profile**:
A named local WireGuard configuration together with its toolkit settings and generated proxy configuration. It is not a person, provider account, login, or subscription.
_Avoid_: User Profile, account, relay

**Default Tunnel Profile**:
The Tunnel Profile selected when a Wrapped command does not explicitly name one. A user chooses it; the toolkit does not infer it from activity or creation order.
_Avoid_: Active Profile, primary tunnel

**Active Tunnel Profile**:
The one Tunnel Profile whose WireProxy process is currently running. Linux v1 permits at most one Active Tunnel Profile at a time.
_Avoid_: Logged-in Profile, user session

**Proxy credential**:
A fixed, nonempty proxy username paired with a generated URL-safe password stored privately with one Tunnel Profile and used by its local HTTP listener. It is proxy authentication material, not a provider login.
_Avoid_: Activation credential, Profile password, proxy login, provider password

**Wrapped command**:
A command launched with proxy environment variables scoped to that command and its descendants.
_Avoid_: Proxied shell, global proxy
