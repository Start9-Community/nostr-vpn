# Nostr VPN

## Documentation

- [Nostr VPN project & docs](https://github.com/mmalmi/nostr-vpn) — the upstream
  repository, overview, and protocol notes for the underlying mesh VPN.
- [Client app downloads](https://github.com/mmalmi/nostr-vpn/releases/latest) —
  the native apps and CLI you install on each device that joins the network.

## What you get on StartOS

Your server becomes the always-on node of the network: it hosts the mesh and is
where you administer it, while phones and laptops join as peers. The control
panel is where you create the network and link devices as they ask to join.

Two things commonly catch people out. Your **other devices do not connect with a
generic WireGuard client** — Nostr VPN has its own apps, covered below. And the
server node starts **idle**: it holds a network but carries no traffic until you
activate one.

## Getting set up

1. On first install, the service shows a required task, **Set Control Panel
   Password**. Run it. StartOS generates a strong password and shows it to you
   once — copy it somewhere safe. The username is `admin`.
2. Open the **Control Panel** and sign in with `admin` and the password from
   step 1.
3. Click **Create Network** to make your server the first node in its own mesh,
   then **Activate** it so it starts carrying traffic (the daemon starts idle
   until a network is active).

## Connecting clients

Each device that joins the network runs the Nostr VPN client for its platform —
not a WireGuard app. The high-level flow is the same on every platform:

1. **Install the client** on the device from the
   [releases page](https://github.com/mmalmi/nostr-vpn/releases/latest). Native
   apps are available for macOS, Linux, Windows, and Android; iOS is in
   TestFlight (public access still pending); and a headless `nvpn` CLI is
   available (`cargo install nvpn`).
2. **Open the app.** On first launch it generates the device's own Nostr identity
   automatically — there is nothing to copy from the server for this step.
3. **Produce a join request on the device.** In the client, add a network and
   choose **Join Network**. It shows a QR code and a **Copy Request** button —
   this is the device asking to join, so it travels from the device to your
   server, not the other way round.
4. **Link it on the server.** Back in the StartOS control panel, open your
   network, choose **Add Device**, and paste the request into **Link Device**.
   Once linked, the device is on the mesh and can reach the other peers.

If the two can't easily exchange that request, use **Manual join** instead: each
side copies its own **Device ID**, you give the device your Device ID and the
**Network ID** from **For Manual Join**, and you add its Device ID under **Add by
Device ID**. Both halves are required — the device is not on the mesh until each
side has the other's ID.

For platform-specific app details (exit nodes, MagicDNS), follow the upstream
[Nostr VPN documentation](https://github.com/mmalmi/nostr-vpn).

## Using Nostr VPN

### Control panel

The control panel is your home base for administering the network: create and
name networks, activate the one in use, view connected peers and their status,
and link or remove devices. Sign in with `admin` and the password you set above.

### Actions

- **Set Control Panel Password** — generates a new random password for the control
  panel and displays it once. Run it whenever you want to rotate the credential; the new
  password takes effect immediately.
