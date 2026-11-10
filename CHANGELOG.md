# Changelog

All notable changes to DirectorLink · PIMA FORCE for Control4. Versions follow the `VERSION` file; the driver version Composer compares is in brackets.

DirectorLink is an independent project, not affiliated with Control4, Snap One or PIMA.

## 1.0.0-beta.1 (1000001) - 2026-11-11

First release as a DirectorLink driver.

- **Receive only, tested on a FORCE 32C** (firmware 1.5.1, which has no JSON interface): the panel's SIA DC-09 reports (Contact-ID) reach Control4, and arming Away and disarming (from PIMA's own app) showed in the partition each time.
- **The JSON interface** (full control: arm Away, Home and Night, disarm, bypass, outputs, zone names and status) is built from PIMA's specification v2.4 and tested against a simulated panel; it has not run against a real panel yet. Reports are welcome.
- **DirectorLink's alarm agreement.** New string variables `DIRECTORLINK_ALARM` = `1` and `DIRECTORLINK_ALARM_CONTROL`: `1` while arming and disarming can work (the JSON interface connected), `0` in receive-only mode or without a panel connection. An arm or disarm from DirectorLink (InterfaceID `DirectorLink`) needs a typed code and is never carried out with Panel User Code.
- **Driver Version** shows the version and Composer's number, for example `1.0.0-beta.1 (1000001)`.
- The package is now `DirectorLink-PIMA-Force.c4z`, named **DirectorLink · PIMA FORCE**, with the license and notice inside.

### From the PimaForce.c4z test builds

Composer updates a driver by its file name, so this is a new driver for Composer. Note the properties of **PIMA FORCE** (Panel User Code, Partitions In Use, Partition N Zones, Panel IP Address), remove it, add **DirectorLink · PIMA FORCE**, and set them again. Bind the **Zone N** connections and redo any programming that used the old partitions. The panel's settings stay as they are.
