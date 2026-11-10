# DirectorLink · PIMA FORCE for Control4

Free, open-source Control4 driver for **PIMA FORCE** alarm panels (FORCE, FORCE 32C, FORCE 16). Part of [DirectorLink Drivers](https://directorlink.io/drivers).

It works on your local network: the panel connects to the driver on the controller the way it connects to a monitoring station, with PIMA's local **JSON interface** (PIMA's *Force Interface JSON Format Specification* v2.4). No cloud, no extra hardware and no subscription.

Free. No subscription, no license key, no account with us.

Made by [DirectorLink](https://directorlink.io), the open-source management layer for Control4 homes. Works on its own: DirectorLink is not required.

DirectorLink is an independent project, not affiliated with Control4, Snap One or PIMA.

**Download:** [releases](../../releases) · **Help and updates:** [directorlink.io/drivers/pima-force](https://directorlink.io/drivers/pima-force)

> **Tested on a FORCE 32C** (firmware 1.5.1) in receive-only mode: arming, disarming and the partition's state reach Control4. The JSON interface (arming and disarming from Control4, zones, bypass) follows PIMA's specification and is tested against a simulated panel; reports from panels with JSON firmware are welcome: see [Support](#support).

## What you get

In Composer the driver adds a **Security Panel** and four **partitions** (Control4's standard security proxies), so every Control4 app shows the alarm.

| Feature | With the JSON interface | Receive only (no JSON in the firmware) |
|---|---|---|
| Armed (Away, Home, Night), disarmed, exit delay | Yes | Armed and disarmed, from the panel's reports |
| Arm and disarm from Control4 | Yes: Away = Full arm, Home = Home 1, Night = Home 2. Disarming needs a typed code | No |
| Alarms (burglary, fire, gas, water, panic, medical, duress) | Yes | Yes |
| Troubles (AC loss, low battery, tamper, communication) | Yes, from the panel's fault list | Yes, from its reports |
| Zones open and closed | Yes, live, with the names in the panel (Hebrew too) | When the panel reports them; names set in Composer |
| Bypass, outputs 1-8 | Yes | No |
| Programming events | Communication Lost / Restored, Siren Active / Inactive, Access Denied, and the partitions' own | The same |

Each zone also has a **Zone N** contact connection: bind a Control4 contact driver (Door Contact, Motion Sensor...) to use the zone in rooms and programming.

PIMA's interface has no command to raise panic, fire or medical alarms, so those buttons are not offered.

## Requirements

- **Control4 OS 3.0.0 or newer** and Composer Pro.
- **A PIMA FORCE panel** on the home network, with a free monitoring-station path (CMS 2 or 3; never one a monitoring company uses).
- **For full control:** panel firmware with the JSON interface (PIMA wrote its specification for 1.6.x and later; 1.8.x is current). Older firmware works in [receive-only mode](#receive-only-mode).
- The panel reaches the controller on the driver's **Listen Port** (7780 by default). The panel dials out; it opens no port of its own.

## Panel firmware

The JSON interface isn't in every FORCE firmware. Upgrade first for full control:

1. On the keypad, enter the **master code**, then Communication → Remote Service → **Upgrade/Update** (press and hold **6** as a shortcut).
2. Set **Firmware: Latest version**, then choose **Over Network**.
3. Check **System Information**: it should show 1.8.x.
4. Users & Codes now has a **Smart Home code**, and a CMS network path offers **Protocol = JSON**.

If the upgrade server offers nothing, ask your installer or PIMA support for FORCE firmware with the Smart Home (JSON) interface.

## Setup

### On the panel (installer code)

System Programming → CMS & Communication → Monitoring Stations → **CMS 2** (or 3) → Comm. Paths → **Network**:

- **IP**: the controller's IP address (give the controller a fixed address). **Port**: the driver's Listen Port, 7780. **Account ID**: any number.
- **Protocol**: **JSON** (or the panel's normal report protocol, for receive only). **Encryption**: **off**. **Life signal**: on.
- Event reporting: **Zone/Output Toggle = ON**.
- User menu: **Remote Disarm = ON**, or the panel refuses disarming from Control4.

### In Composer

1. **Driver → Add or Update Driver or Agent** → `DirectorLink-PIMA-Force.c4z`. Add **DirectorLink · PIMA FORCE** to a room.
2. Set the properties:
   - **Account ID**: leave it empty. The driver takes the account from the panel's first report and fills it in; after that, reports with any other account are refused.
   - **Panel User Code**: the master or Smart Home code (JSON only). It reads zones and status, and is used for programming, for arming from Navigator when **Require Code To Arm** is No, and for bypass and outputs. The installer code does not work here.
   - **Panel IP Address**: the panel's address, so that connections from anywhere else are refused (recommended).
   - **Partitions In Use** and **Partition N Zones** (for example `1-8,12`, or `all`).
3. Watch **Connection Status**: it ends at `Connected to <the panel's address>`, or `Receive only (SIA DC-09): ...`. Zones and their names load by themselves.

The Documentation tab in Composer covers every property, the behaviour and troubleshooting.

## Receive-only mode

FORCE firmware without the JSON interface (like 1.5.1) can still report to the driver with its normal monitoring protocol, **SIA DC-09** (Contact-ID or SIA codes, encryption off). The driver detects it, acknowledges every report, and shows arming, disarming, alarms, troubles and zones opening and closing in Control4. It can't arm, disarm, bypass or read zone names. The partition's state is unknown until the panel's first arm or disarm report. When JSON firmware arrives, set the CMS path to JSON: the driver switches to full control by itself.

## With DirectorLink

The partitions are Control4's standard ones, so DirectorLink (with its **Alarm Status** property On) shows each partition's state on Home in the DirectorLink app, and the home's TV screens tell when the alarm goes off.

From **DirectorLink 1.15.0**, with its **Alarm Control** property On, admins and the members they allow can arm and disarm from the DirectorLink app. They type their alarm code each time: it goes to the panel as typed, and the panel checks it. The driver follows DirectorLink's alarm agreement:

- `DIRECTORLINK_ALARM` = `1`, written on every start.
- `DIRECTORLINK_ALARM_CONTROL` = `1` while arming and disarming can work (the JSON interface connected), `0` in receive-only mode or without a panel connection. DirectorLink offers Arm and Disarm only while it says `1`.
- An arm or disarm from DirectorLink (InterfaceID `DirectorLink`) needs a typed code, and is never carried out with Panel User Code.

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
