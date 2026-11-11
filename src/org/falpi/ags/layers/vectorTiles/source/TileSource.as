package org.falpi.ags.layers.vectorTiles.source
{
    import org.falpi.ags.layers.vectorTiles.util.UrlUtil;

    /** A vector tile source of the style, with its tile grid. */
    public final class TileSource
    {
        public static const WEB_MERCATOR_ORIGIN:Number = 20037508.342787;

        public var name:String;
        /** Absolute tile URL templates ({z}, {x}, {y}). */
        public var tiles:Array = [];
        public var minzoom:int = 0;
        /** Deepest zoom with real tiles; deeper zooms overzoom this level. */
        public var maxzoom:int = 22;
        /** "xyz" (default) or "tms" (y axis flipped). */
        public var scheme:String = "xyz";
        public var attribution:String;
        /** True for Esri "indexed" tile caches, where missing tiles are replaced by their ancestors. */
        public var indexed:Boolean = false;

        /** Tile grid origin (top-left corner) in map units. */
        public var originX:Number = -WEB_MERCATOR_ORIGIN;
        public var originY:Number = WEB_MERCATOR_ORIGIN;
        /** Size in map units of the single tile of zoom 0. */
        public var span0:Number = WEB_MERCATOR_ORIGIN * 2;

        private var m_next:int = 0;

        public function tileURL(z:int, x:int, y:int):String
        {
            if (tiles.length == 0)
            {
                return null;
            }
            var template:String = tiles[m_next++ % tiles.length];
            var row:int = scheme == "tms" ? (1 << z) - 1 - y : y;
            return UrlUtil.template(template, {z: z, x: x, y: row});
        }

        /** Size of a tile in map units at the given zoom. */
        public function span(z:int):Number
        {
            return span0 / Math.pow(2, z);
        }
    }
}
