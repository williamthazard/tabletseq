// tabletseq's sine: the Mac's pitched voice. Evaluates to an Event holding the unadded SynthDef (def)
// and the function that decodes the envelope string the engine receives (decodeEnv); the engine
// (and tests/nrt_engine.scd) add or send them.
//
// The envelope string is "<n>;<pitch levels>;<pitch times>;<amp levels>;<amp times>", comma-separated
// within each part, times in beats. decodeEnv returns [pitchEnv, ampEnv] as Env arrays ready for the
// \pitchEnv and \ampEnv controls, or nil when the string is malformed.
(
	def: {
		var pitchBlank = Env.newClear(64).asArray, ampBlank = Env.newClear(32).asArray;
		SynthDef(\ts_sine, { |out = 0, ts = 0.5, sustain = 1, level = 1, gate = 1,
			reverbOut = 0, delayOut = 0, grainsOut = 0, reverb_send = 0, delay_send = 0, grains_send = 0|
			// pitchEnv and ampEnv play over `ts` seconds per beat; `sustain` alone sets the lifetime
			var freq = EnvGen.kr(\pitchEnv.kr(pitchBlank), timeScale: ts).midicps;
			var amp = EnvGen.kr(\ampEnv.kr(ampBlank), timeScale: ts);
			var fade = min(0.02, sustain / 4);
			var life = EnvGen.kr(Env([0, 1, 1, 0], [fade, (sustain - (2 * fade)).max(0), fade]), doneAction: 2);
			var release = EnvGen.kr(Env.asr(0, 1, 0.05), gate, doneAction: 2);
			// amp 1 at level 1 peaks at 0.25 (-12 dBFS)
			var sig = (SinOsc.ar(freq) * 0.25 * amp * life * release * Lag.kr(level, 0.05)) ! 2;
			Out.ar(out, sig);
			Out.ar(reverbOut, sig * Lag.kr(reverb_send, 0.05));
			Out.ar(delayOut, sig * Lag.kr(delay_send, 0.05));
			// Carter's delay records a mono sum
			Out.ar(grainsOut, (sig[0] + sig[1]) * 0.5 * Lag.kr(grains_send, 0.05));
		})
	}.value,
	decodeEnv: { |string|
		var parts = string.asString.split($;);
		var list = { |part| if(part.isEmpty) { [] } { part.split($,).collect(_.asFloat) } };
		var env = { |levels, times, maxSegments|
			if(levels.size >= 2 and: { levels.size <= (maxSegments + 1) } and: { times.size == (levels.size - 1) }) {
				Env(levels, times.max(0), \lin).asArray
			};
		};
		var pitch, amp;
		if(parts.size == 5) {
			pitch = env.(list.(parts[1]), list.(parts[2]), 64);
			amp = env.(list.(parts[3]), list.(parts[4]), 32);
		};
		if(pitch.notNil and: { amp.notNil }) { [pitch, amp] }
	}
)
