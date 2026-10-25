// tabletseq's effects, ported from just draw for norns (itself from schicksalslied 2's \liedDelay and
// \liedReverb). Evaluates to an Array of unadded SynthDefs: \ts_delay, \ts_reverb and \ts_out.
// There is no sends synth: \ts_sine and \ts_oneshot write the reverb, delay and Carter's buses
// themselves, scaled by their sequence's sends. Node order is the sequence groups, \ts_delay, \ts_reverb:
// the delay feeds `out` and the reverb bus, and the reverb feeds `out`.
[
	SynthDef(\ts_delay, { |in = 0, out = 0, reverbOut = 0, delayTime = 0.3, decayTime = 15,
		amp = 1, amp_slew = 0.1, to_reverb = 1, to_dry = 0|
		var sig = In.ar(in, 2);
		// CombL's maximum is 8 s: 16 s overran the real-time memory pool on norns in Lied.
		var del = CombL.ar(sig, 8.0, delayTime, decayTime) * amp.lag(amp_slew);
		Out.ar(out, del * to_dry.lag(0.05));
		Out.ar(reverbOut, del * to_reverb.lag(0.05));
	}),
	SynthDef(\ts_reverb, { |in = 0, out = 0, room = 0.5, damp = 0.5, amp = 1, amp_slew = 0.1|
		var rev = FreeVerb.ar(In.ar(in, 2), 1.0, room, damp);
		Out.ar(out, rev * amp.lag(amp_slew));
	}),
	// The output stage, at the very tail of the engine: the engine level, then a limiter at -1 dBFS,
	// replacing the stereo bus in place so nothing the norns mixes afterwards clips.
	SynthDef(\ts_out, { |out = 0, level = 1|
		var sig = In.ar(out, 2) * level.lag(0.05);
		ReplaceOut.ar(out, Limiter.ar(sig, -1.dbamp, 0.005));
	})
]
