package org.falpi.ags.layers.vectorTiles.source
{
    import org.falpi.ags.layers.vectorTiles.net.ResourceLoader;
    import org.falpi.ags.layers.vectorTiles.net.ResourceRequest;
    import org.falpi.ags.layers.vectorTiles.style.Style;
    import org.falpi.ags.layers.vectorTiles.util.UrlUtil;

    /**
     * Turns a URL into a BasemapDefinition. The kind of resource is detected
     * from its content, so the same entry point accepts:
     * <ul>
     * <li>an Esri VectorTileServer URL (.../VectorTileServer);</li>
     * <li>an ArcGIS item URL (.../sharing/rest/content/items/{id});</li>
     * <li>any Mapbox GL style document (Esri root.json, Mapbox, MapLibre, MapTiler, OpenMapTiles...).</li>
     * </ul>
     */
    public final class BasemapResolver
    {
        private static const RASTER_SERVICE:String = "Raster tile service: VectorTileLayer needs a VectorTileServer, " +
            "an ArcGIS vector tile item or a Mapbox GL style (use ArcGISTiledMapServiceLayer for this URL)";

        private var m_loader:ResourceLoader;
        private var m_onDone:Function;
        private var m_onFail:Function;
        private var m_definition:BasemapDefinition;
        private var m_pending:int = 0;
        private var m_failed:Boolean = false;
        private var m_cancelled:Boolean = false;
        /** Service URL (no trailing slash, no query) -> Esri service JSON already loaded. */
        private var m_services:Object = {};

        public function BasemapResolver(loader:ResourceLoader)
        {
            m_loader = loader;
        }

        /**
         * Resolves the basemap.
         * @param url entry point (service, item or style URL)
         * @param styleOverride an already parsed style document replacing the one at the URL, or null
         * @param onDone function(definition:BasemapDefinition):void
         * @param onFail function(message:String):void
         */
        public function resolve(url:String, styleOverride:Object, onDone:Function, onFail:Function):void
        {
            m_onDone = onDone;
            m_onFail = onFail;
            m_definition = new BasemapDefinition();
            url = UrlUtil.normalizeMapbox(url);
            if (styleOverride != null && (url == null || url.length == 0))
            {
                useStyle(styleOverride, null);
                return;
            }
            var path:String = UrlUtil.stripQuery(url);
            if (/\/(MapServer|ImageServer)\/?$/i.test(path))
            {
                fail(RASTER_SERVICE + " [" + url + "]");
                return;
            }
            if (/\/content\/items\/[0-9a-fA-F]+\/?$/.test(path))
            {
                url = trimSlash(path) + "/resources/styles/root.json" + query(url);
            }
            else if (/\/VectorTileServer\/?$/i.test(path) && url.indexOf("f=json") < 0)
            {
                url = UrlUtil.appendQuery(url, "f=json");
            }
            var entryURL:String = url;
            m_loader.load(url, false, function(text:String, request:ResourceRequest):void
            {
                if (m_cancelled)
                {
                    return;
                }
                var json:Object = parse(text, entryURL);
                if (json == null)
                {
                    return;
                }
                if (json.layers is Array)
                {
                    useStyle(styleOverride != null ? styleOverride : json, entryURL);
                }
                else if (json.tileInfo != null && json.tileInfo.format is String && String(json.tileInfo.format).toLowerCase() != "pbf")
                {
                    fail(RASTER_SERVICE + " (tile format " + json.tileInfo.format + ") [" + entryURL + "]");
                }
                else if (json.hasOwnProperty("tileInfo") || json.hasOwnProperty("defaultStyles"))
                {
                    var serviceURL:String = trimSlash(UrlUtil.stripQuery(entryURL));
                    m_services[serviceURL] = json;
                    m_definition.esriService = json;
                    if (styleOverride != null)
                    {
                        useStyle(styleOverride, serviceURL + "/resources/styles/root.json");
                        return;
                    }
                    var styles:String = json.hasOwnProperty("defaultStyles") ? String(json.defaultStyles) : "resources/styles";
                    var styleURL:String = UrlUtil.resolve(serviceURL + "/", trimSlash(styles) + "/root.json");
                    m_loader.load(styleURL, false, function(styleText:String, styleRequest:ResourceRequest):void
                    {
                        if (m_cancelled)
                        {
                            return;
                        }
                        var styleJson:Object = parse(styleText, styleURL);
                        if (styleJson != null)
                        {
                            useStyle(styleJson, styleURL);
                        }
                    }, fail, true);
                }
                else if (json.hasOwnProperty("error"))
                {
                    fail("Service error: " + (json.error.message ? json.error.message : "unknown") + " [" + entryURL + "]");
                }
                else
                {
                    fail("Unrecognized resource (neither a style nor a VectorTileServer) [" + entryURL + "]");
                }
            }, fail, true);
        }

        public function cancel():void
        {
            m_cancelled = true;
        }

        private function useStyle(json:Object, styleURL:String):void
        {
            try
            {
                m_definition.style = new Style(json, styleURL);
            }
            catch (error:Error)
            {
                fail(error.message);
                return;
            }
            m_definition.styleURL = styleURL;
            m_pending = 1;
            var sources:Object = m_definition.style.sources;
            for (var name:String in sources)
            {
                var source:Object = sources[name];
                if (source == null || source.type != "vector")
                {
                    continue;
                }
                if (source.tiles is Array)
                {
                    addSource(name, source, styleURL, false);
                }
                else if (source.url is String)
                {
                    loadSource(name, UrlUtil.resolve(styleURL, UrlUtil.normalizeMapbox(String(source.url))));
                }
            }
            sourceDone();
        }

        private function loadSource(name:String, sourceURL:String):void
        {
            var path:String = UrlUtil.stripQuery(sourceURL);
            var serviceURL:String = trimSlash(path);
            if (m_services.hasOwnProperty(serviceURL))
            {
                addSource(name, m_services[serviceURL], serviceURL + "/", true);
                return;
            }
            var requestURL:String = sourceURL;
            var looksLikeTileJSON:Boolean = /\.json$/i.test(path) || sourceURL.indexOf("api.mapbox.com") >= 0;
            if (!looksLikeTileJSON && sourceURL.indexOf("f=json") < 0)
            {
                // Esri services need f=json; TileJSON endpoints ignore the extra parameter
                requestURL = UrlUtil.appendQuery(serviceURL + query(sourceURL), "f=json");
            }
            m_pending++;
            m_loader.load(requestURL, false, function(text:String, request:ResourceRequest):void
            {
                if (m_cancelled)
                {
                    return;
                }
                var json:Object = parse(text, requestURL);
                if (json == null)
                {
                    return;
                }
                if (json.hasOwnProperty("error") && !json.hasOwnProperty("tiles"))
                {
                    fail("Source error: " + (json.error.message ? json.error.message : "unknown") + " [" + requestURL + "]");
                    return;
                }
                var esri:Boolean = json.hasOwnProperty("tileInfo");
                if (esri && m_definition.esriService == null)
                {
                    m_definition.esriService = json;
                }
                addSource(name, json, esri ? serviceURL + "/" : sourceURL, esri);
                sourceDone();
            }, fail, true);
        }

        private function addSource(name:String, json:Object, baseURL:String, esri:Boolean):void
        {
            var source:TileSource = new TileSource();
            source.name = name;
            var q:String = baseURL == null ? "" : UrlUtil.getQuery(baseURL);
            for each (var template:* in (json.tiles as Array))
            {
                var tileURL:String = UrlUtil.resolve(baseURL, String(template));
                if (q.length > 0 && tileURL.indexOf("?") < 0 && !UrlUtil.isAbsolute(String(template)))
                {
                    tileURL = UrlUtil.appendQuery(tileURL, q);
                }
                source.tiles.push(tileURL);
            }
            if (json.hasOwnProperty("minzoom"))
            {
                source.minzoom = int(json.minzoom);
            }
            if (json.hasOwnProperty("maxzoom"))
            {
                source.maxzoom = int(json.maxzoom);
            }
            if (json.scheme == "tms")
            {
                source.scheme = "tms";
            }
            if (json.attribution is String)
            {
                source.attribution = plainText(String(json.attribution));
            }
            if (esri)
            {
                if (json.hasOwnProperty("minLOD"))
                {
                    source.minzoom = int(json.minLOD);
                }
                if (json.hasOwnProperty("maxLOD"))
                {
                    source.maxzoom = int(json.maxLOD);
                }
                source.indexed = json.type == "indexedVector";
                if (json.copyrightText is String)
                {
                    source.attribution = json.copyrightText;
                }
                var tileInfo:Object = json.tileInfo;
                if (tileInfo != null && tileInfo.origin != null && tileInfo.lods is Array && (tileInfo.lods as Array).length > 0)
                {
                    var lod0:Object = tileInfo.lods[0];
                    source.originX = Number(tileInfo.origin.x);
                    source.originY = Number(tileInfo.origin.y);
                    // tile span at the level numbered 0 of the cache
                    source.span0 = Number(lod0.resolution) * Number(tileInfo.cols) * Math.pow(2, int(lod0.level));
                }
            }
            if (source.tiles.length == 0)
            {
                return;
            }
            m_definition.sources[name] = source;
            if (m_definition.copyright == null && source.attribution != null)
            {
                m_definition.copyright = source.attribution;
            }
        }

        private function sourceDone():void
        {
            m_pending--;
            if (m_pending == 0 && !m_failed && !m_cancelled)
            {
                if (m_definition.primarySource == null)
                {
                    fail("The style has no usable vector tile source");
                    return;
                }
                m_onDone(m_definition);
            }
        }

        private function parse(text:String, url:String):Object
        {
            try
            {
                return JSON.parse(text);
            }
            catch (error:Error)
            {
                var html:Boolean = text != null && /^\s*</.test(text);
                fail((html ? "HTML page received instead of JSON (wrong URL, or a login / error page)" : "Invalid JSON: " + error.message)
                    + " [" + url + "]");
            }
            return null;
        }

        private function fail(message:String, request:ResourceRequest = null):void
        {
            if (m_failed || m_cancelled)
            {
                return;
            }
            m_failed = true;
            m_onFail(message);
        }

        /** TileJSON attributions are HTML: keeps the text only. */
        private static function plainText(html:String):String
        {
            var text:String = html.replace(/<[^>]*>/g, "");
            text = text.replace(/&copy;/gi, "©").replace(/&nbsp;/gi, " ").replace(/&lt;/gi, "<")
                .replace(/&gt;/gi, ">").replace(/&quot;/gi, "\"").replace(/&#39;/g, "'").replace(/&amp;/gi, "&");
            return text.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
        }

        private static function trimSlash(url:String):String
        {
            while (url.length > 0 && url.charAt(url.length - 1) == "/")
            {
                url = url.substr(0, url.length - 1);
            }
            return url;
        }

        private static function query(url:String):String
        {
            var q:String = UrlUtil.getQuery(url);
            return q.length > 0 ? "?" + q : "";
        }
    }
}
