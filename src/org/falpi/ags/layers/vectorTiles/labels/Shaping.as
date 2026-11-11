package org.falpi.ags.layers.vectorTiles.labels
{
    /** Positioned glyphs of a label, in glyph units (24 per em) relative to the anchor. */
    public final class Shaping
    {
        public var glyphs:Vector.<Glyph> = new Vector.<Glyph>();
        public var xs:Vector.<Number> = new Vector.<Number>();
        public var ys:Vector.<Number> = new Vector.<Number>();
        public var left:Number = 0;
        public var top:Number = 0;
        public var right:Number = 0;
        public var bottom:Number = 0;
        /** Length of the longest line. */
        public var width:Number = 0;
        public var lineCount:int = 0;
    }
}
