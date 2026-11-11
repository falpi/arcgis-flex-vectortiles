package org.falpi.ags.layers.vectorTiles.labels
{
    import flash.display.BitmapData;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;

    /** A glyph of a glyph PBF: metrics plus a signed distance field rendered at 24 px. */
    public final class Glyph
    {
        /** Empty border around the glyph in the distance field, in pixels. */
        public static const BORDER:int = 3;
        /** Font size the distance fields are generated at. */
        public static const BASE_SIZE:Number = 24;

        public var id:uint;
        public var width:int;
        public var height:int;
        public var left:int;
        public var top:int;
        public var advance:Number = 0;
        /** Raw distance field, (width + 6) x (height + 6) bytes. */
        public var bitmap:ByteArray;

        private var m_sdf:BitmapData;

        /** The distance field as an opaque gray bitmap (null for blank glyphs such as the space). */
        public function get sdf():BitmapData
        {
            if (m_sdf == null && bitmap != null && width > 0 && height > 0)
            {
                var w:int = width + BORDER * 2;
                var h:int = height + BORDER * 2;
                if (bitmap.length < w * h)
                {
                    bitmap = null;
                    return null;
                }
                var pixels:ByteArray = new ByteArray();
                pixels.length = w * h * 4;
                var p:int = 0;
                for (var i:int = 0; i < w * h; i++)
                {
                    var v:uint = bitmap[i];
                    pixels[p++] = 0xff;
                    pixels[p++] = v;
                    pixels[p++] = v;
                    pixels[p++] = v;
                }
                pixels.position = 0;
                m_sdf = new BitmapData(w, h, false, 0);
                m_sdf.setPixels(new Rectangle(0, 0, w, h), pixels);
                bitmap = null;
            }
            return m_sdf;
        }
    }
}
