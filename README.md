# wwand-ipa

eSIM fleet management for [wwand](https://github.com/ddimension/wwand), the
OpenWrt cellular connection manager: the router becomes the SGP.32 IoT
Profile Assistant for an eIM.

This is a **wwand plugin**, not part of wwand itself: it hooks into the daemon
through wwand's plugin interface (`plugins.uc`, see wwand's `docs/reference.md`,
"Plugins") and is packaged separately by the ddimension OpenWrt feed.

| Path | Installed as | Package |
|---|---|---|
| `plugins/ipa.uc` | `/usr/share/ucode/wwand/plugins/ipa.uc` | `wwand-ipa` |
| `ctl/ipa.uc` | `/usr/share/ucode/wwand/ctl/ipa.uc` (`wwandctl ipa`) | `wwand-ipa` |
| `luci/` | the *Network → eSIM Fleet* page | `luci-app-wwand-ipa` |

The assistant itself is [onomondo-ipa](https://github.com/onomondo/onomondo-ipa)
(AGPL-3.0), built by the feed as `wwand-ipad` with a patch that gives it a
card backend speaking lpac's stdio APDU protocol (so wwand relays its APDUs
over the modem's own channel) and a `-H` mode that hands profile changes to
wwand. The patch lives in the feed, `wwand-ipad/patches/`.

## Using it

An **eIM** is the fleet side of GSMA SGP.32: the operator queues eUICC packages
(download a profile, enable, disable, delete) and an **IoT Profile Assistant**
on the device fetches and runs them. `wwand-ipa` provides that assistant:
[onomondo-ipa](https://github.com/onomondo/onomondo-ipa) (AGPL, packaged as
`wwand-ipad`, `/usr/lib/wwand/ipad`), built with a card backend that speaks
lpac's stdio protocol, so its APDUs go over the modem's own channel through the
same bridge lpac uses. It needs `wwand-esim`.

What to know before using it:

- **It drives an SGP.22 consumer eUICC**, the cards `wwand-esim` already
  manages, through the assistant's *IoT eUICC emulation*. onomondo-ipa
  implements SGP.32 **v1.0** (onomondo-ipa README, commit 6aaeb38, 2026-09-01);
  in emulation it signs its results with a placeholder, so **the eIM must
  accept emulation-mode results**. A production eIM for accredited SGP.32 v1.2
  IoT eUICCs does not.
- **The eIM trust lives on the router, not on the card.** In emulation the eIM
  configuration and its replay counter are kept in the assistant's state file,
  `/etc/wwand/ipa/<EID>.nvstate` — one per card. The directory is kept across
  a sysupgrade (`/lib/upgrade/keep.d/wwand-ipa`), so it is the natural place
  for the eIM configuration file too. TLS to
  the eIM is the only authentication of the commands; `ipa_insecure` removes
  even that and is for lab eIMs only.
- **Manual profile changes are locked on a managed card.** With `option ipa`
  set, `modem_esim` refuses `download`, `enable`, `disable`, `delete` and
  `notify` with `esim_managed` (status says `esim_managed_by: "ipa"`): the assistant keeps the card's state (the profile
  to roll back to, pending results) in its state file, and a change made past it
  puts the two out of step. Pending notifications belong to the eIM too. Pass
  `"force": true` to override.

**Setup.** Put the eIM configuration (a BER-encoded `AddInitialEimRequest`, as
the eIM operator provides it) on the router and point the modem at it:

```
config wwand_modem 'm0'
	...
	option ipa '1'
	option ipa_eim_config '/etc/wwand/ipa/eim.ber'
```

Or in one step, which copies the file to `/etc/wwand/ipa/<modem>-eim.ber`,
sets both options and reloads (after checking the file is a BER
`AddInitialEimRequest`, tag `BF57`, or `GetEimConfigurationDataResponse`,
`BF55`):

```
wwandctl ipa [modem] eim /tmp/eim.ber
```

Changing these options does not restart the modem. The configuration reaches
a card only the first time it is seen, when it has no state file yet. A card
that already has one keeps its eIM, and `wwandctl` says so; the eIM itself
can move a card to another eIM (SGP.32 `addEim` / `updateEim`).

**What happens.** Once the modem's connection has been up for a minute plus up
to five more, and every `ipa_interval` seconds (default 3600) plus up to a
tenth more after that, wwand reads the card's EID and runs the assistant. The
extra is fixed per router (derived from its IMEI), so a fleet that comes back
from one power cut does not reach the eIM in the same second, and stays spread
out afterwards. After a failed run the retry comes after 600 s, doubling with
every further failure up to the interval.

1. A card seen for the first time (no state file) is **provisioned**: the eIM
   configuration from `ipa_eim_config` is stored for it. Without that option the
   run stops with `no_eim_config`. Nothing is guessed.
2. The eIM is **polled** and every queued package is run.
3. When a package **changes the active profile**, the assistant hands it to
   wwand: the SIM is reset so the modem takes the new profile (the same apply as
   a manual `enable`; where the SIM cannot be power-cycled, wwand resets the
   modem instead), and wwand waits up to 5 minutes for a *new* data session
   before it lets the assistant report the result. If the eIM cannot be reached
   over the new profile, the assistant rolls back to the previous one (when the
   eIM allowed that), and wwand applies that change the same way.

The card managed is the modem's active eUICC (on a dual-SIM module that can be
the second physical slot); a modem that cannot list its slots uses
`sim_slot`, or 1.

After every run that reached the card, the card's profile list in `status`
(`esim`) is read again. The assistant may have installed, switched or deleted
profiles.

The assistant's log goes to the syslog with wwand's own lines (`logread -e
esim\[ipa\]`), at wwand's log level: its errors as warnings, the APDU traffic
only at `debug` (`wwandctl` / ubus `set_log_level`). The run is exclusive with the
lpac operations on the same card; one waits for the other (`busy`).

**ubus:** `modem_plugin { modem, plugin: "ipa", op }` with op `status` or `poll`
(run now; returns when the run started, and the outcome shows up in `status`),
and the read-only `modem_plugin_status` for `status`.
`status` returns `enabled`, `state` (`idle` / `running` / `waiting_online`),
`eid`, `runs`, `profile_changes`, `last_start` / `last_end`, `last_ok`,
`last_error` (`no_eim_config`, `eim_config_missing`, `no_eid`, `busy`,
`exit <n>`, …), `fails` (consecutive failed runs), `next_due`, `interval` and `nvstate` (whether the card has
state).

`wwandctl ipa [modem] eim <file>` also refuses a file that is not a BER
`AddInitialEimRequest` (`BF57`) or `GetEimConfigurationDataResponse` (`BF55`),
and a modem without a `wwand_modem` section (an old-style configuration:
migrate it first).

## Tests

```
sh tests/run_tests.sh                 # against ../wwand
WWAND_SRC=/path/to/wwand sh tests/run_tests.sh
node luci/tools/test-ipafmt.js
```

The tests load the plugin the way the daemon does (`wwand.plugins.ipa`, next
to wwand's own modules), including a run through wwand's real eSIM bridge with
a stub assistant. Not verified yet: hardware with an eUICC and a real eIM.

## License

GPL-2.0-only, as wwand. The assistant (wwand-ipad) is AGPL-3.0 and runs as a
separate program.
