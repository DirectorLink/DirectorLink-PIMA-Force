# DirectorLink · PIMA FORCE for Control4

Free, open-source Control4 driver for **PIMA FORCE** alarm panels (FORCE, FORCE 32C, FORCE 16). Part of [DirectorLink Drivers](https://directorlink.io/drivers).

It works on your local network: the panel connects to the driver on the controller the way it connects to a monitoring station, with PIMA's local **JSON interface** (PIMA's *Force Interface JSON Format Specification* v2.4). No cloud, no extra hardware and no subscription.

Free. No subscription, no license key, no account with us.

Made by [DirectorLink](https://directorlink.io), the open-source management layer for Control4 homes. Works on its own: DirectorLink is not required.

DirectorLink is an independent project, not affiliated with Control4, Snap One or PIMA.

**Download:** [releases](../../releases) · **Help and updates:** [directorlink.io/drivers/pima-force](https://directorlink.io/drivers/pima-force)

> **Tested on a FORCE 32C** in Israel:
> - **Firmware 3.0.19 with the JSON interface:** the driver reads the panel (24 zones, the exit time), and DirectorLink 1.15.0 armed it Away and disarmed it with a typed code.
> - **Firmware 1.5.1, receive only:** arming, disarming and the partition's state reach Control4.
>
> Reports from other panels and firmware are welcome: see [Support](#support).

## What you get

In Composer the driver adds a **Security Panel** and four **partitions** (Control4's standard security proxies), so every Control4 app shows the alarm.

| Feature | With the JSON interface | Receive only (no JSON in the firmware) |
|---|---|---|
| Armed (Away, Home, Night, Shabbat), disarmed, exit delay | Yes | Armed and disarmed, from the panel's reports |
| Arm and disarm from Control4 | Yes: Away = Full arm, Home = Home 1, Night = Home 2, Shabbat = Shabbat arming. Disarming needs a typed code | No |
| Alarms (burglary, fire, gas, water, panic, medical, duress) | Yes | Yes |
| Troubles (AC loss, low battery, tamper, communication) | Yes, from the panel's fault list | Yes, from its reports |
| Zones open and closed | Yes, live, with the names in the panel (Hebrew too); kept from Control4 while armed for [Shabbat](#shabbat) | When the panel reports them; names set in Composer |
| Bypass, outputs 1-8 | Yes | No |
| Programming events | Communication Lost / Restored, Siren Active / Inactive, Access Denied, and the partitions' own | The same |

Each zone also has a **Zone N** contact connection: bind a Control4 contact driver (Door Contact, Motion Sensor...) to use the zone in rooms and programming.

PIMA's interface has no command to raise panic, fire or medical alarms, so those buttons are not offered.

## Requirements

- **Control4 OS 3.0.0 or newer** and Composer Pro.
- **A PIMA FORCE panel** on the home network, with a free monitoring-station path (CMS 1, 2 or 3; never one a monitoring company uses).
- **For full control:** panel firmware with the JSON interface (tested with 3.0.19). PIMA's guide says it is a special firmware, not the standard one: see [Panel firmware](#panel-firmware). Older firmware works in [receive-only mode](#receive-only-mode).
- The panel reaches the controller on the driver's **Listen Port** (7780 by default). The panel dials out; it opens no port of its own. Give the controller a fixed IP address.
- Your **master code** (or the panel's **Smart Home code**) and the **installer code**.

## Panel firmware

Check whether the panel has the JSON interface: on the keypad, **press and hold 0** (system information).
- **FW** is the firmware version.
- A firmware with JSON names the system **HAC Force** (FORCE 32/32C, 32 zones) or **HA1 Force** (FORCE, 144 zones).
- **IP** must be a real address, not 0.0.0.0; otherwise check the panel's Ethernet cable.

Without JSON, ask PIMA support (support-il@pima-alarms.com, 03-6506411) or your installer to upgrade the panel to the firmware with the JSON (smart-home) interface. PIMA's own guide: *FORCE JOSE configuration Guide* (Hebrew) in [PIMA's download center](https://www.pima-alarms.com/download/).

## Setup

### 1. On the panel: the JSON path to the controller (installer code)

These are the steps of PIMA's JSON configuration guide, with the menu names of PIMA's English guides.

1. **Enter the installer menu:** press and hold the **Exit** key (↶), then type the **installer code**.
2. **Events to report:** System Programming → CMS & Communication → Monitoring Stations → **CMS 1** → Event Reporting.
   Use CMS 2 or 3 if a monitoring company already uses CMS 1. Go to the **fourth screen** and mark **Zone/Output Change**. Without it, zones opening and closing don't reach Control4.
3. *(Optional)* **CMS name:** name the station "Smart home", so that a communication trouble on the keypad says what it is about.
4. **Account number:** … → CMS 1 → Comm. Paths → **Network (Ethernet)** → Account Number. PIMA's guide uses **9999**; any number works, because the driver learns it. Set it for every partition in use.
5. **Address:** … → Network (Ethernet) → Network Addresses: **URL/IP 1** = the controller's IP address, **PORT 1** = **7780** (the driver's Listen Port).
6. **Protocol:** the second screen of Network (Ethernet):
   - **Protocol: JSON**.
   - Mark **Disable Encryption**: the driver reads only unencrypted messages.
   - Turn the **life signal** on.
7. **Remote disarm:** back to CMS & Communication → **General Settings** → mark **Remote Disarm**. Without it the panel refuses disarming from Control4 and DirectorLink.
8. Press Exit until the status screen.

The panel connects to the controller at its next report or life signal (within a few minutes), and reports **Panel programming changed** when you leave the installer menu.

### 2. In Composer

1. **Driver → Add or Update Driver or Agent** → `DirectorLink-PIMA-Force.c4z`. Add **DirectorLink · PIMA FORCE** to a room.
2. Set the properties:
   - **Account ID:** leave it empty. The driver takes the account from the panel's first message and fills it in; after that, messages with any other account are refused.
   - **Panel User Code:** the master code or the **Smart Home code**, never the installer code. With JSON the driver needs it to read zones, names and the partitions' state. It is also used for Composer's programming, for arming from Navigator when **Require Code To Arm** is No, and for bypass and outputs.
   - **Panel IP Address:** the panel's address, so that connections from anywhere else are refused.
   - **Partitions In Use** and **Partition N Zones** (for example `1-8,12`, or `all`).
   - **Link Timeout (s):** longer than the panel's life signal interval (300 by default).
3. Watch **Connection Status**:
   - **With JSON** it ends at `Connected to <the panel's address>`, and **Panel Info** reads `panel <address>, account <n>, <zones> zones, exit time <s> s`. Zones and their names load by themselves.
   - `Receive only (SIA DC-09): ...` means the path is not on JSON yet.
   - `Connected - set 'Panel User Code'` means the code is missing.

The Documentation tab in Composer covers every property, the behaviour and troubleshooting.

### 3. In DirectorLink (optional)

1. In DirectorLink's Composer properties, set **Alarm Status** to **On**: the app shows each partition's state on Home, and the home's TV screens tell when the alarm goes off.
2. To arm and disarm from the app (DirectorLink 1.15.0 and later), set **Alarm Control** to **On**. Admins can then arm and disarm; for a member, turn on **Arms and disarms the alarm** in the app's Settings → Users.
3. In the app, Home's alarm card shows **Arm** (Away, Home, Night, Shabbat) and **Disarm**. Each asks for your alarm code, which goes to the panel as typed and is checked there.

If the card says the alarm can't be armed or disarmed from DirectorLink right now, the panel isn't on JSON (receive only) or isn't connected. Composer shows it in the driver's variable `DIRECTORLINK_ALARM_CONTROL`, which is `1` when arming can work.

## Shabbat

PIMA sells the FORCE in Israel as a "Shabbat and holiday system", approved by the Zomet Institute. On such a panel a long press on **1** arms the **Shabbat** mode, which the installer sets up: only some zones are armed (for example the entrance), so that the family lives in the house as usual. PIMA's guide does not describe the mode further.

- **Arming for Shabbat:** the driver offers **Shabbat** next to Away, Home and Night, in Navigator and in DirectorLink. It is PIMA's own Shabbat arming. A panel that is not a Shabbat system refuses it (Last Panel Error).
- **Zones kept from Control4:** while a partition is armed for Shabbat, its zones opening and closing are not passed to Control4: not the contact connections, not the panel's or the partition's zone lists. People moving in the house cause nothing in Control4's programming. An alarm is still reported. Once the partition is no longer armed for Shabbat, every zone is reported as it is then.
- **Before Shabbat, not during it:** the Zomet Institute's guidance allows arming before Shabbat, or by a timer set before it. Arming and disarming by hand during Shabbat are not allowed.

## Receive-only mode

FORCE firmware without the JSON interface (like 1.5.1) can still report to the driver with its normal monitoring protocol, **SIA DC-09** (Contact-ID or SIA codes, encryption off). The driver detects it, acknowledges every report, and shows arming, disarming, alarms, troubles and zones opening and closing in Control4. It can't arm, disarm, bypass or read zone names. The partition's state is unknown until the panel's first arm or disarm report. When JSON firmware arrives, set the CMS path to JSON ([Setup](#1-on-the-panel-the-json-path-to-the-controller-installer-code), step 6): the driver switches to full control by itself.

## With DirectorLink

The partitions are Control4's standard ones, so DirectorLink shows them like any Control4 alarm ([setup](#3-in-directorlink-optional)). The driver also follows DirectorLink's alarm agreement, version 1:

- `DIRECTORLINK_ALARM` = `1`, written on every start.
- `DIRECTORLINK_ALARM_CONTROL` = `1` while arming and disarming can work (the JSON interface connected), `0` in receive-only mode or without a panel connection. DirectorLink offers Arm and Disarm only while it says `1`.
- An arm or disarm from DirectorLink (InterfaceID `DirectorLink`) needs a typed code, which goes to the panel as typed, and is never carried out with Panel User Code.
- `DIRECTORLINK_ALARM_KEY` is empty and `DIRECTORLINK_ALARM_WITHOUT_CODE` is `none`. Versions 1.2.0 and 1.2.1 sealed DirectorLink's commands to a key of the driver's (version 2), so that Control4's debug log never saw the code; on the controller that took 14 seconds a command, so 1.2.2 dropped it. Like any Control4 command between drivers, the typed code is again in Director's debug log, which is root-only, in the controller's memory and gone within a few hours.

Without DirectorLink the driver works the same.

## Updating

1. Download the new `DirectorLink-PIMA-Force.c4z` from the [releases](../../releases).
2. Check that the name is exactly `DirectorLink-PIMA-Force.c4z`, not `... (1).c4z`.
3. **Driver → Add or Update Driver or Agent**. The driver keeps its settings, connections and programming.

From the earlier `PimaForce.c4z` test builds: see the [change log](CHANGELOG.md).

## Testing without a panel, or a panel without Control4

**A simulated panel.** Install the driver, then run the simulator from any PC on the home network:

```sh
python tools/force_sim.py --host <controller IP> --port 7780 --account 654321 --code 1234
```

Set **Panel User Code** to `1234` and leave **Account ID** and **Panel IP Address** empty. Arm and disarm from Navigator, and type `open 3`, `alarm 3`, `fault ac`, `siren on`, `arm away`, `disarm` or `drop` in the simulator.

**A real panel, from a PC.** Point a CMS network path at the PC's IP (port 7780) and run:

```sh
python tools/force_probe.py                  # ACK only: proves JSON, the account and heartbeats
PIMA_CODE=1234 python tools/force_probe.py   # also reads zones, names, the partition state and faults
```

The probe never arms, disarms, bypasses or switches outputs. On Windows, allow inbound TCP 7780 from the panel's address in the firewall first.

## Troubleshooting

| Connection Status | What to check |
|---|---|
| Waiting for the panel to connect on port N | The CMS path's IP and port, the controller's firewall or VLAN, the panel's network cable. The panel may take a few minutes to dial. |
| Account mismatch | Account ID differs from the CMS path's account. Clear it to learn the panel's. |
| Panel is sending Contact-ID/SIA, not JSON | Set Protocol = JSON. If JSON is not offered, the firmware must be upgraded, or use receive only. |
| Panel reports are encrypted / Unreadable data | Turn encryption off on the CMS path. |
| Connected - set 'Panel User Code' | Enter the master or Smart Home code. |

**Last Panel Error: Wrong User Code**: the panel refused the code it was sent.

Still to confirm on a real panel with JSON: whether arming needs `order` 1 or 0 (the driver sends 1 and retries with 0 if the panel refuses the order), the exact exit-delay timing, and whether Hebrew names need **Reverse Zone Names**.

## Privacy

The driver talks only to the panel on your home network. It sends nothing to DirectorLink or to PIMA's cloud and collects no usage data. Codes stay in your Control4 project, and no log line, status or report ever shows one. See [SECURITY.md](SECURITY.md).

## Support

Community-supported, best effort. Report problems in [Issues](../../issues).

Please include the panel model and firmware, your Control4 OS version, the **Driver Version**, **Connection Status** and **Panel Info** properties, and the log with **Debug Mode** on. Remove addresses and names you don't want to share. Reports that a panel works are welcome too. Security problems: see [SECURITY.md](SECURITY.md).

## Building from source

```sh
lua5.1 tests/test_force_protocol.lua   # the JSON protocol
lua5.1 tests/test_driver.lua           # the driver against a simulated panel (VERBOSE=1 shows its log)
lua5.1 tests/test_sia.lua              # receive-only mode
python tools/build.py                  # the tests, then dist/DirectorLink-PIMA-Force.c4z and dist/SHA256SUMS.txt
```

To test the packaged script instead of `src/`: `DRIVER_LUA=dist/driver.lua lua5.1 tests/test_driver.lua`.

| Path | Contents |
|---|---|
| `src/driver.xml` | The driver's definition: proxies, connections, properties, events, commands |
| `src/driver.lua` | The Control4 side: proxies, zones, partitions, the panel session, commands, DirectorLink's alarm agreement |
| `src/pima_force.lua` | The protocols: JSON codec, framing, Windows-1255 text, frame builders and decoders, SIA DC-09 |
| `src/www/documentation.html` | The installer's guide in Composer's Documentation tab |
| `tests/` | Offline tests (stock Lua 5.1) with a simulated panel and a mocked Control4 runtime |
| `tools/build.py` | The package |
| `tools/force_sim.py`, `tools/force_probe.py` | A simulated panel for a real controller, and a read-only listener for a real panel |
| `VERSION`, `CHANGELOG.md`, `docs/releases/` | The version, the change log, and the notes for each release |

`build.py` inlines `pima_force.lua` into one `driver.lua`, checks that every property the Lua uses exists in `driver.xml`, and stamps the version from `VERSION`. The driver version Composer compares is major·1000000 + minor·10000 + patch·100 + build, where build is the beta number, or 99 for the release: `1.0.0-beta.1` → `1000001`, `1.0.0` → `1000099`.

**Rules for new versions**

- `VERSION` is the only place the version is set.
- **Never rename** the `.c4z` file, and **never change or remove** proxy binding ids, connection ids, event ids, property names or the order of the variables. Dealers' projects (and DirectorLink) depend on them. Adding new ones is fine.
- Update `VERSION`, `CHANGELOG.md` and `docs/releases/v<version>.md`, then tag `v<version>`: GitHub Actions tests, builds and publishes the release with `SHA256SUMS.txt` (a pre-release for `-beta` versions).

## License and trademarks

[Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

The protocol follows PIMA's *Force Interface JSON Format Specification* v2.4. How the panel behaves in the field was checked against [C4-PimaForce](https://github.com/efic1/C4-PimaForce) (MIT), [pima-force-ha-integration](https://github.com/amithalp/pima-force-ha-integration) (MIT; the JSON test frames come from its fixtures) and [homebridge-pima-force](https://github.com/electricmonk/homebridge-pima-force) (protocol facts only). Control4 interfaces follow the public [Snap One DriverWorks documentation](https://snap-one.github.io/docs-driverworks-fundamentals/). DirectorLink's own source code: [github.directorlink.io](https://github.directorlink.io).

Installing third-party drivers or changing a Control4 project can affect compatibility, support, warranty or recovery. Keep a backup of your project. An alarm system protects people and property: test arming, disarming and alarms after installing, and keep the panel's own keypad and monitoring as they are.

Apache License 2.0. Copyright 2026 DirectorLink. DirectorLink is an independent project, not affiliated with Control4 or Snap One. Not affiliated with or endorsed by PIMA Electronic Systems. Product names are trademarks of their owners.
