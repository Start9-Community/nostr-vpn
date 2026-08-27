# Nostr VPN

## Documentation

- [Nostr VPN README](https://github.com/mmalmi/nostr-vpn) — the upstream
  overview, the per-platform app status, and the download links for every client.
- [Protocol reference](https://github.com/mmalmi/nostr-vpn/blob/master/docs/protocol.md) —
  how join requests, roster sync, and the encrypted mesh work.

## What you get on StartOS

Your server becomes the always-on hub of a private network you own. It holds the
network and is where you administer it; your phones and laptops join it as peers,
and once they have, they can reach each other from anywhere.

Two things commonly catch people out, so read them before you start:

- **Your devices do not connect with a generic WireGuard app.** Nostr VPN has its
  own apps, and only those can join. There is no WireGuard config file to export.
- **The server starts idle.** Its private network is set up for you on first
  run, but it carries no traffic until you switch the VPN on.

## Getting set up

1. Run the required task, **Set Control Panel Password**. StartOS generates a
   strong password and shows it to you **once** — copy it somewhere safe before
   you close the window. Your username is `admin`.
2. Open the **Control Panel** and sign in as `admin` with that password.
3. Switch **VPN** on, using the toggle in the panel header.

That is the whole setup. Your server already has a private network of its own —
called **Network 1**, created for you on first run — and it is already the
network's administrator, so it is ready for devices to join.

Worth one more minute: your server names itself with a random string of letters,
and every device you add will see that name in its device list. On the
**Settings** tab, under **This Device**, put something recognisable in **Name**
(`home-server`, say) and click **Save settings**.

## Connecting your devices

Every device runs the Nostr VPN app for its platform. The request to join always
travels **from the device to your server** — you are not sending out an invite
link, you are approving devices that ask.

Do these three steps once per device.

### 1. Install the app on the device

| Device              | Get it from                                                                                |
| ------------------- | ------------------------------------------------------------------------------------------ |
| iPhone or iPad      | [the App Store](https://apps.apple.com/app/nostr-vpn/id6785410348)                         |
| Android phone       | the signed APK on the [releases page](https://github.com/mmalmi/nostr-vpn/releases/latest) |
| Mac (Apple Silicon) | the macOS app on the [releases page](https://github.com/mmalmi/nostr-vpn/releases/latest)  |
| Windows PC          | the installer on the [releases page](https://github.com/mmalmi/nostr-vpn/releases/latest)  |
| Linux desktop       | the `.deb` on the [releases page](https://github.com/mmalmi/nostr-vpn/releases/latest)     |

There is also a command-line client for a server or a headless machine, installed
with `cargo install nvpn`. Intel Macs are not covered by a prebuilt app.

### 2. Ask to join, from the device

Open the app. On first launch it creates that device's own identity — there is
nothing to copy from your server for this step.

Add a network and choose **Join Network**. The app shows a QR code and a **Copy
Request** button. That is the device asking to join, and it is what your server
needs next. Leave the app on this screen.

### 3. Approve it, from the server

Back in the control panel, on the **Devices** tab:

1. Click **Add Device**.
2. Paste the device's request into the **Join request** box under **Link Device**.
   (If the device showed a QR code, scan it with the device you have the panel
   open on, or use **Copy Request** and paste it across however you normally move
   text between your machines.)
3. A confirmation appears — click **Add**.

The device shows up in the **Devices** list. Give it a moment and it comes online.

### If the device can't send you its request

Some pairs of devices have no easy way to pass a block of text between them. Use
**Manual join** instead, where each side is given the other's ID by hand. Both
halves are required — the device is not on the network until your server has its
ID _and_ it has your server's.

1. **On the server:** click **Add Device**, and under **For Manual Join** copy
   both **Your Device ID** and the **Network ID**.
2. **On the device:** choose **Join Network**, then **Manual join**. Enter the two
   values from step 1, click **Add manually**, and copy the device's own
   **Device ID** from the same screen.
3. **On the server:** under **Add Device → Add by Device ID**, paste the device's
   ID, optionally give it a name, and click **Add**.

## Using Nostr VPN

### Control panel

The control panel is where you administer the network: create and rename
networks, activate the one in use, watch which devices are online, and add or
remove them. Sign in as `admin` with the password you set.

The **Exit Nodes** tab is where you would route a device's whole internet
connection through another peer. See the upstream README for how exit nodes and
MagicDNS work.

### Actions

- **Set Control Panel Password** — generates a new random password and shows it
  once. Run it whenever you want to change the password. The new one takes effect
  immediately, and anyone signed in with the old one is locked out.

## Limitations

- **The VPN switch does not survive a restart.** Whenever the service restarts —
  after an update, a reboot, or a manual stop — the network stays configured but
  the VPN comes back **off**, and you have to switch it on again in the control
  panel. Settings' **Start VPN automatically** has no effect here.
