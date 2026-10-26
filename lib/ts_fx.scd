// tabletseq's effects, ported from just draw for norns (itself from schicksalslied 2's \liedDelay and
// \liedReverb). Evaluates to an Array of unadded SynthDefs: \ts_input, \ts_delay, \ts_reverb and \ts_out.
// There is no sends synth: \ts_sine and \ts_oneshot write the reverb, delay and Carter's buses
// themselves, scaled by their sequence's sends. \ts_input does the same for norns' audio input.
// Node order is \ts_input (at the head of the group the sequence groups are in), the sequence groups,
// \ts_delay, Carter's pointer and grains (when it is on), \ts_reverb, Carter's feedback patch and
// recorder: the delay and the grains feed `out` and the reverb bus, the reverb, which reads its bus last,
// feeds `out`, and the feedback patch reads `out` after that, so it hears the reverb.
[
	// norns' audio input (inL and inR, the two mono buses of context.in_b) into the effects: scaled
	// copies go to the reverb and delay buses and, as a mono average, to Carter's delay (grainsOut).
	// It never writes the main output: norns' own monitor level (LEVELS > monitor) already passes the
	// dry input, and writing it here too would double it.
	SynthDef(\ts_input, { |inL = 0, inR = 1, reverbOut = 0, delayOut = 0, grainsOut = 0,
		in_reverb_send = 0, in_delay_send = 0, in_grains_send = 0|
		var sig = [In.ar(inL), In.ar(inR)];
		Out.ar(reverbOut, sig * in_reverb_send.lag(0.05));
		Out.ar(delayOut, sig * in_delay_send.lag(0.05));
		Out.ar(grainsOut, (sig[0] + sig[1]) * 0.5 * in_grains_send.lag(0.05));
	}),
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
