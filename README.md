# tabletseq

a drawing sequencer for norns, played on a wacom one pen tablet. the tablet plugs straight into
norns. a grid is optional.

x is time, y is pitch, and pen pressure is loudness. you draw sequences, start and stop them on the
bar, and layer them. it is the norns version of tabletseq for the mac.

## install

copy this folder to `/home/we/dust/code/tabletseq/` on the norns. once the repo is public,
`;install https://github.com/williamthazard/tabletseq` in maiden does the same.

the first install needs a norns restart, so the new engine (`Engine_TabletSeq`) registers.

## drawing

- a quick touch is a dot: one note. drawn on a drum voice, a dot is a hit.
- a line is a held note. its pitch glides with the pen, and its pressure shapes its loudness.
- several strokes at the same time make a chord.
- on a drum voice, a line is a roll.
- time quantize snaps notes to the grid (1/4, 1/8, 1/8 triplets, 1/16, 1/16 triplets or 1/32).
  pitch quantize snaps pitch to a root and scale (the mac's ten scales, minor pentatonic at first).
  neither changes the drawing: turn them off and it is as you drew it.
- a sequence is 1 to 64 bars long, 4 at first. it loops. what you draw past the loop end is cut.
- the pen's upper button clears the sequence; press it twice within a second. the lower button
  undoes the last stroke.
- up to 16 sequences.

## sequences and the bar

a sequence starts and stops on the next bar line of the norns clock. while it waits for the bar,
its dot blinks. ask again while it waits and it cancels. a change to a playing sequence, a new
stroke for example, takes effect from its next pass.

tempo is norns' own (PARAMETERS > CLOCK), so link, midi or crow clock just work. beats per bar is a
param, 4 at first (1 to 16). it can change only while nothing plays.

## voices

each sequence picks one:

- **sine**: a sine with the drawn pitch and loudness. goes through the effects.
- **midi synth**: one channel. glides are pitch bend, pressure is channel pressure, velocity comes
  from the start of the note. bend range is 24 at first.
- **midi kit**: each row of the canvas is a note, from c1 (36) at the bottom.
- **crow 1+2** and **crow 3+4**: pitch on the odd output (1 volt per octave, middle c at 0 v) and an
  envelope on the even one (5 v times the drawn loudness, 0 between notes). a pair is mono: the
  latest note wins, and a chord plays its highest note.
- **jf**: just friends over ii, in synthesis mode, polyphonic over its six channels.
- **w/syn**: over ii, polyphonic within its voices setting. velocity follows the pressure.
- **drum rack**: one-shot samples, one canvas row per sample. goes through the effects.

crow, jf and w/syn play the same notes as the midi synth: with pitch quantize on, a drawn line is
stepped notes; with it off, one gliding note.

default pitch ranges: sine, crow, jf and w/syn 55 to 84; midi synth 48 to 84; midi kit and drum rack
36 to 51. midi channels start at the lowest free one.

jf and w/syn module settings (jf mode; w/syn voices, lpg time, lpg symmetry, hold or pluck) are
params. they are sent when they change and when the first sequence using that voice starts, never at
stop. the first time jf plays in a session it also gets run mode 1 and run volts 0.7, and w/syn gets
a neutral fm ratio, curve, ramp and fm index. they are never changed at stop or cleanup.

the hardware targets (the midi device, each crow pair, jf and w/syn) are shared by every sequence.
stopping a sequence ends only the notes it started.

## the screen and controls

the canvas fills the screen left of a narrow info column. it shows the selected sequence's strokes
(brighter with pressure), the playhead, a faint bar grid, and the pen's hover ring. dots along the
bottom show the sequences, the selected one bright; they appear when there is more than one.

- E1: pick a sequence. one past the last is a blank page: draw on it to make a new sequence.
- E2: pick a line in the info column: voice, bars, low, high, level, quantize and grid, pitch
  quantize, root, scale, channel and bend (midi only), and the sends (sine and drum rack only).
- E3: change it.
- K2: delete the sequence. the screen says "K2 again to delete"; press again within 3 seconds.
- K3: start or stop on the bar, or cancel a wait.
- K1 stays norns'.

## the grid

optional. everything works from the keys without it.

- row 1: one key per sequence. a press starts or stops it on the bar, or cancels a wait. dim is
  stopped, bright is playing, blinking is waiting.
- row 2: a press selects that sequence on the screen.
- a 64-key grid shows sequences 1 to 8.

## the drum rack folder

in params, "drum folder" picks any file in a folder, and the whole folder loads, sorted by name, up
to 16 samples. norns comes with a folder of 808 sounds in `dust/audio`. the first sample is the
bottom row (note 36). a row with no sample is silent but keeps its strokes, so a bigger folder brings
them back. with no folder picked, the drum rack is silent.

## effects

reverb, delay and carter's delay, on the sine and the drum rack only. every sequence on those voices
has its own reverb, delay and carter's sends (0 to 1, 0 at first). the settings are params, off by
default.

- reverb: room, damp and level.
- delay: sync is "1" by default, so it lasts one beat of the norns clock and follows its tempo,
  however that is set. pick a division from 1/16 to 8 beats, or "free" for seconds.
- carter's delay: a granular delay (from schicksalslied 2) that is allocated only while its switch
  is on. its granular switches, feedback patch and grain lfo rates are in params too.

## saving

everything that is not per sequence is a param, so a norns pset saves and loads it: beats per bar,
the module settings, the midi device, the effects, the drum folder, the tablet and flip.

the sequences (every drawing and its settings, and which is selected) are saved in a file beside the
pset, `<pset>.tabletseq`, whenever a pset is written, and loaded when one is read. drawings that are
not in a pset are lost when another script loads. loading a pset stops everything first, ending
notes and gates.

## good to know

- a fresh start has one empty sine sequence.
- with no tablet, the screen says to plug it in. plugging it in or out while the script runs is fine.
- loading another script stops every sequence and ends all notes: midi note-offs, all-notes-off and
  a bend centre on each channel used, crow gates and envelopes to 0 v, jf and w/syn released. jf's
  mode is never changed.

mit license. made by william hazard.
