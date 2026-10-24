// tabletseq's one-shot sampler: a port of schicksalslied 2's OneShot SynthDef (PlayBuf, MoogFF, the
// 5 ms end fade). Evaluates to the unadded SynthDef; the engine (and tests/nrt_engine.scd) add it.
// Buffers are two-channel (the engine reads a mono file into both channels). The synth frees itself
// when the sample ends, or at once when its group's gate goes to 0.
SynthDef(\ts_oneshot, { |out = 0, buf = 0, rate = 1, amp = 1, level = 1, cutoff = 12000, resonance = 1,
	t_gate = 1, gate = 1, reverbOut = 0, delayOut = 0, grainsOut = 0,
	reverb_send = 0, delay_send = 0, grains_send = 0|
	var len, sig, filter, release, scaled;
	// Reversed hits (rate < 0) start from the file's last frame.
	// PlayBuf holds the file's last sample once it reaches the end, so each hit fades to 0 over its
	// last 5 ms (its second half, if shorter): a file that doesn't end at zero would otherwise leave DC.
	// max() and clip() keep the gain finite at rate 0 and for an empty buffer (BufDur 0).
	len = BufDur.kr(buf) / rate.abs.max(1e-9);
	sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf) * rate, t_gate, (rate < 0) * (BufFrames.kr(buf) - 1))
		* ((len - Sweep.ar(t_gate)) / (len * 0.5).clip(1e-6, 0.005)).clip(0, 1);
	filter = MoogFF.ar(sig, cutoff, resonance);
	// the fade ends at len; the filter rings a little past it
	Line.kr(0, 1, len + 0.05, doneAction: 2);
	release = EnvGen.kr(Env.asr(0, 1, 0.05), gate, doneAction: 2);
	scaled = filter * amp * release * Lag.kr(level, 0.05);
	Out.ar(out, scaled);
	Out.ar(reverbOut, scaled * Lag.kr(reverb_send, 0.05));
	Out.ar(delayOut, scaled * Lag.kr(delay_send, 0.05));
	Out.ar(grainsOut, (scaled[0] + scaled[1]) * 0.5 * Lag.kr(grains_send, 0.05));
});
