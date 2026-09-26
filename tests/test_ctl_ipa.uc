// wwand-ipa tests — `wwandctl ipa`: its formatters and the eIM file check.

'use strict';

import { eq, ok, done } from './lib/check.uc';

let ctl = require('wwand.ctl.ipa');

// --- ipa_lines: `wwandctl ipa` -------------------------------------------------
{
	eq(ctl.ipa_lines({ enabled: false }, 0), [ [ 'eIM', 'not enabled on this modem (option ipa)' ] ],
	   'ipa: a modem without option ipa says so, and nothing else');

	let st = { enabled: true, state: 'idle', runs: 4, profile_changes: 1,
	           last_end: 1000, last_ok: false, last_error: 'exit 234', fails: 2,
	           next_due: 1000 + 1200, eid: 'E1', backend: 'emulated', key_fingerprint: '0123456789ABCDEF0123',
	           connectivity: { iccid: '8949', source: 'emulated: none', section: 'wwsim_8949', written: true },
	           last_changes: { switched: [ { from: 'A', to: 'B', rollback: false },
	                                       { from: 'B', to: 'A', rollback: true } ],
	                           installed: [ 'C' ], deleted: [] } };

	eq(ctl.ipa_lines(st, 1300), [
		[ 'eIM', 'idle · 4 runs · 1 profile change' ],
		[ 'last run', '5 min ago · failed: exit 234 (2 in a row)' ],
		[ 'next poll', 'in 15 min' ],
		[ 'card', 'EID E1 · SGP.22 card, emulated · device key 0123456789ABCDEF…' ],
		[ 'connectivity', '8949: none stated (emulated: none) → wwsim_8949 (written)' ],
		[ 'last changes', 'switched A → B · rolled back B → A · installed C' ],
	], 'ipa: outcome first, then when it tries again, the card and what the last run did');

	eq(ctl.ipa_lines({ enabled: true, state: 'idle', runs: 0, profile_changes: 0 }, 0)[1],
	   [ 'next poll', 'once the connection is up' ], 'ipa: offline, the next poll waits for the connection');
	eq(ctl.ipa_lines({ ...st, next_due: 1000 }, 1300)[2], [ 'next poll', 'due now' ], 'ipa: an overdue poll is due now');
	eq(ctl.ipa_lines({ ...st, last_ok: true, fails: 0, last_end: 0 }, 3 * 3600 + 5 * 60)[1],
	   [ 'last run', '3 h 5 min ago · ok' ], 'ipa: a good run, hours ago');
}

// --- eim_config_kind: what `wwandctl ipa eim <file>` accepts ------------------
eq(ctl.eim_config_kind('\xbf\x57\x7c\xa0'), 'AddInitialEimRequest', 'eim file: BF57 is the initial eIM request');
eq(ctl.eim_config_kind('\xbf\x55\x7c\xa0'), 'GetEimConfigurationDataResponse', 'eim file: BF55 is accepted as the same structure');
eq(ctl.eim_config_kind('-----BEGIN PUBLIC KEY-----'), null, 'eim file: a PEM key is not a configuration');
eq(ctl.eim_config_kind('BF577CA0'), null, 'eim file: a HEX dump of one is not one either');
eq(ctl.eim_config_kind('\xbf\x2d\x00\x00'), null, 'eim file: another ES10 structure is refused');
eq(ctl.eim_config_kind(null), null, 'eim file: nothing read, nothing accepted');
eq(ctl.eim_config_kind('\x30\x0a\x80\x03eim'), 'EimConfigurationData', 'eim file: a bare EimConfigurationData');
eq(ctl.eim_config_kind('\x30\x81\x88\x80\x0f'), 'EimConfigurationData', 'eim file: ...with a long length');
eq(ctl.eim_config_kind('\x30\x0a\x02\x01\x00'), null, 'eim file: some other SEQUENCE is not one');

{
	let cn = (c) => ctl.ipa_lines({ enabled: true, state: 'idle', runs: 1, profile_changes: 0, connectivity: c }, 0)[2];

	eq(cn({ iccid: '8949', source: 'card', apn: 'iot.ex', pdp_type: 'ipv4', section: 'wwsim_8949', written: true }),
	   [ 'connectivity', '8949: apn iot.ex · ipv4 → wwsim_8949 (written)' ], 'connectivity: what the card stated, and where it went');
	eq(cn({ iccid: '8949', source: 'card', apn: 'iot.ex', section: 'mysim', reason: 'foreign' }),
	   [ 'connectivity', '8949: apn iot.ex → your wwand_sim mysim wins, not touched' ], 'connectivity: a hand-written section wins');
}


ok(type(ctl.run) == 'function' && length(ctl.help) == 3, 'ctl: the shape wwandctl loads (run, help)');

done('test_ctl_ipa');
