// tabletseq's engine: the sine and the drum rack's one-shots, each sequence on its own group, and the
// effects they send to (reverb, delay and Carter's delay, ported from just draw for norns).
// The only SuperCollider class in the script; the SynthDefs live in ts_sine.scd, ts_oneshot.scd,
// ts_fx.scd and ts_grains.scd.
// Node order: the sequence groups, the delay, Carter's pointer and grains (when it is on), the reverb, Carter's
// feedback patch and recorder, then the output stage (\ts_out: engine level and a -1 dBFS limiter) at the tail.
// Every note starts in its sequence's group (1-16), so level and sends act live on the sounding notes.
Engine_TabletSeq : CroneEngine {
	var master, groups, levels, sends, buffers, decodeEnv;
	var reverbBus, delayBus, grainsBus, delayGroup, reverbGroup, outGroup, delay, reverb, outStage, outLevel = 0.316;
	// Carter's delay (ts_grains.scd): nothing is allocated until grains_on 1. grainSet holds every
	// setting, so values sent while the chain is off (or still allocating) apply when it comes up.
	var grainsOn = false, grainsLive = false, grainsGen = 0;
	var grainSet, grainRates;
	var grainGroups, grainBuf, grainEnvBufs, grainPtrBus, grainPtr, grainRec, grainFb, grainSynths;
	var grainDurs, grainDelays;
	classvar seqCount = 16, slotCount = 16, sendNames, grainCount = 4, grainBeatSec = 0.5;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	*initClass {
		sendNames = [\reverb, \delay, \grains];
	}

	alloc {
		var dir = PathName(this.class.filenameSymbol.asString).pathOnly;
		var sine = thisProcess.interpreter.executeFile(dir +/+ "ts_sine.scd");
		var oneshot = thisProcess.interpreter.executeFile(dir +/+ "ts_oneshot.scd");
		var fxDefs = thisProcess.interpreter.executeFile(dir +/+ "ts_fx.scd");
		var grainDefs = thisProcess.interpreter.executeFile(dir +/+ "ts_grains.scd");
		sine[\def].add;
		oneshot.add;
		fxDefs.do { |def| def.add };
		grainDefs.do { |def| def.add };
		decodeEnv = sine[\decodeEnv];
		Server.default.sync;

		// The effects' buses; the sends write to them.
		reverbBus = Bus.audio(context.server, 2);
		delayBus = Bus.audio(context.server, 2);
		grainsBus = Bus.audio(context.server, 1);
		master = Group.new(context.xg);
		groups = seqCount.collect { Group.new(master) };
		levels = Array.fill(seqCount, 0.8);
		sends = Array.fill(seqCount, { [0, 0, 0] });
		buffers = Array.newClear(slotCount);
		this.initGrains;
		// A bus written by a node that runs after its reader is lost for that cycle (In.ar hears silence), so
		// the reverb runs after everything that writes its bus: the sequence groups (their sends), the delay and
		// Carter's grains. The delay has a group of its own, and Carter's pointer and grains are made with
		// Group.after(delayGroup), which puts them between delayGroup and reverbGroup. Its feedback patch and
		// recorder go the other way, after the reverb, so the feedback hears it.
		delayGroup = Group.after(master);
		delay = Synth.new(\ts_delay, [\in, delayBus, \out, context.out_b, \reverbOut, reverbBus], delayGroup);
		reverbGroup = Group.after(delayGroup);
		reverb = Synth.new(\ts_reverb, [\in, reverbBus, \out, context.out_b], reverbGroup);
		// The output stage runs last of all; Carter's feedback groups (Group.after(reverbGroup)) sit before it.
		outGroup = Group.after(reverbGroup);
		outStage = Synth.new(\ts_out, [\out, context.out_b, \level, outLevel], outGroup);

		this.addCommand(\sine_note, "iffs", { arg msg;
			var group = this.groupFor(msg[1]);
			var env = decodeEnv.(msg[4]);
			if(group.notNil and: { env.notNil }) {
				Synth.new(\ts_sine, [
					\pitchEnv, env[0], \ampEnv, env[1], \ts, msg[3], \sustain, msg[2]
				] ++ this.noteArgs(msg[1].asInteger - 1), group);
			};
		});
		this.addCommand(\oneshot_load, "is", { arg msg; this.loadSlot(msg[1].asInteger, msg[2].asString) });
		this.addCommand(\oneshot_clear, "i", { arg msg; this.clearSlot(msg[1].asInteger) });
		this.addCommand(\oneshot_hit, "iif", { arg msg;
			var group = this.groupFor(msg[1]);
			var buf = this.bufferFor(msg[2]);
			if(group.notNil and: { buf.notNil }) {
				Synth.new(\ts_oneshot, [\buf, buf.bufnum, \amp, msg[3]] ++ this.noteArgs(msg[1].asInteger - 1), group);
			};
		});
		this.addCommand(\seq_level, "if", { arg msg;
			var group = this.groupFor(msg[1]);
			if(group.notNil) {
				levels[msg[1].asInteger - 1] = msg[2];
				group.set(\level, msg[2]);
			};
		});
		this.addCommand(\seq_send, "isf", { arg msg;
			var group = this.groupFor(msg[1]);
			var which = sendNames.indexOf(msg[2].asSymbol);
			if(group.notNil and: { which.notNil }) {
				sends[msg[1].asInteger - 1][which] = msg[3];
				group.set((sendNames[which] ++ "_send").asSymbol, msg[3]);
			};
		});
		this.addCommand(\seq_release, "i", { arg msg;
			var group = this.groupFor(msg[1]);
			if(group.notNil) { group.set(\gate, 0) };
		});
		this.addCommand(\release_all, "", { arg msg; groups.do { |group| group.set(\gate, 0) } });

		// Effects: each command sets one control on the synth that owns it.
		[
			[\set_delay_time, { delay }, \delayTime], [\set_delay_decay, { delay }, \decayTime],
			[\set_delay_level, { delay }, \amp], [\set_delay_to_reverb, { delay }, \to_reverb],
			[\set_delay_to_dry, { delay }, \to_dry], [\set_reverb_room, { reverb }, \room],
			[\set_reverb_damp, { reverb }, \damp], [\set_reverb_level, { reverb }, \amp]
		].do { |row|
			this.addCommand(row[0], "f", { arg msg; row[1].value.set(row[2], msg[1]) });
		};

		// The engine level, a linear amp, ahead of the limiter.
		this.addCommand(\set_out_level, "f", { arg msg;
			outLevel = msg[1];
			outStage.set(\level, outLevel);
		});

		// Carter's delay.
		this.addCommand(\grains_on, "i", { arg msg;
			if(msg[1] > 0) { this.allocGrains } { this.freeGrains };
		});
		[
			[\set_grains_level, \level], [\set_grains_to_reverb, \toReverb], [\set_grains_freeze, \freeze], [\set_grains_rec_pre, \recPre],
			[\set_grains_window, \window], [\set_grains_sync, \sync],
			[\set_grains_cutoff_ceiling, \ceiling], [\set_grains_rate_mult, \rateMult],
			[\set_grains_octaves, \octaves], [\set_grains_fifths, \fifths],
			[\set_grains_suboctaves, \suboctaves], [\set_grains_reverse, \reverse],
			[\set_grains_delay_scale, \delayScale], [\set_grains_fb_amp, \fbAmp],
			[\set_grains_fb_balance, \fbBalance], [\set_grains_fb_hpf, \fbHpf],
			[\set_grains_fb_noise, \fbNoise], [\set_grains_fb_sine_level, \fbSineLevel],
			[\set_grains_fb_sine_hz, \fbSineHz]
		].do { |row|
			this.addCommand(row[0], "f", { arg msg; this.setGrain(row[1], msg[1]) });
		};
		[[\set_grains_pan_rate, \panRate], [\set_grains_cutoff_rate, \cutoffRate],
			[\set_grains_res_rate, \resRate]].do { |row|
			this.addCommand(row[0], "if", { arg msg; this.setGrainRate(row[1], msg[1].asInteger, msg[2]) });
		};
	}

	// ---- Carter's delay: ported from schicksalslied 2's Lied.sc (ensureGranularChain and friends) ----

	initGrains {
		grainSet = Dictionary.newFrom([
			\level, 0.3, \toReverb, 0, \freeze, 0, \recPre, 0, \window, 0, \sync, 1, \ceiling, 16000, \rateMult, 1,
			\octaves, 0, \fifths, 0, \suboctaves, 0, \reverse, 0, \delayScale, 1,
			\fbAmp, 0, \fbBalance, 0, \fbHpf, 12, \fbNoise, 0, \fbSineLevel, 0, \fbSineHz, 55
		]);
		grainRates = (panRate: Array.fill(grainCount, { rrand(1, 64) }),
			cutoffRate: Array.fill(grainCount, { rrand(1, 64) }), resRate: Array.fill(grainCount, { rrand(1, 64) }));
	}

	// Playback rates of the grains, from the octave, fifth, sub-octave and reverse switches.
	grainTapRates {
		var oct = grainSet[\octaves] > 0, fif = grainSet[\fifths] > 0, sub = grainSet[\suboctaves] > 0;
		var base = case
			{ oct and: fif and: sub } { [1/2, 1, 3/2, 2] }
			{ oct and: fif } { [1, 2, 3/2, 4/3] }
			{ oct and: sub } { [1/4, 1/2, 1, 2] }
			{ fif and: sub } { [1/2, 1, 3/2, 4/3] }
			{ oct } { [1, 2, 1, 2] }
			{ fif } { [1, 3/2, 4/3, 9/8] }
			{ sub } { [1, 1/2, 1/4, 1/2] }
			{ true } { [1/4, 1/2, 1, 3/2] };
		^grainCount.collect { |i|
			var rate = base[i % base.size];
			(if(grainSet[\reverse] > 0 and: { i.odd }) { rate.neg } { rate }) * grainSet[\rateMult].max(0.01)
		};
	}

	grainEnvNum {
		^if(grainSet[\window] == 0) { -1 } { grainEnvBufs[grainSet[\window].asInteger - 1].bufnum }
	}

	// Sends one stored setting to the live chain.
	pushGrain { arg key;
		var value = grainSet[key];
		case
			{ key == \level } { grainSynths.do { |g| g.set(\amp, value) } }
			{ key == \toReverb } { grainSynths.do { |g| g.set(\toReverb, value) } }
			{ key == \sync } { grainSynths.do { |g| g.set(\sync, value) } }
			{ key == \ceiling } { grainSynths.do { |g| g.set(\cutoffMax, value) } }
			{ key == \window } { grainSynths.do { |g| g.set(\grainEnv, this.grainEnvNum) } }
			{ key == \recPre } { grainRec.set(\preLevel, value) }
			{ key == \freeze } {
				grainPtr.set(\rate, if(value > 0) { 0 } { 1 });
				grainRec.run(value <= 0);
			}
			{ [\rateMult, \octaves, \fifths, \suboctaves, \reverse].includes(key) } {
				this.grainTapRates.do { |rate, i|
					grainSynths[i].set(\rate, rate, \dens, 1 / (grainDurs[i] * rate.abs));
				};
			}
			{ key == \fbAmp } { grainFb.set(\amp, value) }
			{ key == \fbBalance } { grainFb.set(\balance, value) }
			{ key == \fbHpf } { grainFb.set(\hpFreq, value) }
			{ key == \fbNoise } { grainFb.set(\noiseLevel, value) }
			{ key == \fbSineLevel } { grainFb.set(\sineLevel, value) }
			{ key == \fbSineHz } { grainFb.set(\sineHz, value) };
	}

	// Stores a setting and, once the chain is up, sends it.
	setGrain { arg key, value;
		grainSet[key] = value;
		if(grainsLive) { this.pushGrain(key) };
	}

	setGrainRate { arg key, index, rate;
		if(index < grainCount) {
			grainRates[key][index] = rate;
			if(grainsLive) { grainSynths[index].set(key, rate) };
		};
	}

	allocGrains {
		var gen;
		if(grainsOn) { ^this };
		grainsOn = true;
		gen = grainsGen = grainsGen + 1;
		fork {
			var server = context.server;
			var delayScale = grainSet[\delayScale];
			var rates;
			grainBuf = Buffer.alloc(server, server.sampleRate * (grainBeatSec * 512), 1);
			grainEnvBufs = [
				Buffer.sendCollection(server, Env.perc(0.01, 0.99, 1, -4).asSignal(512)),
				Buffer.sendCollection(server, Env.new([0, 1, 0], [0.7, 0.3], [3, -3]).asSignal(512)),
				Buffer.sendCollection(server, Env.new([0, 1, 0], [0.98, 0.02], [4, -4]).asSignal(512))
			];
			grainPtrBus = Bus.audio(server, 1);
			server.sync;
			// Freed while allocating: only the buffers and bus exist, so free them and stop.
			if(gen != grainsGen) {
				grainBuf.free; grainEnvBufs.do(_.free); grainPtrBus.free;
			} {
				// The pointer and the grains run after delayGroup, after every note has written grainsBus and
				// before the reverb reads what the grains send it. The feedback patch and the recorder run after
				// reverbGroup, so the feedback hears the reverb on the main bus, and fbmix runs ahead of rec,
				// which reads the bus fbmix writes. The grains read the buffer far behind the pointer, so rec
				// running after them costs nothing. Each is in a group of its own to fix the order.
				grainGroups = Array.newClear(4);
				grainGroups[0] = Group.after(delayGroup);
				grainGroups[1] = Group.after(grainGroups[0]);
				grainGroups[2] = Group.after(reverbGroup);
				grainGroups[3] = Group.after(grainGroups[2]);
				grainPtr = Synth(\ts_ptr, [\buf, grainBuf, \out, grainPtrBus,
					\rate, if(grainSet[\freeze] > 0) { 0 } { 1 }], grainGroups[0]);
				grainFb = Synth(\ts_fbmix, [\in, context.out_b, \out, grainsBus, \amp, grainSet[\fbAmp],
					\balance, grainSet[\fbBalance], \hpFreq, grainSet[\fbHpf], \noiseLevel, grainSet[\fbNoise],
					\sineLevel, grainSet[\fbSineLevel], \sineHz, grainSet[\fbSineHz]], grainGroups[2]);
				grainRec = Synth(\ts_rec, [\ptrIn, grainPtrBus, \micIn, grainsBus, \buf, grainBuf,
					\preLevel, grainSet[\recPre]], grainGroups[3]);
				if(grainSet[\freeze] > 0) { grainRec.run(false) };
				rates = this.grainTapRates;
				grainDurs = grainCount.collect({ |i| grainBeatSec * (i + 1) }).scramble;
				grainDelays = grainCount.collect({ |i|
					server.sampleRate * (grainBeatSec * (i + 1)) * 16 * delayScale
				}).scramble;
				grainSynths = grainCount.collect { |n|
					Synth(\ts_gran, [
						\amp, grainSet[\level], \buf, grainBuf, \out, context.out_b,
						\reverbOut, reverbBus, \toReverb, grainSet[\toReverb], \atk, 1, \rel, 1, \gate, 1,
						\sync, grainSet[\sync], \dens, 1 / (grainDurs[n] * rates[n].abs),
						\baseDur, grainDurs[n], \durRand, 1, \rate, rates[n], \rateRand, 1,
						\grainEnv, this.grainEnvNum, \ptrBus, grainPtrBus, \ptrSampleDelay, grainDelays[n],
						\ptrRandSamples, server.sampleRate * (grainBeatSec * (n + 1)) * 2,
						\minPtrDelay, grainDelays[n], \cutoffMax, grainSet[\ceiling], \beatSec, grainBeatSec,
						\panRate, grainRates[\panRate][n], \cutoffRate, grainRates[\cutoffRate][n],
						\resRate, grainRates[\resRate][n]
					], grainGroups[1]);
				};
				grainsLive = true;
			};
		};
	}

	freeGrains {
		if(grainsOn.not) { ^this };
		grainsOn = false;
		grainsGen = grainsGen + 1;
		if(grainsLive) {
			grainsLive = false;
			grainGroups.do(_.free);
			grainEnvBufs.do(_.free);
			grainBuf.free;
			grainPtrBus.free;
			grainGroups = grainSynths = grainPtr = grainRec = grainFb = nil;
			grainBuf = grainEnvBufs = grainPtrBus = nil;
		};
	}

	// The group of sequence i (1-16), or nil.
	groupFor { arg i;
		i = i.asInteger;
		^if(i >= 1 and: { i <= seqCount }) { groups[i - 1] };
	}

	// The loaded buffer of slot i (1-16), or nil: an empty slot is silent.
	bufferFor { arg i;
		i = i.asInteger;
		^if(i >= 1 and: { i <= slotCount }) { buffers[i - 1] };
	}

	// The level, sends and send buses a new note starts with (the group's live sets only reach notes already playing).
	noteArgs { arg index;
		^[
			\out, context.out_b, \level, levels[index],
			\reverbOut, reverbBus, \delayOut, delayBus, \grainsOut, grainsBus,
			\reverb_send, sends[index][0], \delay_send, sends[index][1], \grains_send, sends[index][2]
		];
	}

	// Reads a sample into slot i. Always two channels: a mono file plays in both.
	loadSlot { arg i, path;
		var server = context.server;
		if(i >= 1 and: { i <= slotCount }) {
			fork {
				var file = SoundFile.openRead(path);
				var buf, old;
				if(file.notNil) {
					buf = Buffer.readChannel(server, path, channels: if(file.numChannels == 1) { [0, 0] } { [0, 1] });
					file.close;
					server.sync;
					old = buffers[i - 1];
					buffers[i - 1] = buf;
					if(old.notNil) { old.free };
				};
			};
		};
	}

	clearSlot { arg i;
		if(i >= 1 and: { i <= slotCount } and: { buffers[i - 1].notNil }) {
			buffers[i - 1].free;
			buffers[i - 1] = nil;
		};
	}

	free {
		this.freeGrains;
		delay.free;
		reverb.free;
		outStage.free;
		outGroup.free;
		reverbGroup.free;
		delayGroup.free;
		master.free;
		buffers.do { |buf| if(buf.notNil) { buf.free } };
		reverbBus.free;
		delayBus.free;
		grainsBus.free;
	}
}
