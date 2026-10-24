// tabletseq's engine: the sine and the drum rack's one-shots, each sequence on its own group.
// The only SuperCollider class in the script; the SynthDefs live in ts_sine.scd and ts_oneshot.scd.
// Every note starts in its sequence's group (1-16), so level and sends act live on the sounding notes.
Engine_TabletSeq : CroneEngine {
	var master, groups, levels, sends, buffers, decodeEnv;
	var reverbBus, delayBus, grainsBus;
	classvar seqCount = 16, slotCount = 16, sendNames;

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
		sine[\def].add;
		oneshot.add;
		decodeEnv = sine[\decodeEnv];
		Server.default.sync;

		// The effects' buses; the sends write to them and nothing reads them until the effects exist.
		reverbBus = Bus.audio(context.server, 2);
		delayBus = Bus.audio(context.server, 2);
		grainsBus = Bus.audio(context.server, 1);
		master = Group.new(context.xg);
		groups = seqCount.collect { Group.new(master) };
		levels = Array.fill(seqCount, 0.8);
		sends = Array.fill(seqCount, { [0, 0, 0] });
		buffers = Array.newClear(slotCount);

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
		master.free;
		buffers.do { |buf| if(buf.notNil) { buf.free } };
		reverbBus.free;
		delayBus.free;
		grainsBus.free;
	}
}
