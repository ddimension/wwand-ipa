# wwand-ipa

eSIM fleet management for [wwand](https://github.com/ddimension/wwand), the
OpenWrt cellular connection manager. With it, the router acts as the GSMA
SGP.32 IoT Profile Assistant for an eIM.

This is a **wwand plugin**, not part of wwand itself. It hooks into the daemon
through wwand's plugin interface (`plugins.uc`, see "Plugins" in wwand's
`docs/reference.md`), and the ddimension OpenWrt feed packages it separately.

| Path | Installed as | Package |
|---|---|---|
| `plugins/ipa.uc` | `/usr/share/ucode/wwand/plugins/ipa.uc` | `wwand-ipa` |
| `ctl/ipa.uc` | `/usr/share/ucode/wwand/ctl/ipa.uc` (`wwandctl ipa`) | `wwand-ipa` |
| `luci/` | the *Network → eSIM Fleet* page | `luci-app-wwand-ipa` |

The assistant itself is [ipad](https://github.com/ddimension/ipad), a C
implementation of SGP.32 v1.3 that the feed builds as `wwand-ipad`
(`/usr/lib/wwand/ipad`). It reaches the card through lpac's stdio APDU
protocol, so wwand relays its APDUs over the modem's own channel through the
same bridge lpac uses. It needs `wwand-esim`.

## What it does

An **eIM** is the fleet side of SGP.32. The operator queues eUICC packages
(download a profile, enable, disable, delete), and the assistant on the device
fetches and runs them. What the host adds:

- **Profile changes reach the modem.** When a package switches the active
  profile, wwand resets the SIM so the modem takes the new profile. This is the
  same apply as a manual `enable`; where the SIM cannot be power-cycled, wwand
  resets the modem instead. wwand then waits up to 5 minutes for a *new* data
  session. If none comes, the assistant rolls the change back (SGP.32 3.3.2)
  and reports that instead, and wwand applies the rollback the same way.
- **Direct downloads run through lpac** (SGP.32 3.2.3.1), under the
  assistant's own claim on the card. The assistant reports the result to the
  eIM. Indirect downloads (through the eIM) the assistant does itself.
- **The APN of the enabled profile lands in the config.** After every run, the
  assistant reads the enabled profile's connectivity parameters (SGP.32
  5.9.24). wwand writes them into a `wwand_sim` section for that ICCID,
  `wwsim_<iccid>`, marked `option origin 'ipa'`:

  ```
  config wwand_sim 'wwsim_89000123456789012342'
  	option iccid '89000123456789012342'
  	option origin 'ipa'
  	option apn 'iot.example'
  	option pdp_type 'ipv4v6'
  ```

  - **A hand-written `wwand_sim` for the same card always wins.** It is never
    touched.
  - **Taking the section over:** delete its `origin` line.
  - **A card that states no parameters still gets its section.** That is
    always the case for an emulated SGP.22 card (below). The section is
    created with just the ICCID, for you to fill in, and later runs leave it
    as it is.

## Cards

ipad works with two kinds of card:

- **An IoT eUICC** (SGP.32) stores the eIM configuration itself and signs
  its own results.
- **An ordinary SGP.22 consumer eUICC**, the cards `wwand-esim` already
  manages. ipad *emulates* the SGP.32 functions: the eIM configuration, the
  replay counters and the stored results live in
  `/etc/wwand/ipa/<EID>.state`. Results are signed with a **device key**,
  `/etc/wwand/ipa/device.key`.
  - The directory is kept across a sysupgrade
    (`/lib/upgrade/keep.d/wwand-ipa`).
  - The eIM verifies these signatures once it has imported the key:

    ```
    wwandctl ipa [modem] export /tmp/device.json     # on the router
    eimctl euicc import device.json                  # on the eIM
    ```

  - The import file (`eim-euicc-import/1`) proves that its maker holds the
    key.
  - A key file that exists but cannot be read is never replaced. If the file
    is gone, ipad creates a new key, and the eIM rejects its results until
    that key is imported.

ipad probes which kind it is talking to; `option ipa_backend 'iot'|'emu'`
forces it.

## Setup

**With a bundle from the eIM** (`eim-ipad-provision/1`, `eimctl ipad bundle`,
eIM decision D-69): one file with the eIM configuration and a device key the
eIM issued. The card's EID need not be known; the card registers itself.

```
wwandctl ipa [modem] provision /tmp/bundle.json
```

- ipad stores the configuration on the card (or in the emulation), puts the
  key in `/etc/wwand/ipa/device.key` (0600) and **deletes the file**. The
  bundle is a secret — it holds the private key in clear —, so copy it to
  the router over SSH only. A bundle that could not be stored (expired, the
  card already has an eIM) is left where it is, and the command says so.
- Fleet management is switched on (`option ipa '1'`).
- The next poll **binds** the card first: ipad posts the card's
  `eim-euicc-import/1` file, signed with the bundle key, to
  `/ipad/v1/bind` on the eIM, over the same TLS as ESipa, and only then asks
  for packages. 204 or 409 (already registered): bound. 403: refused — the
  card is not polled again until an operator acts (`reset`, a new bundle).
  429, 5xx or no answer: tried again at the next poll.
- An IoT eUICC takes only the configuration; it signs with its own
  certificate and does not bind.

**Without a bundle:**

1. **Point the modem at the eIM.** The eIM operator provides the eIM
   configuration: an `AddInitialEimRequest` as `eimctl eim-config` writes it
   (tag `BF57`). A `GetEimConfigurationDataResponse` (`BF55`) or a single
   `EimConfigurationData` (`30`) works too.

   ```
   config wwand_modem 'm0'
   	...
   	option ipa '1'
   	option ipa_eim_config '/etc/wwand/ipa/eim.ber'
   ```

   Or in one step, which checks the file and copies it to
   `/etc/wwand/ipa/<modem>-eim.ber`, sets both options and reloads:

   ```
   wwandctl ipa [modem] eim /tmp/eim.ber
   ```

2. **For an SGP.22 card, import its device key on the eIM** (`export`, above).
   The first run creates the key; `export` does too, if it runs first.

Changing these options does not restart the modem. The configuration reaches
a card only when the card has no eIM yet: ipad says so on its first poll,
and wwand then provisions it. A card that has an eIM keeps it. Moving a card
to another eIM is the eIM's business (SGP.32 `addEim` / `updateEim`).

## Options

| Option | Default | |
|---|---|---|
| `ipa` | off | fleet management for this modem |
| `ipa_eim_config` | – | the eIM configuration file for a card without an eIM |
| `ipa_eim_id` | the first | which eIM, when the card has several |
| `ipa_interval` | 3600 | seconds between polls (at least 300) |
| `ipa_backend` | `auto` | `iot` / `emu` to skip the probe |
| `ipa_direct` | on | offer direct downloads (lpac) to the eIM |
| `ipa_insecure` | off | no TLS verification of the eIM — lab only |

The eIM's TLS identity comes from its configuration
(`trustedPublicKeyDataTls`: a pinned key, its certificate or its CA), and
otherwise from the system CAs.

## Schedule

A poll runs when all of these hold:

- the connection has been up for a minute, plus up to five more;
- after that, every `ipa_interval` seconds, plus up to a tenth more.

The extra time is fixed per router (derived from its IMEI). A fleet that comes
back from one power cut therefore does not reach the eIM in the same second,
and it stays spread out afterwards. After a failed run, the next try comes
after 600 s, doubling with each further failure up to the interval.

The card managed is the modem's active eUICC. On a dual-SIM module that can be
the second physical slot. A modem that cannot list its slots uses `sim_slot`,
or 1.

The run is exclusive with the lpac operations on the same card; one waits for
the other (`busy`). Manual profile changes on a managed card are refused with
`esim_managed`: the assistant's state (the profile to roll back to, pending
results) would go out of step with the card. Pass `"force": true` to override.

ipad logs to the syslog itself (`logread -e ipad`).

## Interfaces

**CLI:**

```
wwandctl ipa [modem]                    # state, the card, the last run
wwandctl ipa [modem] poll [--timeout S] # poll now and wait for the end (JSON)
wwandctl ipa [modem] poll --no-wait     # only start it
wwandctl ipa [modem] eim <file>         # set the eIM, enable
wwandctl ipa [modem] export <file>      # the eIM import file (emulated card)
wwandctl ipa [modem] provision <bundle> # store a bundle, enable (JSON)
wwandctl ipa [modem] info               # the card now (JSON)
wwandctl ipa [modem] reset              # forget configuration, state, key (JSON)
```

`provision`, `poll`, `info` and `reset` are for scripts too (the eIM lab's
target driver, a bulk station): the last line on stdout is one JSON object,
messages for people go to stderr, and the exit status is

| Exit | |
|---|---|
| 0 | done (`poll`: the run completed, the eIM had no more packages) |
| 1 | failed: the eIM or the network, the card, an argument; `error` says which |
| 2 | the eIM refused to bind the card (403) |
| 3 | not supported here: ipad or wwand-esim not installed |

- `poll` waits for a run already under way (a scheduled one) to end, then
  runs its own, at most `--timeout` seconds (default 300) in all:
  `{"result":"ok"|"error","packages":n,"results":n,"notifications":n,"bound":bool,"bind":"…","eid":"…","error":"…"}`.
  `results` counts the results the eIM acknowledged.
- `info` reads the card (a short session of its own):
  `{"eid","card_type":"iot"|"emulated","bound","bind","counter","key_fingerprint","last_poll","last_error"}`.
  `bind` is `none`, `pending`, `done` or `refused`; `bound` is null for an
  IoT eUICC, which does not bind. `last_poll` is the time of the last poll.
- `provision` answers like `info`, plus `bundle_deleted`, or with
  `bundle_kept` when the bundle could not be stored.
- `reset` removes the eIM configuration of the emulation, its state, the
  device key and the binding (`ipad reset`, no card needed), refused while a
  run is under way. The uci options stay: with `option ipa` on, polls then
  fail (`no_eim_config`) until a new bundle is provisioned. An IoT eUICC keeps
  its eIM configuration; only the eIM can remove it.

**ubus:** `modem_plugin { modem, plugin: "ipa", op }`, with these ops:

- `status`;
- `poll`: returns once the run has started; the outcome shows in `status`;
- `export { file }`: answers `{ file }` when the file is written;
- `provision { file }`: answers the card's info once the bundle is stored;
- `info`: the card's info, read in a session of its own;
- `reset`: `{ reset: true }`.

Only a poll moves the schedule; `export`, `provision` and `info` do not count
as runs.

The read-only `modem_plugin_status` reaches `status` only.

`status` returns these fields:

| Field | Meaning |
|---|---|
| `enabled`, `state` | `idle` / `running` / `waiting_online` / `downloading` |
| `eid`, `backend` | `iot` / `emulated` |
| `key_fingerprint` | SHA-256 of the device key |
| `bind`, `counter` | an emulated card's self-binding (`none` / `pending` / `done` / `refused`) and its counter for the eIM |
| `last_poll` | `{ at, ok, error, summary }`: the last poll, with ipad's own account of it (packages, acknowledged results, exit code) |
| `runs`, `profile_changes` | counters |
| `last_start`, `last_end`, `last_ok`, `last_error` | the last run. Errors: ipad's own reason, or `no_eim_config`, `eim_config_missing`, `busy`, `exit <n>`, … |
| `fails` | consecutive failed runs |
| `next_due`, `interval` | the schedule |
| `last_changes` | switches, installs, deletions and downloads |
| `connectivity` | ICCID, the source (`card` / `none` / `emulated: none`), APN, PDP type, the section and whether it was written |

## Tests

```
sh tests/run_tests.sh                 # against ../wwand
WWAND_SRC=/path/to/wwand sh tests/run_tests.sh
node luci/tools/test-ipafmt.js
```

The tests load the plugin the way the daemon does (`wwand.plugins.ipa`, next
to wwand's own modules). They include a run through wwand's real eSIM bridge
with a stub assistant. ipad has its own suite, including an end-to-end run
against a real eIM. Not verified yet: router hardware with an eUICC.

## License

GPL-2.0-only, as wwand and ipad.
