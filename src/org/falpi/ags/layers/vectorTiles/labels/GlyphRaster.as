package org.falpi.ags.layers.vectorTiles.labels
{
    import flash.display.BitmapData;

    /** A glyph rasterized for a given size and colors. */
    public final class GlyphRaster
    {
        /** Glyph body in the text color (null for blank glyphs). */
        public var fill:BitmapData;
        /** Halo in the halo color (null when the label has no halo). */
        public var halo:BitmapData;
        /** Size / 24: converts glyph units to pixels. */
        public var scale:Number;
        /** Whole pixels from the baseline of the line to the top of the bitmaps (the fraction is in the bitmaps). */
        public var offsetY:int;
        /** Glyphs drawn in place (GlyphManager.rasterizeAt): column of the bitmaps in the target. */
        public var offsetX:int;
    }
}
