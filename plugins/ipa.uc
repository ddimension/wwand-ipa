// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-ipa — the eIM side of an eSIM fleet (GSMA SGP.32), as a wwand plugin
// (wwand plugins.uc: installed at /usr/share/ucode/wwand/plugins/ipa.uc).
//
// An eIM is the operator's fleet server: it queues eUICC packages (download
// this profile, enable that one, delete another) and the IoT Profile Assistant
// on the device fetches and executes them. The assistant here is ipad
// (github.com/ddimension/ipad, GSMA SGP.32 v1.3; /usr/lib/wwand/ipad from the
// feed's wwand-ipad package). It reaches the card through lpac's stdio
// protocol, so esim_bridge relays its APDUs over the modem's own channel
// exactly as it does for lpac. This module decides WHEN it runs and does what
// only the host can:
// - make the modem use a profile the eIM has just switched to (event
//   `profile_changed`), and say whether the connection came back — if not, the
//   assistant rolls the change back (SGP.32 3.3.2) and hands that change to us
//   the same way;
// - run a direct profile download through lpac (event `download`, SGP.32
//   3.2.3.1);
// - put the enabled profile's connectivity parameters into a wwand_sim section
//   for its ICCID (event `connectivity`, SGP.32 5.9.24).
//
// ipad drives an IoT eUICC as it is, and an ordinary SGP.22 consumer eUICC by
// emulating the SGP.32 functions: then the eIM configuration and the replay
// counters live in its state directory (/etc/wwand/ipa, kept across upgrades),
// and results are signed with a device key there, which the eIM learns from
// `wwandctl ipa export`. Such a card has no connectivity parameters, so its
// wwand_sim section is created empty, for the user to fill in.
//
// Exportless plain script: require() returns the API — the plugin object wwand
// expects (name, options, create), plus the pure pieces the tests reach.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const IPAD = '/usr/lib/wwand/ipad';

// ipad's exit status when the card has no eIM configuration (ipad main.c)
const EXIT_NO_EIM = 3;

// the wwand_modem options this plugin reads (wwand hands them over raw)
const OPTIONS = [ 'ipa', 'ipa_interval', 'ipa_eim_config', 'ipa_eim_id', 'ipa_insecure',
	'ipa_backend', 'ipa_direct' ];

let truthy = (v) => (v === true || v == '1' || v == 'true' || v == 'on' || v == 'yes');

// The raw uci values as the scheduler reads them. Empty strings are unset;
// ipa_interval stays null when it is not a number, and interval_of then takes
// the default. sim_slot is the modem's own option, from its entry: the slot to
// fall back to when the modem cannot say which one holds the active eUICC.
// ipa_backend: auto (the assistant probes the card), iot or emu; anything else
// is auto. ipa_direct (default on): offer direct downloads, run through lpac.
function cfg_of(ext, entry)
{
	let str = (v) => (v != null && v != '') ? '' + v : null;
	let n = +(ext?.ipa_interval ?? '');

	return {
		ipa: truthy(ext?.ipa),
		ipa_interval: (str(ext?.ipa_interval) != null && n == n) ? n : null,
		ipa_eim_config: str(ext?.ipa_eim_config),
		ipa_eim_id: str(ext?.ipa_eim_id),
		ipa_insecure: truthy(ext?.ipa_insecure),
		ipa_backend: (ext?.ipa_backend in [ 'iot', 'emu' ]) ? ext.ipa_backend : 'auto',
		ipa_direct: (str(ext?.ipa_direct) == null) ? true : truthy(ext.ipa_direct),
		sim_slot: entry?.cfg?.sim_slot,
	};
}
const STATE_DIR = '/etc/wwand/ipa';

// seconds; every one overridable through deps.timing for the tests
const TIMING = {
	// online this long before the first poll, so the poll does not race the
	// rest of bring-up (renew, firewall, a DNS that is not answering yet)
	settle: 60,
	// ...plus up to this much more, different per device (see spread_of): a
	// fleet that comes back from one power cut must not reach the eIM in the
	// same second
	settle_spread: 300,
	// after a failed run: soon enough to catch an eIM that was briefly away,
	// rare enough not to hammer one that is down
	retry: 600,
	// after a profile change: how long the SIM reset plus reconnect may take
	// before the assistant is told the connection is not back. A generous
	// bound, not a measurement: a new profile may first have to register on a
	// network the modem has not seen, and answering too early costs a rollback
	// the eIM did not ask for.
	online_timeout: 300,
	// how often the connection is checked while waiting for it
	online_poll: 5,
};

const INTERVAL_DEFAULT = 3600;
const INTERVAL_MIN = 300;

// Arguments land in a shell command line. Each is checked against what it can
// legitimately be, and refused otherwise — quoting alone would still let a
// quote character through.
let safe_path = (p) => type(p) == 'string' && match(p, /^\/[A-Za-z0-9._\/-]+$/) && !match(p, /\.\./);
let safe_id = (s) => type(s) == 'string' && match(s, /^[A-Za-z0-9._:-]+$/);

// The IMEI goes to the assistant for DeviceInfo (SGP.22 4.2), whose TAC is
// its first 8 digits (3GPP TS 23.003 6.2.1): the eIM and the SM-DP+ may tell
// device models apart by it. Only a well-formed one is passed.
function imei_of(imei)
{
	return (type(imei) == 'string' && match(imei, /^[0-9]{14,16}$/)) ? imei : null;
}

function interval_of(cfg)
{
	let n = +(cfg?.ipa_interval ?? INTERVAL_DEFAULT);

	if (n != n || n <= 0)
		n = INTERVAL_DEFAULT;

	return (n < INTERVAL_MIN) ? INTERVAL_MIN : n;
}

// When the next run is due: null while offline. The first run waits for the
// connection to settle; later ones follow the interval, or the shorter retry
// after a failure.
// A fixed fraction in [0, 1) per device, from its IMEI (FNV-1a). The whole
// point is that two routers get different values; being FIXED rather than
// random keeps one router's rhythm the same across restarts and makes the
// schedule testable. No IMEI: 0, i.e. no spread, which is also where every
// router stood before.
function spread_of(key)
{
	if (type(key) != 'string' || !length(key))
		return 0;

	let h = 2166136261;

	for (let i = 0; i < length(key); i++)
		h = ((h ^ ord(key, i)) * 16777619) % 4294967296;

	return (h % 10000) / 10000.0;   // .0: an integer division here is always 0
}

// When the next run is due: null while offline.
// - first run: after the settle time plus this device's share of the spread
// - after a good run: the interval, stretched by up to a tenth per device so
//   a fleet started together drifts apart instead of polling in lockstep
// - after failures: the retry time, doubled per consecutive failure (an eIM
//   that is down should not see the whole fleet every ten minutes), never
//   beyond the interval
function due(st, cfg, timing)
{
	let t = { ...TIMING, ...(timing ?? {}) };
	let sp = st?.spread ?? 0;

	if (st?.online_since == null)
		return null;

	if (st.last_end == null)
		return st.online_since + t.settle + int(t.settle_spread * sp);

	let iv = interval_of(cfg);

	if (st.last_ok)
		return st.last_end + iv + int(iv / 10 * sp);

	let back = t.retry;

	for (let i = 1; i < (st.fails ?? 1) && back < iv; i++)
		back *= 2;

	return st.last_end + ((back < iv) ? back : iv);
}

// The assistant's command line: ipad [options] <cmd> [file].
//   -s  its state directory (emulation state per EID, the device key)
//   -b  backend, -e eIM id, -k no TLS verification (lab only), -i IMEI,
//   -D  offer direct download (the `download` event goes to lpac)
// Its log goes to the syslog itself; stderr (usage errors, nothing else
// without -v) joins the protocol pipe, 2>&1, where the bridge logs every line
// that is not protocol JSON.
function build_cmd(o)
{
	let parts = [ o.ipad ?? IPAD, '-s', sprintf("'%s'", o.dir) ];

	if (o.backend && o.backend != 'auto')
		push(parts, '-b', o.backend);

	if (o.eim_id)
		push(parts, '-e', sprintf("'%s'", o.eim_id));

	if (o.insecure)
		push(parts, '-k');

	if (o.imei)
		push(parts, '-i', o.imei);

	if (o.direct)
		push(parts, '-D');

	push(parts, o.cmd ?? 'poll');

	if (o.file)
		push(parts, sprintf("'%s'", o.file));

	return sprintf('%s 2>&1', join(' ', parts));
}

// What reaches the pipe outside the protocol is what ipad could not log to
// the syslog: a usage error, a stuck start. Worth seeing, not an alarm.
function log_level(line)
{
	return 'notice';
}

return {
	// exposed for tests (test_ipa)
	imei_of: imei_of,
	spread_of: spread_of,
	interval_of: interval_of,
	due: due,
	build_cmd: build_cmd,
	log_level: log_level,

	// The scheduler proper, on typed options (cfg_of) and direct deps:
	// deps: { bridge (an esim_bridge instance), log,
	//         modem_of(ref), online(ref) -> a token for the current connection
	//         generation, or null while not connected,
	//         refresh(ref, eid, slot, cb(profiles)) -> re-read the card's
	//         profile list into status, then hand it to cb,
	//         modem_reset(ref, cb) -> the daemon's modem reset (hwops),
	//         sim_upsert(iccid, fields, origin, opts) -> the daemon's writer,
	//         download(ref, code, cc, cb(err)) -> a direct download under
	//         the running session (esim_bridge session_download) }
	// test seams: ipad_path, state_dir, timing, now(), exists(path)
	scheduler: function(deps) {
		let log = deps.log;
		let ipad = deps.ipad_path ?? IPAD;
		let dir = deps.state_dir ?? STATE_DIR;
		let timing = { ...TIMING, ...(deps.timing ?? {}) };
		let now = deps.now ?? (() => time());
		let exists = deps.exists ?? ((p) => fs.access(p) == true);
		let states = {};

		let state_of = (ref) => {
			if (!states[ref])
				states[ref] = { state: 'idle', seq: 0, runs: 0, profile_changes: 0 };

			return states[ref];
		};

		let slot_of = (cfg) => ((+(cfg?.sim_slot ?? 0)) > 0) ? +cfg.sim_slot : 1;

		// The card to manage is the ACTIVE eUICC, which on a dual-SIM module is
		// not necessarily the configured slot (the FM350's eUICC sits in SUB2).
		// Asked the way the daemon's esim_ready read asks it (daemon.uc,
		// `esim_ready`); a modem that cannot list its slots, or lists no active
		// eUICC, gets the configured slot — the one it always got.
		let pick_slot = (modem, cfg, cb) => {
			if (type(modem?.slot_status) != 'function')
				return cb(slot_of(cfg));

			modem.slot_status((err, slots) => {
				let e = filter(slots ?? [], (s) => s.is_euicc && s.active)[0];

				cb((!err && e?.physical != null) ? +e.physical : slot_of(cfg));
			});
		};

		// the one place a run ends; everything else only returns into it
		let finish = (ref, st, ok, error, cb, result) => {
			st.seq++;   // anything still pending from this run is stale now
			st.state = 'idle';
			st.last_end = now();
			st.last_ok = ok;
			st.last_error = ok ? null : error;
			st.fails = ok ? 0 : (st.fails ?? 0) + 1;
			st.runs++;

			if (ok)
				log('info', sprintf('modem %s: ipa: %s done', ref, st.why ?? 'poll'));
			else
				log('warn', sprintf('modem %s: ipa: run failed (%s)', ref, error ?? '?'));

			// The assistant may have installed, deleted or switched profiles
			// without the host seeing which, so the card's list in status is
			// read again after every run that reached the card — failed ones
			// too, a package can fail halfway.
			//
			// The list is also how installs and deletions become visible here
			// at all: the assistant does not report them to the host, and the
			// eUICC Package Result it sends the eIM carries result codes, not
			// the profile list (SGP.32 v1.3 EuiccResultData). So the list from
			// before the run is compared with the one after it.
			if (st.reached_card && type(deps.refresh) == 'function') {
				let before = st.profiles_before;
				let changes = st.changes;

				deps.refresh(ref, st.eid, st.slot, (profiles) => {
					let now_ids = map(profiles ?? [], (p) => p.iccid);

					// no list from before (never read on this modem): nothing
					// to compare, and reporting every profile as installed
					// would be a lie
					if (before != null) {
						changes.installed = filter(now_ids, (i) => index(before, i) < 0);
						changes.deleted = filter(before, (i) => index(now_ids, i) < 0);
					}

					for (let i in changes.installed ?? [])
						log('notice', sprintf('modem %s: ipa: profile %s installed by the eIM', ref, i));

					for (let i in changes.deleted ?? [])
						log('notice', sprintf('modem %s: ipa: profile %s deleted by the eIM', ref, i));
				});
			}

			st.last_changes = st.changes;
			st.reached_card = false;

			cb?.(ok ? null : { error: 'ipa', detail: error }, result ?? null);
		};

		// A profile change inside the run: reset the SIM so the modem takes the
		// new profile, then wait for a NEW connection. Waiting for "online"
		// alone would return at once — the old session is still CONNECTED
		// until the daemon notices the identity change and drops it — so it
		// waits for the connection generation to move.
		let on_profile_changed = (ref, st, slot, reply) => {
			let before = deps.online(ref);
			let deadline = now() + timing.online_timeout;

			// THIS run's wait. The assistant can die while we wait (the bridge
			// kills a run, or it crashes); finish() then moves seq on, and a
			// timer firing afterwards must not put the scheduler back into
			// 'running' — nothing would ever end that run, and every later
			// poll would be refused as busy.
			let mine = st.seq;
			let live = () => st.seq == mine;

			st.state = 'waiting_online';
			st.profile_changes++;

			// which profile this was, by the modem's own reading of the card:
			// the ICCID now, and the one after the SIM reset below. A switch
			// back to where the run started is the assistant's rollback.
			let from = deps.modem_of(ref)?.modem?.info?.iccid;
			log('notice', sprintf('modem %s: ipa: the eIM changed the active profile — resetting the SIM and waiting for the connection', ref));

			let answer = (online) => {
				if (!live())
					return;

				st.state = 'running';

				// looked up NOW, not the object from the event: a modem reset
				// (below) replaces the modem object, and the old one never
				// learns the new ICCID
				let to = deps.modem_of(ref)?.modem?.info?.iccid;
				let rollback = (to != null && to == st.iccid_at_start && length(st.changes.switched) > 0);

				push(st.changes.switched, { from: from, to: to, rollback: rollback });
				log('notice', sprintf('modem %s: ipa: %s %s -> %s', ref,
					rollback ? 'profile rolled back' : 'profile switched', from ?? '?', to ?? '?'));

				log(online ? 'notice' : 'warn', sprintf('modem %s: ipa: connection %s after the profile change%s',
					ref, online ? 'back' : 'NOT back', online ? '' : ' — the assistant will roll back if the eIM stays unreachable'));
				reply({ online: online });
			};

			deps.bridge.apply_sim_reset(ref, slot, (err, res) => {
				if (err)
					log('warn', sprintf('modem %s: ipa: SIM reset failed (%J)', ref, err));

				// The SIM power cycle did not happen, and the apply falls back to
				// a modem reset (esim_bridge apply_sim_reset). In LuCI a person
				// presses that button; here nobody would, and the modem would
				// keep the OLD profile until the assistant gave up and rolled
				// back a switch that may well have worked. So do it.
				if (res?.apply == 'modem_reset' && type(deps.modem_reset) == 'function') {
					log('warn', sprintf('modem %s: ipa: the SIM could not be reset — resetting the modem to take the new profile', ref));
					deps.modem_reset(ref, (rerr) => {
						if (rerr)
							log('warn', sprintf('modem %s: ipa: modem reset failed too (%J) — the modem may keep the old profile', ref, rerr));
					});
				}

				let check;
				check = () => {
					if (!live())
						return;

					let tok = deps.online(ref);

					if (tok != null && tok !== before)
						return answer(true);

					// Still the pre-reset session (or none) at the deadline is
					// NOT back: a profile change always drops the old session,
					// because the daemon sees the ICCID change
					// (daemon.modem_sim_refresh). Reporting it as
					// online would send the result over the old profile.
					if (now() >= deadline)
						return answer(false);

					uloop.timer(timing.online_poll * 1000, check);
				};

				uloop.timer(timing.online_poll * 1000, check);
			});
		};

		// A direct download the eIM asked for (SGP.32 3.2.3.1), through lpac
		// under the assistant's own claim on the card. The install
		// notification stays on the card: the assistant reports it to the eIM.
		// The activation code is not logged; it may be a one-time secret.
		let on_download = (ref, st, p, reply) => {
			let mine = st.seq;

			if (type(deps.download) != 'function')
				return reply({ ok: false, error: 'unsupported' });

			log('notice', sprintf('modem %s: ipa: the eIM asked for a profile download', ref));
			st.state = 'downloading';

			let dl = { ok: null };

			push(st.changes.downloads, dl);

			deps.download(ref, p?.activation_code, p?.confirmation_code, (err) => {
				if (st.seq != mine)
					return;   // the run is over; nobody waits for this answer

				st.state = 'running';
				dl.ok = !err;
				log(err ? 'warn' : 'notice', sprintf('modem %s: ipa: download %s%s', ref,
					err ? 'failed' : 'done', err ? sprintf(' (%s)', err.error ?? '?') : ''));
				reply(err ? { ok: false, error: err.error ?? 'failed' } : { ok: true });
			});
		};

		// The enabled profile's connectivity parameters (SGP.32 5.9.24) into a
		// wwand_sim section for its ICCID. What the card states is written and
		// kept current. A card that states nothing (always so for an emulated
		// SGP.22 card) still gets its section, but only created, never
		// updated, so an APN the user fills in stays. A hand-written wwand_sim
		// for the card always wins: sim_upsert does not touch it.
		let on_connectivity = (ref, st, p, reply) => {
			let from_card = (p?.source == 'card');
			let fields = {};

			if (from_card) {
				fields.apn = p.apn;
				fields.pdp_type = p.pdp_type;

				// TS 102 223 carries login and password but no method
				if (length(p.username ?? '') || length(p.password ?? '')) {
					fields.username = p.username;
					fields.password = p.password;
					fields.auth = 'both';
				}
			}

			let r = (type(deps.sim_upsert) == 'function' && match(p?.iccid ?? '', /^[0-9]{18,20}$/))
				? deps.sim_upsert(p.iccid, fields, 'ipa', { create_only: !from_card })
				: { written: false, reason: 'unsupported' };

			st.connectivity = {
				iccid: p?.iccid,
				source: from_card ? 'card' : (p?.emulated ? 'emulated: none' : 'none'),
				apn: fields.apn,
				pdp_type: fields.pdp_type,
				section: r?.section,
				written: !!r?.written,
				reason: r?.reason,
			};

			if (r?.written)
				log('notice', sprintf('modem %s: ipa: connectivity parameters of %s written to %s (%s)',
					ref, p.iccid, r.section, from_card ? sprintf('apn %J', fields.apn) : 'none stated, left for you to fill in'));
			else if (r?.reason == 'foreign')
				log('info', sprintf('modem %s: ipa: %s has a wwand_sim of its own (%s); not touched', ref, p?.iccid, r.section));

			reply({});
		};

		let on_event = (ref, st, slot, rec, reply) => {
			switch (rec.event) {
			case 'info':
				st.eid = rec.payload?.eid;
				st.backend = rec.payload?.backend;
				st.key_fingerprint = rec.payload?.key_fingerprint;
				return reply({});
			case 'profile_changed':
				return on_profile_changed(ref, st, slot, reply);
			case 'download':
				return on_download(ref, st, rec.payload, reply);
			case 'connectivity':
				return on_connectivity(ref, st, rec.payload, reply);
			}

			log('warn', sprintf('modem %s: ipa: unknown event %s', ref, rec.event ?? '?'));
			reply({ online: false });
		};

		// job: null for a poll, { cmd: 'export', file } for an export
		let run = (ref, cfg, why, cb, job) => {
			let entry = deps.modem_of(ref);
			let st = state_of(ref);

			if (!entry?.modem)
				return cb?.({ error: 'no_such_modem' }, null);

			if (st.state != 'idle')
				return cb?.({ error: 'busy' }, null);

			if (!exists(ipad))
				return cb?.({ error: 'ipa_not_installed', detail: sprintf('%s is missing (package wwand-ipad)', ipad) }, null);

			let init_cfg = cfg?.ipa_eim_config;
			let eim_id = cfg?.ipa_eim_id;

			if (init_cfg != null && !safe_path(init_cfg))
				return cb?.({ error: 'invalid_argument', detail: 'ipa_eim_config' }, null);

			if (eim_id != null && !safe_id(eim_id))
				return cb?.({ error: 'invalid_argument', detail: 'ipa_eim_id' }, null);

			let slot = slot_of(cfg);

			st.state = 'running';
			st.last_start = now();
			st.why = why;
			st.slot = slot;
			st.reached_card = false;
			st.iccid_at_start = entry.modem.info?.iccid;
			st.profiles_before = (type(entry.modem.esim_info?.profiles) == 'array')
				? map(entry.modem.esim_info.profiles, (p) => p.iccid) : null;
			st.changes = { switched: [], installed: null, deleted: null, downloads: [] };
			log('info', sprintf('modem %s: ipa: polling the eIM (%s)', ref, why));

			pick_slot(entry.modem, cfg, (picked) => {
				slot = picked;
				st.slot = picked;

				let step;
				step = (phase) => {
					let cmd = build_cmd({
						ipad: ipad, dir: dir,
						backend: cfg?.ipa_backend,
						eim_id: eim_id,
						insecure: !!cfg?.ipa_insecure,
						imei: imei_of(entry.modem.info?.imei),
						direct: cfg?.ipa_direct !== false,
						cmd: (phase == 'provision') ? 'provision' : (job?.cmd ?? 'poll'),
						file: (phase == 'provision') ? init_cfg : job?.file,
					});

					// set BEFORE the call: the run may end inside it, and
					// finish() reads this; a refused start takes it back
					st.reached_card = true;

					let r = deps.bridge.session_run(ref, slot, 'ipa', cmd, log_level,
						(rec, reply) => on_event(ref, st, slot, rec, reply),
						(rerr) => {
							let code = (rerr?.error == 'lpac') ? (rerr.code ?? -1) : null;

							// ipad exits 3 when the card has no eIM yet: store the
							// configured one, then poll it. Asked of the assistant,
							// not guessed from a file: on an IoT eUICC the
							// configuration lives on the card.
							if (code == EXIT_NO_EIM && phase == 'poll' && job == null) {
								if (init_cfg == null)
									return finish(ref, st, false, 'no_eim_config', cb);

								if (!exists(init_cfg))
									return finish(ref, st, false, 'eim_config_missing', cb);

								return step('provision');
							}

							if (rerr)
								return finish(ref, st, false,
									(code != null) ? sprintf('exit %d', code) : (rerr.error ?? 'error'), cb);

							if (phase == 'provision') {
								log('notice', sprintf('modem %s: ipa: eIM configuration stored on card %s', ref, st.eid ?? '?'));
								return step('poll');
							}

							finish(ref, st, true, null, cb, job ? { file: job.file } : null);
						});

					if (r) {
						st.reached_card = false;
						finish(ref, st, false, r.error, cb);
					}
				};

				step('poll');
			});
		};

		return {
			// called from the daemon's 10 s status tick for every modem
			tick: function(ref, cfg) {
				if (!cfg?.ipa)
					return;

				let st = state_of(ref);

				if (deps.online(ref) == null) {
					st.online_since = null;
					return;
				}

				if (st.online_since == null)
					st.online_since = now();

				let imei = deps.modem_of(ref)?.modem?.info?.imei;

				if (st.spread == null && imei)
					st.spread = spread_of(imei);

				if (st.state != 'idle')
					return;

				let d = due(st, cfg, timing);

				if (d != null && now() >= d)
					run(ref, cfg, 'schedule', null);
			},

			// ubus modem_ipa { op: 'poll' }: run now. The answer comes when the
			// run has started or been refused; the outcome is in status.
			poll: function(ref, cfg, cb) {
				let started = false;

				run(ref, cfg, 'request', (err, res) => {
					if (!started)
						cb(err, res);
				});

				if (state_of(ref).state != 'idle') {
					started = true;
					cb(null, { started: true });
				}
			},

			// The eIM import file for the card (eim-euicc-import/1): the device
			// key the eIM verifies an emulated card's results with. A run of
			// its own, so it never meets a poll on the card.
			export: function(ref, cfg, file, cb) {
				if (!safe_path(file))
					return cb({ error: 'invalid_argument', detail: 'file' });

				run(ref, cfg, 'export', cb, { cmd: 'export', file: file });
			},

			status: function(ref, cfg) {
				let st = state_of(ref);

				return {
					// the daemon's clock, which every timestamp here is on:
					// a browser computing "5 min ago" from its own clock is
					// off by whatever the two disagree
					now: now(),
					enabled: !!cfg?.ipa,
					state: st.state,
					eid: st.eid,
					runs: st.runs,
					profile_changes: st.profile_changes,
					last_start: st.last_start,
					last_end: st.last_end,
					last_ok: st.last_ok,
					last_error: st.last_error,
					fails: st.fails ?? 0,
					// what the last run did to the card: profile switches
					// ({ from, to, rollback }), and the ICCIDs it installed
					// and deleted (null when there was no list to compare)
					last_changes: st.last_changes,
					next_due: cfg?.ipa ? due(st, cfg, timing) : null,
					interval: interval_of(cfg),
					// what the assistant said about the card at the start of
					// its last run: iot or emulated, and for an emulated one
					// the device key the eIM must have imported
					backend: st.backend,
					key_fingerprint: st.key_fingerprint,
					// the last connectivity report and what became of it
					connectivity: st.connectivity,
				};
			},
		};
	},

	cfg_of: cfg_of,

	// --- the wwand plugin (plugins.uc) ---------------------------------------
	name: 'ipa',
	options: OPTIONS,

	create: function(pd) {
		// the daemon's deps, looked up when used: the eSIM bridge and module
		// load lazily in the daemon, and wwand-esim may be missing entirely
		let bridge = {
			session_run: (...a) => pd.esim_bridge()?.session_run(...a) ?? { error: 'esim_not_installed' },
			apply_sim_reset: (ref, slot, cb) => {
				let br = pd.esim_bridge();

				return br ? br.apply_sim_reset(ref, slot, cb) : cb({ error: 'esim_not_installed' });
			},
		};

		let sch = this.scheduler({
			bridge: bridge,
			log: pd.log,
			modem_of: pd.modem_of,
			online: pd.connection_token,
			refresh: pd.esim_refresh,
			modem_reset: pd.modem_reset,
			sim_upsert: pd.sim_upsert,
			download: (ref, code, cc, cb) => {
				let br = pd.esim_bridge();

				return (type(br?.session_download) == 'function')
					? br.session_download(ref, code, cc, cb)
					: cb({ error: 'esim_not_installed' });
			},
		});

		return {
			tick: (ref, ext) => sch.tick(ref, cfg_of(ext, pd.modem_of(ref))),

			// Manual profile changes on a managed card would put the
			// assistant's record of it (the profile to roll back to, the
			// pending results) out of step with the card; pending
			// notifications belong to the eIM too. Without wwand-esim nothing
			// runs, so nothing is managed and nothing is locked.
			esim_guard: (ref, op, ext) => (cfg_of(ext).ipa && pd.esim_bridge())
				? { reason: 'this card is managed by an eIM (option ipa)' } : null,

			ops: {
				status: (ref, ext, args, cb) => cb(null, sch.status(ref, cfg_of(ext, pd.modem_of(ref)))),
				poll: (ref, ext, args, cb) => {
					let cfg = cfg_of(ext, pd.modem_of(ref));

					if (!cfg.ipa)
						return cb({ error: 'ipa_disabled', detail: 'set option ipa on this modem' });

					sch.poll(ref, cfg, cb);
				},
				// modem_plugin { op: 'export', args: { file } } -> { file }
				export: (ref, ext, args, cb) =>
					sch.export(ref, cfg_of(ext, pd.modem_of(ref)), args?.file ?? '/tmp/wwand/ipa-export.json', cb),
			},
			read_ops: [ 'status' ],
		};
	},
};
