package org.falpi.ags.layers
{
    import flash.events.Event;

    import org.falpi.ags.layers.supportClasses.RasterContent;
    import org.falpi.ags.layers.supportClasses.VectorContent;
    import org.falpi.ags.layers.supportClasses.tile_internal;
    import org.falpi.ags.layers.vectorTiles.style.Style;

    use namespace tile_internal;

    /**
     * A basemap layer that is either vector or raster, chosen by properties: the same tag can switch between the
     * two by configuration. It shows a vector content (as VectorTileLayer) or a raster one (as RasterTileLayer)
     * and replaces it when the configuration changes.
     *
     * <ul>
     * <li><code>layerType="vector"</code>: an Esri VectorTileServer, an ArcGIS item or a Mapbox GL style.</li>
     * <li><code>layerType="raster"</code> with <code>layerFormat="esri"</code>: an ArcGIS MapServer, as
     * ArcGISTiledMapServiceLayer.</li>
     * <li><code>layerType="raster"</code> with <code>layerFormat="tiled"</code>: a URL template, as
     * WebTiledLayer.</li>
     * </ul>
     *
     * <p>The URL can be given directly (<code>url</code>) or taken from a map of basemaps
     * (<code>layerMap</code>), selected by <code>layerSelector</code>. Every basemap of the map lists its layers,
     * the same basemap in different types and formats; the layer takes the first one that matches
     * <code>layerType</code> and <code>layerFormat</code>, so with neither of them it takes the first of the list
     * (the order of the list is the default of the application). Several layers of the same type and format are
     * alternatives in order of preference: the first is used. When none matches the layer does not load: there is
     * no fallback to another type. A basemap that is not valid stops only the layers that select it. The map is XML or JSON (text or parsed):</p>
     *
     * <listing version="3.0">
     * &lt;Basemaps&gt;
     *    &lt;Basemap id="topo" description="Topographic"&gt;
     *       &lt;Layer type="raster" format="esri" url=".../World_Topo_Map/MapServer"/&gt;
     *       &lt;Layer type="raster" format="tiled" url="https://{subDomain}.arcgisonline.com/.../tile/{level}/{row}/{col}"
     *              subDomains="services,server"/&gt;
     *       &lt;Layer type="vector" url="https://www.arcgis.com/sharing/rest/content/items/..."/&gt;
     *    &lt;/Basemap&gt;
     * &lt;/Basemaps&gt;
     *
     * {"topo": {"description": "Topographic", "layers": [
     *     {"type": "raster", "format": "esri", "url": ".../World_Topo_Map/MapServer"},
     *     {"type": "raster", "format": "tiled", "url": "...", "subDomains": ["services", "server"]},
     *     {"type": "vector", "url": "https://www.arcgis.com/sharing/rest/content/items/..."}]}}
     * </listing>
     *
     * <p>Every layer has a <code>type</code> and a <code>url</code>; a raster one has a <code>format</code>
     * ("esri" when missing). Its options are those of the properties of the same name: <code>transport</code>,
     * <code>proxyTiles</code>, <code>subDomains</code>, <code>tileServers</code> (lists, comma separated in XML),
     * <code>maxLevel</code>, <code>resampling</code>, <code>tileCacheSize</code>, <code>copyright</code>. Other
     * attributes, as <code>description</code>, are ignored.</p>
     *
     * <p>One rule decides every setting, from the strongest: the property set on the layer (in MXML or by code),
     * the option of the layer chosen from layerMap, the defaults of the kind of basemap shown
     * (<code>RasterTileLayer.defaults</code> or <code>VectorTileLayer.defaults</code>), the defaults of every tile
     * layer (<code>AbstractTileLayer.defaults</code>, which start with those of the library). The defaults of this
     * class are only the criteria that choose the basemap: <code>defaultLayerMap</code>,
     * <code>defaultLayerType</code>, <code>defaultLayerFormat</code>.</p>
     */
    public class HybridTileLayer extends AbstractTileLayer
    {
        public static const TYPE_VECTOR:String = "vector";
        public static const TYPE_RASTER:String = "raster";
        /** Raster: an ArcGIS MapServer (as ArcGISTiledMapServiceLayer). */
        public static const FORMAT_ESRI:String = RasterContent.FORMAT_ESRI;
        /** Raster: a URL template (as WebTiledLayer). */
        public static const FORMAT_TILED:String = RasterContent.FORMAT_TILED;

        // ------------------------------------------------------------------
        // static defaults
        // ------------------------------------------------------------------

        /** Default of layerType. */
        public static var defaultLayerType:String;
        /** Default of layerFormat. */
        public static var defaultLayerFormat:String;
        /** Default of layerMap. */
        public static var defaultLayerMap:Object;

        private var m_vector:VectorContent;
        private var m_raster:RasterContent;

        public function HybridTileLayer(url:String = null, proxyURL:String = null, token:String = null)
        {
            super(url, proxyURL, token);
            m_vector = new VectorContent();
            m_raster = new RasterContent();
            invalidateConfiguration();
        }

        // ------------------------------------------------------------------
        // creation by code
        // ------------------------------------------------------------------

        /**
         * A layer of a basemap of the map of basemaps (layerMap, otherwise defaultLayerMap).
         * @param layerType "vector" or "raster"; null: defaultLayerType, otherwise the first layer of the basemap
         * @param layerFormat "esri" or "tiled" for a raster layer; null: defaultLayerFormat, otherwise the first one
         * @param proxyURL proxy page; null: the defaults
         * @param proxyTiles true or false; null: the defaults
         */
        public static function fromSelector(selector:String, layerType:String = null, layerFormat:String = null,
            proxyURL:String = null, proxyTiles:Object = null):HybridTileLayer
        {
            var layer:HybridTileLayer = new HybridTileLayer(null, proxyURL);
            layer.layerSelector = selector;
            layer.layerType = layerType;
            layer.layerFormat = layerFormat;
            RasterTileLayer.applyProxyTiles(layer, proxyTiles);
            return layer;
        }

        /**
         * A layer of a URL given directly, of the type and format given.
         * @param layerType "vector" or "raster"; null: defaultLayerType, otherwise "vector"
         * @param layerFormat "esri" or "tiled" for a raster layer; null: defaultLayerFormat, otherwise "esri"
         * @param proxyURL proxy page; null: the defaults
         * @param proxyTiles true or false; null: the defaults
         */
        public static function fromParams(url:String, layerType:String = null, layerFormat:String = null,
            proxyURL:String = null, proxyTiles:Object = null):HybridTileLayer
        {
            var layer:HybridTileLayer = new HybridTileLayer(url, proxyURL);
            layer.layerType = layerType;
            layer.layerFormat = layerFormat;
            RasterTileLayer.applyProxyTiles(layer, proxyTiles);
            return layer;
        }

        // ------------------------------------------------------------------
        // selection
        // ------------------------------------------------------------------

        private var m_layerType:String;

        [Bindable("layerTypeChanged")]
        [Inspectable(enumeration="vector,raster")]
        /**
         * "vector" or "raster". Not set: defaultLayerType; if that is not set either, with layerSelector the
         * type of the layer taken from layerMap, with url "vector".
         */
        public function get layerType():String
        {
            return m_layerType;
        }

        public function set layerType(value:String):void
        {
            if (m_layerType != value)
            {
                m_layerType = value;
                invalidateConfiguration();
                dispatchEvent(new Event("layerTypeChanged"));
            }
        }

        private var m_layerFormat:String;

        [Bindable("layerFormatChanged")]
        [Inspectable(enumeration="esri,tiled")]
        /**
         * Format of a raster layer: "esri" (ArcGIS MapServer) or "tiled" (URL template). Not set:
         * defaultLayerFormat; if that is not set either, with layerSelector the format of the layer taken from
         * layerMap, with url "esri". Not used by vector layers, whose format is recognized from the content.
         */
        public function get layerFormat():String
        {
            return m_layerFormat;
        }

        public function set layerFormat(value:String):void
        {
            if (m_layerFormat != value)
            {
                m_layerFormat = value;
                invalidateConfiguration();
                dispatchEvent(new Event("layerFormatChanged"));
            }
        }

        private var m_layerSelector:String;

        [Bindable("layerSelectorChanged")]
        /** The basemap of layerMap to use (ignored when url is set). */
        public function get layerSelector():String
        {
            return m_layerSelector;
        }

        public function set layerSelector(value:String):void
        {
            if (m_layerSelector != value)
            {
                m_layerSelector = value;
                invalidateConfiguration();
                dispatchEvent(new Event("layerSelectorChanged"));
            }
        }

        private var m_layerMap:Object;

        /**
         * The basemaps, each with its layers in order of preference (see the class description): XML (or its
         * text) or JSON (parsed or its text). Not set: defaultLayerMap.
         */
        public function get layerMap():Object
        {
            return m_layerMap;
        }

        public function set layerMap(value:Object):void
        {
            m_layerMap = value;
            invalidateConfiguration();
        }

        // ------------------------------------------------------------------
        // url: it takes the place of layerMap
        // ------------------------------------------------------------------

        private var m_hybridURL:String;

        [Bindable("urlChanged")]
        /**
         * URL of the layer, which takes the place of layerMap: a vector basemap (see VectorTileLayer), an ArcGIS
         * MapServer ("raster:esri") or a URL template ("raster:tiled").
         */
        override public function get url():String
        {
            return m_hybridURL;
        }

        override public function set url(value:String):void
        {
            if (m_hybridURL != value)
            {
                m_hybridURL = value;
                invalidateConfiguration();
                dispatchEvent(new Event("urlChanged"));
            }
        }

        /** The options of the layer chosen from layerMap (transport, proxyTiles, resampling, tileCacheSize...). */
        private var m_activeOptions:Object;

        /** The options of the layer chosen from layerMap, for the settings of AbstractTileLayer and resampling. */
        override protected function layerOption(name:String):*
        {
            var value:* = m_activeOptions != null ? m_activeOptions[name] : undefined;
            if (value === null || value === undefined || (value is Number && isNaN(value)) ||
                (value is String && String(value).length == 0))
            {
                return undefined;
            }
            return value;
        }

        // ------------------------------------------------------------------
        // properties of the raster layers (set here, they take precedence over the options of layerMap)
        // ------------------------------------------------------------------

        private var m_subDomains:Array;

        /** Sub-domains that replace {subDomain} in a "tiled" template, one per row in turn. */
        public function get subDomains():Array
        {
            return m_subDomains;
        }

        public function set subDomains(value:Array):void
        {
            m_subDomains = value;
            invalidateConfiguration();
        }

        private var m_tileServers:Array;

        /** Servers that the tiles of an "esri" layer are asked to, one per row in turn. */
        public function get tileServers():Array
        {
            return m_tileServers;
        }

        public function set tileServers(value:Array):void
        {
            m_tileServers = value;
            invalidateConfiguration();
        }

        private var m_maxLevel:Number = NaN;

        /** Last level of a raster layer (see RasterTileLayer). */
        public function get maxLevel():Number
        {
            return m_maxLevel;
        }

        public function set maxLevel(value:Number):void
        {
            m_maxLevel = value;
            invalidateConfiguration();
        }

        private var m_hybridResampling:Boolean = true;
        private var m_resamplingSet:Boolean = false;

        /**
         * Whether a missing raster tile shows the enlarged part of a tile of a lower level (see RasterTileLayer).
         * Not set: the option of the layer chosen from layerMap, then RasterTileLayer.defaults. Reads the value
         * in use.
         */
        public function get resampling():Boolean
        {
            if (m_resamplingSet)
            {
                return m_hybridResampling;
            }
            var option:* = layerOption("resampling");
            return option is Boolean ? Boolean(option) : RasterContent.DEFAULTS.resampling;
        }

        public function set resampling(value:Boolean):void
        {
            m_hybridResampling = value;
            m_resamplingSet = true;
            invalidateConfiguration();
        }

        // ------------------------------------------------------------------
        // properties of the vector layers
        // ------------------------------------------------------------------

        /** Style overriding the one published at the URL (see VectorTileLayer). */
        public function get style():Object
        {
            return m_vector.style;
        }

        public function set style(value:Object):void
        {
            m_vector.style = value;
        }

        [Inspectable(enumeration="arcgis,service", defaultValue="arcgis")]
        /** Levels of detail of a vector basemap (see VectorTileLayer). */
        public function get tilingScheme():String
        {
            return m_vector.tilingScheme;
        }

        public function set tilingScheme(value:String):void
        {
            m_vector.tilingScheme = value;
        }

        /** Shows or hides the labels and icons of a vector basemap. */
        public function get labelsVisible():Boolean
        {
            return m_vector.labelsVisible;
        }

        public function set labelsVisible(value:Boolean):void
        {
            m_vector.labelsVisible = value;
        }

        /** Halo width given to the labels whose style has none (see VectorTileLayer). */
        public function get minimumHaloWidth():Number
        {
            return m_vector.minimumHaloWidth;
        }

        public function set minimumHaloWidth(value:Number):void
        {
            m_vector.minimumHaloWidth = value;
        }

        /** Color of that halo (see VectorTileLayer). */
        public function get minimumHaloColor():Number
        {
            return m_vector.minimumHaloColor;
        }

        public function set minimumHaloColor(value:Number):void
        {
            m_vector.minimumHaloColor = value;
        }

        /** Opacity of that halo (see VectorTileLayer). */
        public function get minimumHaloAlpha():Number
        {
            return m_vector.minimumHaloAlpha;
        }

        public function set minimumHaloAlpha(value:Number):void
        {
            m_vector.minimumHaloAlpha = value;
        }

        /** What the url of a vector basemap was recognized as (see VectorTileLayer); null for a raster one. */
        public function get detectedFormat():String
        {
            return content == m_vector ? m_vector.detectedFormat : null;
        }

        /** Where the style of a vector basemap comes from (see VectorTileLayer); null for a raster one. */
        public function get styleOrigin():String
        {
            return content == m_vector ? m_vector.styleOrigin : null;
        }

        /** The parsed style of a vector basemap (null otherwise). */
        public function get styleDefinition():Style
        {
            return content == m_vector ? m_vector.styleDefinition : null;
        }

        // ------------------------------------------------------------------
        // what is in use
        // ------------------------------------------------------------------

        private var m_activeType:String;
        private var m_activeFormat:String;
        private var m_activeURL:String;

        /** The type in use, once configured ("vector" or "raster"). */
        public function get activeLayerType():String
        {
            return m_activeType;
        }

        /** The format in use, once configured ("esri" or "tiled" for raster layers, null for vector ones). */
        public function get activeLayerFormat():String
        {
            return m_activeFormat;
        }

        /** The URL in use, once configured (from url or from layerMap). */
        public function get activeURL():String
        {
            return m_activeURL;
        }

        // ------------------------------------------------------------------
        // configuration
        // ------------------------------------------------------------------

        private var m_configurationDirty:Boolean = false;

        private function invalidateConfiguration():void
        {
            m_configurationDirty = true;
            invalidateProperties();
        }

        override protected function commitProperties():void
        {
            if (m_configurationDirty)
            {
                m_configurationDirty = false;
                configure();
            }
            super.commitProperties();
        }

        private function configure():void
        {
            // what is asked: null when it is not
            var type:String = nonEmpty(m_layerType, defaultLayerType, null);
            var format:String = nonEmpty(m_layerFormat, defaultLayerFormat, null);
            if (type != null && type != TYPE_VECTOR && type != TYPE_RASTER)
            {
                fail("Unknown layerType '" + type + "' (vector, raster)");
                return;
            }
            if (format != null && format != FORMAT_ESRI && format != FORMAT_TILED)
            {
                fail("Unknown layerFormat '" + format + "' (esri, tiled)");
                return;
            }

            // the URL and its options
            var target:String = m_hybridURL;
            var options:Object = {};
            if ((target == null || target.length == 0) && m_layerSelector != null && m_layerSelector.length > 0)
            {
                var source:Object = m_layerMap != null ? m_layerMap : defaultLayerMap;
                if (source == null)
                {
                    fail("layerMap is not set (layerSelector '" + m_layerSelector + "')");
                    return;
                }
                var basemaps:Object;
                try
                {
                    basemaps = readLayerMap(source);
                }
                catch (error:Error)
                {
                    fail("Invalid layerMap: " + error.message);
                    return;
                }
                if (basemaps[m_layerSelector] is String)
                {
                    fail("Invalid layerMap: " + basemaps[m_layerSelector]);
                    return;
                }
                var layers:Array = basemaps[m_layerSelector] as Array;
                if (layers == null)
                {
                    fail("layerMap has no basemap '" + m_layerSelector + "'");
                    return;
                }
                // the first layer of the list that matches the type and, for a raster one, the format asked
                var chosen:Object = null;
                for each (var layer:Object in layers)
                {
                    if ((type == null || layer.type == type) && (format == null || layer.type != TYPE_RASTER || layer.format == format))
                    {
                        chosen = layer;
                        break;
                    }
                }
                if (chosen == null)
                {
                    fail("layerMap basemap '" + m_layerSelector + "' has no layer " +
                        (type != null ? type : "") + (format != null && type != TYPE_VECTOR ? (type != null ? ":" : "format ") + format : ""));
                    return;
                }
                type = chosen.type;
                format = chosen.format;
                target = chosen.url;
                options = chosen;
            }
            else
            {
                if (type == null)
                {
                    type = TYPE_VECTOR;
                }
                if (type == TYPE_RASTER && format == null)
                {
                    format = FORMAT_ESRI;
                }
            }
            if (type == TYPE_VECTOR)
            {
                format = null;
            }
            m_activeType = type;
            m_activeFormat = format;
            m_activeURL = target;
            // every setting: the property of the layer, then the option of layerMap (layerOption), then the
            // static default
            m_activeOptions = options;

            if (type == TYPE_RASTER)
            {
                m_raster.format = format;
                m_raster.subDomains = m_subDomains != null ? m_subDomains : options.subDomains as Array;
                m_raster.tileServers = m_tileServers != null ? m_tileServers : options.tileServers as Array;
                m_raster.maxLevel = !isNaN(m_maxLevel) ? m_maxLevel : (options.maxLevel is Number ? Number(options.maxLevel) : NaN);
                m_raster.resampling = resampling;
                // a copyright set on the layer is kept by AbstractTileLayer
                m_raster.copyrightText = options.copyright is String ? String(options.copyright) : null;
                setContent(m_raster);
            }
            else
            {
                setContent(m_vector);
            }
            super.url = target;
            // a new configuration is loaded again even when the URL is the same (format, options)
            layerOptionsChanged();
        }

        private function fail(message:String):void
        {
            m_activeOptions = null;
            m_activeType = null;
            m_activeFormat = null;
            m_activeURL = null;
            // nothing of the previous configuration may stay on the map
            setContent(null);
            loadFailed(message);
        }

        private static function nonEmpty(value:String, fallback:String, last:String):String
        {
            if (value != null && value.length > 0)
            {
                return value;
            }
            return fallback != null && fallback.length > 0 ? fallback : last;
        }

        // ------------------------------------------------------------------
        // the map of basemaps
        // ------------------------------------------------------------------

        /** The last map read, and what it gave (see readLayerMap). */
        private static var s_mapSource:Object;
        private static var s_mapRead:Object;

        /**
         * Reads a layer map (XML or JSON, parsed or as text) into {basemap id: [layers]}, every layer an Object
         * {type, format (raster only), url, transport (String or null), proxyTiles and resampling (Boolean or
         * null), subDomains, tileServers (Arrays or null), maxLevel and tileCacheSize (NaN if not given), copyright}. Throws an Error with the reason
         * when it is not valid. The same map (the same object or text) is read once.
         */
        private static function readLayerMap(source:Object):Object
        {
            if (source === s_mapSource && s_mapRead != null)
            {
                return s_mapRead;
            }
            var data:Object = source;
            if (data is String)
            {
                var text:String = String(data).replace(/^\s+/, "");
                data = text.charAt(0) == "<" ? new XML(text) : JSON.parse(text);
            }
            var basemaps:Object = {};
            var id:String;
            var layers:Array;
            if (data is XML || data is XMLList)
            {
                var root:XMLList = XMLList(data);
                var entries:XMLList = new XMLList();
                for each (var node:XML in root)
                {
                    if (localName(node) == "Basemap")
                    {
                        entries += node;
                    }
                    else
                    {
                        for each (var child:XML in node.elements())
                        {
                            if (localName(child) == "Basemap")
                            {
                                entries += child;
                            }
                        }
                    }
                }
                for each (var basemap:XML in entries)
                {
                    id = String(basemap.@id);
                    layers = [];
                    for each (var element:XML in basemap.elements())
                    {
                        if (localName(element) == "Layer")
                        {
                            layers.push({type: attribute(element, "type"), format: attribute(element, "format"),
                                url: attribute(element, "url"), transport: attribute(element, "transport"),
                                proxyTiles: attribute(element, "proxyTiles"), subDomains: attribute(element, "subDomains"),
                                tileServers: attribute(element, "tileServers"), maxLevel: attribute(element, "maxLevel"),
                                resampling: attribute(element, "resampling"), tileCacheSize: attribute(element, "tileCacheSize"),
                                copyright: attribute(element, "copyright")});
                        }
                    }
                    readBasemap(basemaps, id, layers);
                }
            }
            else if (data != null)
            {
                for (id in data)
                {
                    var entry:Object = data[id];
                    layers = entry is Array ? entry as Array : (entry != null ? entry.layers as Array : null);
                    readBasemap(basemaps, id, layers != null ? layers : []);
                }
            }
            s_mapSource = source;
            s_mapRead = basemaps;
            return basemaps;
        }

        private static function localName(node:XML):String
        {
            var name:Object = node.localName();
            return name != null ? String(name) : null;
        }

        private static function attribute(node:XML, name:String):String
        {
            var list:XMLList = node.attribute(name);
            return list.length() > 0 ? String(list[0]) : null;
        }

        /** Checks the layers of a basemap and adds them, with their options in the form used by configure. */
        /**
         * Adds a basemap. One that is not valid does not stop the others: its entry is the reason (a String),
         * reported by the layers that select it.
         */
        private static function readBasemap(basemaps:Object, id:String, layers:Array):void
        {
            try
            {
                addBasemap(basemaps, id, layers);
            }
            catch (error:Error)
            {
                if (id == null || id.length == 0)
                {
                    throw error;
                }
                basemaps[id] = error.message;
            }
        }

        private static function addBasemap(basemaps:Object, id:String, layers:Array):void
        {
            if (id == null || id.length == 0)
            {
                throw new Error("a basemap has no id");
            }
            if (basemaps[id] != null)
            {
                throw new Error("basemap '" + id + "' is defined twice");
            }
            var list:Array = [];
            for each (var layer:Object in layers)
            {
                var type:String = layer.type is String ? String(layer.type) : null;
                var format:String = layer.format is String && String(layer.format).length > 0 ? String(layer.format) : null;
                if (type == TYPE_RASTER)
                {
                    format = format != null ? format : FORMAT_ESRI;
                    if (format != FORMAT_ESRI && format != FORMAT_TILED)
                    {
                        throw new Error("basemap '" + id + "': unknown format '" + format + "' (esri, tiled)");
                    }
                }
                else if (type == TYPE_VECTOR)
                {
                    format = null;
                }
                else
                {
                    throw new Error("basemap '" + id + "': unknown type '" + type + "' (vector, raster)");
                }
                var key:String = format != null ? type + ":" + format : type;
                if (!(layer.url is String) || String(layer.url).length == 0)
                {
                    throw new Error("basemap '" + id + "': layer " + key + " has no url");
                }
                var transport:String = layer.transport != null && String(layer.transport).length > 0 ? String(layer.transport) : null;
                if (transport != null && transport != TRANSPORT_FLASH && transport != TRANSPORT_JAVASCRIPT)
                {
                    throw new Error("basemap '" + id + "': layer " + key + " has an unknown transport '" + transport + "' (flash, javascript)");
                }
                list.push({type: type, format: format, url: String(layer.url), transport: transport,
                    proxyTiles: toBoolean(layer.proxyTiles, id, key, "proxyTiles"),
                    resampling: toBoolean(layer.resampling, id, key, "resampling"),
                    tileCacheSize: toMegabytes(layer.tileCacheSize, id, key),
                    subDomains: toList(layer.subDomains),
                    tileServers: toList(layer.tileServers), maxLevel: layer.maxLevel != null ? Number(layer.maxLevel) : NaN,
                    copyright: layer.copyright is String ? String(layer.copyright) : null});
            }
            basemaps[id] = list;
        }

        /** A Boolean given as such or as "true"/"false"; null when not given. */
        private static function toBoolean(value:Object, id:String, key:String, name:String):Object
        {
            if (value is Boolean)
            {
                return value;
            }
            if (value == null || String(value).length == 0)
            {
                return null;
            }
            var text:String = String(value).toLowerCase();
            if (text != "true" && text != "false")
            {
                throw new Error("basemap '" + id + "': layer " + key + " has " + name + " '" + value + "' (true, false)");
            }
            return text == "true";
        }

        /** A size in megabytes (0 or more) given as a number or as text; NaN when not given. */
        private static function toMegabytes(value:Object, id:String, key:String):Number
        {
            if (value == null || String(value).length == 0)
            {
                return NaN;
            }
            var size:Number = Number(value);
            if (isNaN(size) || size < 0)
            {
                throw new Error("basemap '" + id + "': layer " + key + " has tileCacheSize '" + value + "' (megabytes, 0 or more)");
            }
            return size;
        }

        /** A list given as an Array or as comma separated text; null when not given. */
        private static function toList(value:Object):Array
        {
            if (value == null)
            {
                return null;
            }
            var items:Array = value is Array ? (value as Array).concat() : String(value).split(",");
            var list:Array = [];
            for each (var item:Object in items)
            {
                var text:String = String(item).replace(/^\s+|\s+$/g, "");
                if (text.length > 0)
                {
                    list.push(text);
                }
            }
            return list.length > 0 ? list : null;
        }
    }
}
