package org.falpi.ags.layers.vectorTiles.source
{
    import org.falpi.ags.layers.vectorTiles.style.Style;

    /** Everything needed to draw a vector basemap: the style and its resolved tile sources. */
    public final class BasemapDefinition
    {
        /** The url is ArcGIS: an item of a portal or a VectorTileServer. */
        public static const FORMAT_ARCGIS:String = "arcgis";
        /** The url is a MapLibre / Mapbox GL style document (style specification v8). */
        public static const FORMAT_MAPLIBRE:String = "maplibre";

        /** The style is the one of the ArcGIS item (resources/styles/root.json). */
        public static const STYLE_ORIGIN_ITEM:String = "item";
        /** The style is the default one of the VectorTileServer. */
        public static const STYLE_ORIGIN_SERVICE:String = "service";
        /** The style is the document at the url. */
        public static const STYLE_ORIGIN_DOCUMENT:String = "document";
        /** The style was given by the application (style property), not downloaded: the url, if any, gives the service. */
        public static const STYLE_ORIGIN_INLINE:String = "inline";

        /** What the url was recognized as: FORMAT_ARCGIS, FORMAT_MAPLIBRE, or null without url. */
        public var detectedFormat:String;
        /** Where the style in use comes from: STYLE_ORIGIN_ITEM, _SERVICE, _DOCUMENT or _INLINE. */
        public var styleOrigin:String;

        public var style:Style;
        /** URL the style document was loaded from. */
        public var styleURL:String;
        /** Source name -> TileSource (vector sources only). */
        public var sources:Object = {};
        public var copyright:String;
        /** Raw JSON of the Esri VectorTileServer, when the basemap comes from one. */
        public var esriService:Object;

        /** The first tile source, used as reference tile grid. */
        public function get primarySource():TileSource
        {
            if (style != null)
            {
                for (var i:int = 0; i < style.layers.length; i++)
                {
                    var source:TileSource = sources[style.layers[i].source] as TileSource;
                    if (source != null)
                    {
                        return source;
                    }
                }
            }
            for each (var any:TileSource in sources)
            {
                return any;
            }
            return null;
        }
    }
}
