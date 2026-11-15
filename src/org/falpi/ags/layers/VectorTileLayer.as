package org.falpi.ags.layers
{
    import org.falpi.ags.layers.supportClasses.VectorContent;
    import org.falpi.ags.layers.supportClasses.VectorTileLayerDefaults;
    import org.falpi.ags.layers.vectorTiles.source.BasemapDefinition;
    import org.falpi.ags.layers.vectorTiles.style.Style;

    /**
     * A basemap layer for the ArcGIS API for Flex that renders vector tiles
     * (Mapbox Vector Tile PBF + Mapbox GL style), meant as a replacement of
     * ArcGISTiledMapServiceLayer for the Esri vector basemaps.
     *
     * <p>The <code>url</code> can be an Esri VectorTileServer, an ArcGIS
     * item (custom style) or any Mapbox GL style document, so the same
     * class also works with Mapbox, MapLibre, MapTiler or OpenMapTiles
     * basemaps.</p>
     *
     * <listing version="3.0">
     * &lt;esri:Map&gt;
     *     &lt;falpi:VectorTileLayer
     *         url="https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer"
     *         proxyURL="https://myserver/proxy/proxy.ashx"/&gt;
     * &lt;/esri:Map&gt;
     * </listing>
     */
    public class VectorTileLayer extends AbstractTileLayer
    {
        /** Levels of the classic ArcGIS Online / Google / Bing raster scheme (256 px tiles). */
        public static const SCHEME_ARCGIS:String = VectorContent.SCHEME_ARCGIS;
        /** Levels declared by the vector tile service (512 px tiles). */
        public static const SCHEME_SERVICE:String = VectorContent.SCHEME_SERVICE;

        private var m_vector:VectorContent;

        public function VectorTileLayer(url:String = null, proxyURL:String = null, token:String = null)
        {
            super(url, proxyURL, token);
            m_vector = new VectorContent();
            setContent(m_vector);
        }

        /**
         * The defaults of the vector basemaps (HybridTileLayer included, when it shows one): the settings of every
         * tile layer for the vector basemaps only, and tilingScheme, labelsVisible and the minimum halo (see
         * TileLayerDefaults).
         */
        public static function get defaults():VectorTileLayerDefaults
        {
            return VectorContent.DEFAULTS;
        }

        /**
         * Optional style overriding the one published at the URL: a Mapbox GL
         * style as a parsed Object or as a JSON String. When the url is not
         * set the style must define its sources with absolute tile URLs.
         */
        public function get style():Object
        {
            return m_vector.style;
        }

        public function set style(value:Object):void
        {
            m_vector.style = value;
        }

        [Inspectable(enumeration="arcgis,service", defaultValue="arcgis")]
        /**
         * Levels of detail the layer gives to the Map when it is the base layer.
         * "arcgis" (default) exposes the levels of the classic raster basemaps,
         * so map.level keeps the meaning it had with ArcGISTiledMapServiceLayer;
         * "service" exposes the levels of the vector tile service (512 px tiles,
         * one level less for the same scale). Services that are not in Web
         * Mercator always use their own levels.
         */
        public function get tilingScheme():String
        {
            return m_vector.tilingScheme;
        }

        public function set tilingScheme(value:String):void
        {
            m_vector.tilingScheme = value;
        }

        /** Shows or hides labels and icons (symbol layers). */
        public function get labelsVisible():Boolean
        {
            return m_vector.labelsVisible;
        }

        public function set labelsVisible(value:Boolean):void
        {
            m_vector.labelsVisible = value;
        }

        /**
         * Halo width in pixels given to the labels whose style has none, to keep them readable on busy
         * backgrounds (default 1.5). 0 draws those labels as the style says.
         */
        public function get minimumHaloWidth():Number
        {
            return m_vector.minimumHaloWidth;
        }

        public function set minimumHaloWidth(value:Number):void
        {
            m_vector.minimumHaloWidth = value;
        }

        /**
         * Color of that halo as 0xRRGGBB. NaN (the default) picks it for each label: white behind dark
         * text, black behind light text.
         */
        public function get minimumHaloColor():Number
        {
            return m_vector.minimumHaloColor;
        }

        public function set minimumHaloColor(value:Number):void
        {
            m_vector.minimumHaloColor = value;
        }

        /** Opacity of that halo, 0 to 1 (default 0.8). */
        public function get minimumHaloAlpha():Number
        {
            return m_vector.minimumHaloAlpha;
        }

        public function set minimumHaloAlpha(value:Number):void
        {
            m_vector.minimumHaloAlpha = value;
        }

        /** detectedFormat: the url is ArcGIS (an item of a portal or a VectorTileServer). */
        public static const FORMAT_ARCGIS:String = BasemapDefinition.FORMAT_ARCGIS;
        /** detectedFormat: the url is a MapLibre / Mapbox GL style document (style specification v8). */
        public static const FORMAT_MAPLIBRE:String = BasemapDefinition.FORMAT_MAPLIBRE;
        /** styleOrigin: the style of the ArcGIS item (resources/styles/root.json). */
        public static const STYLE_ORIGIN_ITEM:String = BasemapDefinition.STYLE_ORIGIN_ITEM;
        /** styleOrigin: the default style of the VectorTileServer. */
        public static const STYLE_ORIGIN_SERVICE:String = BasemapDefinition.STYLE_ORIGIN_SERVICE;
        /** styleOrigin: the style document at the url. */
        public static const STYLE_ORIGIN_DOCUMENT:String = BasemapDefinition.STYLE_ORIGIN_DOCUMENT;
        /** styleOrigin: the style property, given by the application instead of downloaded. */
        public static const STYLE_ORIGIN_INLINE:String = BasemapDefinition.STYLE_ORIGIN_INLINE;

        /**
         * What the url was recognized as, read-only: "arcgis" (an item of a portal or a VectorTileServer) or
         * "maplibre" (a MapLibre / Mapbox GL style document); null without url, or until the layer is loaded.
         */
        public function get detectedFormat():String
        {
            return m_vector.detectedFormat;
        }

        /**
         * Where the style in use comes from, read-only (null until the layer is loaded): "item" (the style of the
         * ArcGIS item), "service" (the default style of the VectorTileServer), "document" (the style document at the
         * url) or "inline" (the style property, given by the application instead of downloaded, which replaces the style at the url: the url, if any, still gives
         * the service, its grid and extent, and the base of the relative URLs).
         */
        public function get styleOrigin():String
        {
            return m_vector.styleOrigin;
        }

        /** The parsed style in use (null until the layer is loaded). */
        public function get styleDefinition():Style
        {
            return m_vector.styleDefinition;
        }
    }
}
