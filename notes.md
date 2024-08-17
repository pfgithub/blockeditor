video editor:

- all clip frames are in one list:
  - sorted by z-index
- all clip frames have one property:
  - start_time

then they're displayed as flat as possible, only stacking if they don't fit under

seems resonable

then the clip frame contains a clip which says:

- duration
- effects list
- source material (link to a block containing a video or something) & offset

we can optionally have instead of clips having a start time, they have a start time relative to a linked 'base' clip

then you can link clips to other clips and to the base clips

and since they're all in one big array, you can have a clip below the one it is linked to

and base clips would be a reorderable array so you can insert stuff and move around without having to drag everything out



problems:

- potential for duplication when splitting a clip if two people do it
  - that's fine, you'll notice


value:

Timeline:
  base_clips: Array(*Clip) // left to right order
  above_clips: Array( // top to bottom order (z index)
    ClipFrame:
      anchor: *Clip,
      start_time: u64,
  )
Clip:
  duration: u64,
  offset: u64,
  source_material: *(Video | Image | ...)

What happens if:
- One person splits a clip while another person anchors a clip to the pre-split clip
  - Splitting a clip deletes the original & spawns two new ones
  - Anchoring a clip reorders it in z index, sets its anchor, and sets its start time

The anchored clip would be moved in z order but be referencing a clip that is not in z order.
Uh oh, it's now orphaned.