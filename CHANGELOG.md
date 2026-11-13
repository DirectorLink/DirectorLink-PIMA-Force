# Changelog

All notable changes to DirectorLink · PIMA FORCE for Control4. Versions follow the `VERSION` file; the driver version Composer compares is in brackets.

DirectorLink is an independent project, not affiliated with Control4, Snap One or PIMA.

## 1.2.3 (1020399) - 2026-11-13

- **No Armed flash when disarming during the exit delay.** A FORCE reads armed from the start of its exit delay, so a disarm accepted during it showed the partition Armed for a moment before the panel's status read. The partition is now disarmed as soon as the panel accepts the disarm; the status read still follows.

## 1.2.2 (1020299) - 2026-11-13

Back to the typed code, as 1.1.0: arming and disarming from DirectorLink is quick again.

- **No more sealed commands.** On the owner's controller (CORE-1), the X25519 that 1.2.0 added took 14 seconds inside this driver, at every start and for every command from DirectorLink 1.16.0, and Director, which runs drivers one at a time, waited meanwhile (Composer froze for as long when the driver was updated). DirectorLink, on the same controller, runs the same code in well under a second; why this driver's Lua is so much slower is not known. The owner chose speed: the driver follows DirectorLink's alarm agreement version 1 again (`DIRECTORLINK_ALARM` = `1`), so DirectorLink sends the typed code. Like any command between Control4 drivers, that code is again in Director's own debug log (root-only, in memory, gone within a few hours).
- `DIRECTORLINK_ALARM_KEY` is cleared and `DIRECTORLINK_ALARM_WITHOUT_CODE` is `none`, written at every start; the stored private key is deleted. A sealed command (`dl2:`) still in flight is refused and nothing is sent to the panel.
- **DirectorLink Without Code is gone.** DirectorLink 1.16.0 arms and disarms without a code only for a driver that publishes a key, so the property could do nothing any more. Every arm and disarm from DirectorLink needs a typed code, as in 1.1.0.
- The X25519 and base64 code (and their notice) are removed; the driver is one plain script again.
- **1.2.1 was wrong about the cause:** running on standard Lua instead of LuaJIT changed nothing (14.2 s before and after). The driver stays on standard Lua, as DirectorLink runs.

## 1.2.1 (1020199) - 2026-11-13

- **Arm and disarm from DirectorLink in about a second, not 15.** The driver ran under LuaJIT (`jit="1"` in driver.xml, from its first version). There, on the controller, the X25519 that opens each of DirectorLink 1.16.0's sealed commands took 14 s, and Director, which runs drivers one at a time, waited: DirectorLink could not answer the app meanwhile, so the app said a command had failed that then went through. Now the driver runs on standard Lua, as DirectorLink does, where the same calculation takes well under a second. Seen on the owner's controller: "Command took too long … 14.3 s" in Director's log for each command. The build refuses `jit` from now on.
- Composer's description says CMS 1, 2 or 3, as the setup does since 1.1.0.

## 1.2.0 (1020099) - 2026-11-13

DirectorLink's alarm agreement, version 2 (for DirectorLink 1.16.0).

- **Sealed commands.** The driver makes an X25519 key pair once (from Director's random UUIDs, kept encrypted) and publishes the public key in `DIRECTORLINK_ALARM_KEY`. DirectorLink 1.16.0 seals each arm and disarm to it, so the code is no longer written in Control4's debug log, which records every command one driver sends another. The driver checks the command's MAC before decrypting it, and refuses a command that is replayed, more than a minute old, or meant for another action or mode. It logs none of it.
- **DirectorLink Without Code** (new property, default No; Arm only; Arm and disarm), told in `DIRECTORLINK_ALARM_WITHOUT_CODE`: how far a sealed command without a code is carried out with Panel User Code. DirectorLink's admins must allow it too.
- `DIRECTORLINK_ALARM` is now `2`. DirectorLink 1.15.0 still works: its typed codes are taken as before.
- The README has no Hebrew text; Composer's Documentation tab neither.

## 1.1.0 (1010099) - 2026-11-13

- **Shabbat mode.** **Shabbat** is offered next to Away, Home and Night (Navigator, DirectorLink): PIMA's own Shabbat arming (JSON operation 43), on panels sold in Israel as a "Shabbat and holiday system" (approved by the Zomet Institute). A panel that is not one refuses it.
- **Zones kept from Control4 on Shabbat.** While a partition is armed for Shabbat, its zones opening and closing are not passed to Control4 (the Zone N contact connections, the panel's and the partition's zone lists), so people moving in the house cause nothing in Control4's programming. An alarm is still reported. Once the partition is no longer armed for Shabbat, every zone is reported as it is then.
- **The JSON setup, step by step**, as PIMA's JSON configuration guide gives it: the events to report (Zone/Output Change), the account, the address and port, Protocol JSON with encryption disabled, and Remote Disarm, which is under CMS & Communication → General Settings, not the user menu as 1.0.0 said. Also in Composer's Documentation tab.
- **Tested on a FORCE 32C with the JSON interface** (firmware 3.0.19): the driver read the panel (24 zones, the exit time), and DirectorLink 1.15.0 armed it Away and disarmed it with a typed code. The README no longer says the JSON firmware is 1.6.x or 1.8.x: it is a special firmware PIMA provides.

## 1.0.0 (1000099) - 2026-11-11

First release as a DirectorLink driver.

- **Receive only, tested on a FORCE 32C** (firmware 1.5.1, which has no JSON interface): the panel's SIA DC-09 reports (Contact-ID) reach Control4, and arming Away and disarming (from PIMA's own app) showed in the partition each time.
- **The JSON interface** (full control: arm Away, Home and Night, disarm, bypass, outputs, zone names and status) is built from PIMA's specification v2.4 and tested against a simulated panel; it has not run against a real panel yet. Reports are welcome.
- **DirectorLink's alarm agreement.** New string variables `DIRECTORLINK_ALARM` = `1` and `DIRECTORLINK_ALARM_CONTROL`: `1` while arming and disarming can work (the JSON interface connected), `0` in receive-only mode or without a panel connection. An arm or disarm from DirectorLink (InterfaceID `DirectorLink`) needs a typed code and is never carried out with Panel User Code.
- **Driver Version** shows the version and Composer's number, for example `1.0.0 (1000099)`.
- The package is now `DirectorLink-PIMA-Force.c4z`, named **DirectorLink · PIMA FORCE**, with the license and notice inside.

### From the PimaForce.c4z test builds

Composer updates a driver by its file name, so this is a new driver for Composer. Note the properties of **PIMA FORCE** (Panel User Code, Partitions In Use, Partition N Zones, Panel IP Address), remove it, add **DirectorLink · PIMA FORCE**, and set them again. Bind the **Zone N** connections and redo any programming that used the old partitions. The panel's settings stay as they are.
