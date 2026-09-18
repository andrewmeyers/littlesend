LittleSend.icon — Icon Composer bundle
=====================================

Unzip, then double-click LittleSend.icon to open it in Icon Composer,
or drag it straight into an Xcode project's asset slot.

Structure
  icon.json          layer/group manifest + background fill
  Assets/page.png    top sheet, back sheet and the copy/arrow cut-outs (alpha)
  Assets/fold.png    folded corner highlight (alpha)

Background
  The teal ground is the bundle FILL, not an asset, so Icon Composer
  derives the dark and tinted appearances and applies Liquid Glass
  to the two layers above it. Fill colour: #1A5C66 (automatic gradient).

If you'd rather work in vectors, replace the two PNGs with
final/layers/02-page.svg and 03-fold-detail.svg (same 1024 geometry).

Also in the project
  final/littlesend-1024.png   flat master, no alpha
  final/glyph-mono.svg        menu-bar template glyph
  final/appearance-*.svg      dark / tinted / clear reference renders
