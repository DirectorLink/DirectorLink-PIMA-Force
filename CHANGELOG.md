# Changelog

All notable changes to DirectorLink · PIMA FORCE for Control4. Versions follow the `VERSION` file; the driver version Composer compares is in brackets.

DirectorLink is an independent project, not affiliated with Control4, Snap One or PIMA.

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
