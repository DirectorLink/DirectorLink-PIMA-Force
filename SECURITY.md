# Security policy

## Reporting a vulnerability

Please report security problems privately, not in public issues.

Open this repository's **Security** tab and choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers see your report.

Include what you found, the driver version (the **Driver Version** property), and the steps to reproduce it. Leave out real codes, addresses and names.

We will confirm the report, fix the problem in a new release, and credit you if you wish.

## Supported versions

Only the [newest release](../../releases) gets security fixes.

## Scope

The driver runs on the Control4 controller. It listens on one TCP port (**Listen Port**, 7780 by default) for the alarm panel, which connects to it the way it connects to a monitoring station.

- **The link to the panel is not encrypted.** PIMA's JSON interface has no encryption, and the driver reads SIA DC-09 reports only with encryption off. Codes sent to the panel and the panel's reports cross the home network in the clear. Keep the panel and the controller on a network you trust, and set **Panel IP Address** so that the driver refuses connections from any other address.
- **The account.** Once the driver has learned the panel's account (from its first report, or as typed in **Account ID**), it refuses reports with any other account.
- **Panel User Code** (the master or Smart Home code) is kept in the Control4 project, as the driver's property. It is used to read the panel's zones and status, for Composer programming (arm and disarm without a typed code), for arming from Navigator when **Require Code To Arm** is No, and for bypass and outputs. It is sent only to the connected panel.
- **Codes typed on a Control4 screen** are sent to the panel as typed; the panel checks them. Disarming from a Control4 screen always needs a typed code.
- **DirectorLink** (DirectorLink's alarm agreement): an arm or disarm from DirectorLink (InterfaceID `DirectorLink`) always carries the code a person typed in the DirectorLink app. Without one it is refused, and it is never carried out with Panel User Code.
- **No code is ever logged**, typed or stored, at any Debug Mode: every log line passes through a filter that hides them, and neither Connection Status nor Panel Info shows one.
- **What the driver cannot do:** raise panic, fire or medical alarms (PIMA's interface has no command for them), or change the panel's programming.
