package org.falpi.ags.utils
{
    import com.esri.ags.SpatialReference;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.layers.supportClasses.LOD;

    /** Reading of the ArcGIS REST JSON of the tile services (MapServer, VectorTileServer). */
    public final class ServiceJson
    {
        /**
         * A spatial reference ({wkid, latestWkid}). Every Web Mercator alias becomes 102100, so that the basemaps
         * of a map agree whatever their service declares; Web Mercator when none is given.
         */
        public static function spatialReference(json:Object):SpatialReference
        {
            var wkid:Number = json != null ? Number(json.wkid) : NaN;
            if (!(wkid > 0) && json != null)
            {
                wkid = Number(json.latestWkid);
            }
            if (!(wkid > 0) || WebMercator.isWebMercator(wkid))
            {
                wkid = WebMercator.WKID;
            }
            return new SpatialReference(wkid);
        }

        /** An extent ({xmin, ymin, xmax, ymax}); null when it is missing or invalid. */
        public static function extent(json:Object, sr:SpatialReference):Extent
        {
            if (json == null || isNaN(Number(json.xmin)) || isNaN(Number(json.xmax)))
            {
                return null;
            }
            return new Extent(Number(json.xmin), Number(json.ymin), Number(json.xmax), Number(json.ymax), sr);
        }

        /** The levels of a tileInfo ([{level, resolution, scale}]), up to maxLevel when it is given. */
        public static function lods(json:Object, maxLevel:Number = NaN):Array
        {
            var list:Array = [];
            for each (var lod:Object in json as Array)
            {
                if (isNaN(maxLevel) || Number(lod.level) <= maxLevel)
                {
                    list.push(new LOD(Number(lod.level), Number(lod.resolution), Number(lod.scale)));
                }
            }
            return list;
        }
    }
}
