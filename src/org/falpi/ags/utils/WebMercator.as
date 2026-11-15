package org.falpi.ags.utils
{
    import com.esri.ags.SpatialReference;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.geometry.MapPoint;
    import com.esri.ags.layers.supportClasses.LOD;

    /**
     * Web Mercator (wkid 102100 / 3857) and the standard grid of the web basemaps: the world is a square of
     * WORLD map units starting at (-HALF_WORLD, HALF_WORLD), divided in 2^level tiles a side at each level.
     */
    public final class WebMercator
    {
        /** Half the side of the world (map units, meters). */
        public static const HALF_WORLD:Number = 20037508.342787;
        /** The side of the world (map units, meters). */
        public static const WORLD:Number = HALF_WORLD * 2;
        /** Dots per inch of the levels (scale = resolution * DPI * INCHES_PER_METER). */
        public static const DPI:int = 96;
        public static const INCHES_PER_METER:Number = 39.37007874015748;
        /** The wkid used for every Web Mercator alias. */
        public static const WKID:int = 102100;

        /** Whether the wkid is Web Mercator (102100, 3857 and the older 102113 and 900913). */
        public static function isWebMercator(wkid:Number):Boolean
        {
            return wkid == 102100 || wkid == 3857 || wkid == 102113 || wkid == 900913;
        }

        /** Map units per pixel at a level, for tiles of tileSize pixels. */
        public static function resolution(tileSize:int, level:int):Number
        {
            return WORLD / tileSize / Math.pow(2, level);
        }

        /** The levels 0 to last of the standard grid, for tiles of tileSize pixels. */
        public static function lods(tileSize:int, last:int):Array
        {
            var list:Array = [];
            for (var level:int = 0; level <= last; level++)
            {
                var r:Number = resolution(tileSize, level);
                list.push(new LOD(level, r, r * DPI * INCHES_PER_METER));
            }
            return list;
        }

        /** The top left corner of the grid. */
        public static function origin(sr:SpatialReference):MapPoint
        {
            return new MapPoint(-HALF_WORLD, HALF_WORLD, sr);
        }

        /** The whole world. */
        public static function world(sr:SpatialReference):Extent
        {
            return new Extent(-HALF_WORLD, -HALF_WORLD, HALF_WORLD, HALF_WORLD, sr);
        }
    }
}
