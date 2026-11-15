package org.falpi.ags.layers.supportClasses
{
    import com.esri.ags.geometry.MapPoint;
    import com.esri.ags.layers.supportClasses.TileInfo;

    import flash.display.Bitmap;
    import flash.display.BitmapData;
    import flash.display.DisplayObject;
    import flash.display.Sprite;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;
    import flash.utils.clearTimeout;
    import flash.utils.getTimer;
    import flash.utils.setTimeout;

    import org.falpi.ags.layers.AbstractTileLayer;
    import org.falpi.ags.layers.vectorTiles.labels.GlyphManager;
    import org.falpi.ags.layers.vectorTiles.labels.SymbolPlacer;
    import org.falpi.ags.layers.vectorTiles.mvt.VectorTile;
    import org.falpi.ags.net.ResourceLoader;
    import org.falpi.ags.net.ResourceRequest;
    import org.falpi.ags.layers.vectorTiles.render.SourceTile;
    import org.falpi.ags.layers.vectorTiles.render.SpriteAtlas;
    import org.falpi.ags.layers.vectorTiles.render.SymbolCandidate;
    import org.falpi.ags.layers.vectorTiles.render.TileRenderer;
    import org.falpi.ags.layers.vectorTiles.source.BasemapDefinition;
    import org.falpi.ags.layers.vectorTiles.source.BasemapResolver;
    import org.falpi.ags.layers.vectorTiles.source.TileSource;
    import org.falpi.ags.layers.vectorTiles.style.Style;
    import org.falpi.ags.layers.supportClasses.tile_internal;
    import org.falpi.ags.utils.ServiceJson;
    import org.falpi.ags.utils.WebMercator;

    use namespace tile_internal;

    /**
     * Vector basemaps (Mapbox Vector Tiles in PBF + Mapbox GL style): an Esri VectorTileServer, an ArcGIS item with
     * a style or any Mapbox GL style. Draws the tiles on the CPU and places the labels in an overlay over them.
     */
    public class VectorContent extends TileContent
    {
        /** Levels of the classic ArcGIS Online / Google / Bing raster scheme (256 px tiles). */
        public static const SCHEME_ARCGIS:String = "arcgis";
        /** Levels declared by the vector tile service (512 px tiles). */
        public static const SCHEME_SERVICE:String = "service";

        /** The defaults of the vector basemaps (VectorTileLayer.defaults). */
        public static const DEFAULTS:VectorTileLayerDefaults = new VectorTileLayerDefaults();

        override public function get defaults():TileLayerDefaults
        {
            return DEFAULTS;
        }

        private static const TILE_SIZE:Number = 512;
        private static const LABEL_MARGIN:Number = 128;
        private static const MAX_PARSED_TILES:int = 96;
        private static const MAX_FALLBACK_LEVELS:int = 12;
        /** How long a data tile that failed for an unknown or temporary reason is not asked again (ms). */
        private static const RETRY_MS:int = 30000;
        /** While the map is dragged, labels are placed again when it stays still this long (ms). */
        private static const PAN_PAUSE_MS:int = 200;
        /**
         * While it moves, they are placed again at most this often (ms), and never more often than eight
         * times the last placement took: placing takes at most about an eighth of the time of the drag. These
         * placements are incremental (only the area brought into view), so they are short.
         */
        private static const PAN_INTERVAL_MS:int = 150;

        public function VectorContent()
        {
            m_labelBitmap = new Bitmap();
        }

        // ------------------------------------------------------------------
        // state
        // ------------------------------------------------------------------

        private var m_labelBitmap:Bitmap;
        /**
         * During a zoom animation the labels are split in pieces, one per symbol, that follow the point of the
         * map they belong to without being scaled (the overlay would be scaled with the tiles). They stay until
         * the labels are placed again at the new scale.
         */
        private var m_pieces:Sprite;
        /**
         * The pieces: Objects {bitmap, mapX, mapY (anchor), dx, dy (bitmap from anchor, pixels), boxes (collision
         * boxes from anchor), hidden}.
         */
        private var m_pieceList:Array;

        private var m_loader:ResourceLoader;
        private var m_resolver:BasemapResolver;
        private var m_definition:BasemapDefinition;
        private var m_grid:TileSource;
        private var m_sprites:SpriteAtlas;
        private var m_glyphs:GlyphManager;
        private var m_renderer:TileRenderer;
        private var m_placer:SymbolPlacer;

        /** data tile key -> VectorTile. */
        private var m_parsed:Object = {};
        private var m_parsedOrder:Array = [];
        /** data tile key -> {request, waiters}. */
        private var m_dataRequests:Object = {};
        /**
         * data tile keys that failed: true when they do not exist (404, empty or invalid answer), otherwise the time
         * (getTimer) until which they are not asked again (server or network errors, or a status Flash does not tell).
         */
        private var m_missing:Object = {};
        /** Timer of retryTiles (0: none) and when it fires. */
        private var m_retryTimer:uint = 0;
        private var m_retryTime:int = 0;
        private var m_tileSecurityReported:Boolean = false;

        private var m_labelsDirty:Boolean = false;
        private var m_labelsTime:int = 0;
        private var m_labelMapX:Number;
        private var m_labelMapY:Number;
        private var m_labelResolution:Number;
        /** getTimer of the last placement made during the drag. */
        private var m_panPlaced:int = 0;
        /** Milliseconds the last placement of the labels took. */
        private var m_placeMs:int = 0;
        /**
         * Something new for the labels arrived during the drag (a tile drawn, glyphs loaded) after the last
         * placement: they are placed again even if the map has not moved since.
         */
        private var m_panDirty:Boolean = false;
        /** The labels wait for a placement during the drag (set at the start of every frame). */
        private var m_panWaiting:Boolean = false;
        private var m_statPlaceCount:int;
        private var m_statPlaceMs:int;

        // ------------------------------------------------------------------
        // settings
        // ------------------------------------------------------------------

        private var m_style:Object;

        /** Style overriding the one published at the URL: a Mapbox GL style as an Object or as JSON text. */
        public function get style():Object
        {
            return m_style;
        }

        public function set style(value:Object):void
        {
            m_style = value;
            reload();
        }

        // settings of the vector basemaps: the value set on the layer (m_set), otherwise the one of DEFAULTS. The
        // fields m_tilingScheme... hold the values applied

        private var m_set:Object = {};

        private function setting(name:String):*
        {
            return m_set.hasOwnProperty(name) ? m_set[name] : DEFAULTS.getValue(name);
        }

        /** Sets the value of the layer; null (NaN) goes back to the default. */
        private function setSetting(name:String, value:*):void
        {
            if (value === null || value === undefined || (value is Number && isNaN(value) && name != "minimumHaloColor"))
            {
                delete m_set[name];
            }
            else
            {
                m_set[name] = value;
            }
        }

        private var m_tilingScheme:String = SCHEME_ARCGIS;

        /**
         * "arcgis" (levels of the classic raster basemaps) or "service" (levels of the vector service). Not set:
         * VectorTileLayer.defaults.
         */
        public function get tilingScheme():String
        {
            var value:String = setting("tilingScheme") as String;
            return value != null && value.length > 0 ? value : SCHEME_ARCGIS;
        }

        public function set tilingScheme(value:String):void
        {
            setSetting("tilingScheme", value != null && value.length > 0 ? value : null);
            if (tilingScheme != m_tilingScheme)
            {
                m_tilingScheme = tilingScheme;
                reload();
            }
        }

        private var m_labelsVisible:Boolean = true;

        /** Shows or hides labels and icons (symbol layers). Not set: VectorTileLayer.defaults. */
        public function get labelsVisible():Boolean
        {
            return setting("labelsVisible") != false;
        }

        public function set labelsVisible(value:Boolean):void
        {
            setSetting("labelsVisible", value);
            applyLabelsVisible();
        }

        private function applyLabelsVisible():void
        {
            var value:Boolean = labelsVisible;
            if (m_labelsVisible != value)
            {
                m_labelsVisible = value;
                m_labelBitmap.visible = value;
                if (!value)
                {
                    removePieces();
                }
                if (value)
                {
                    requestLabels();
                }
            }
        }

        private var m_minimumHaloWidth:Number = 1.5;
        private var m_minimumHaloColor:Number = NaN;
        private var m_minimumHaloAlpha:Number = 0.8;

        /** Halo width given to the labels whose style has none (see VectorTileLayer). */
        public function get minimumHaloWidth():Number
        {
            var value:Number = Number(setting("minimumHaloWidth"));
            return value > 0 ? value : 0;
        }

        public function set minimumHaloWidth(value:Number):void
        {
            setSetting("minimumHaloWidth", value);
            applyHaloSettings();
        }

        /** Color of that halo as 0xRRGGBB; NaN picks it for each label. */
        public function get minimumHaloColor():Number
        {
            var value:* = setting("minimumHaloColor");
            return value is Number ? Number(value) : NaN;
        }

        public function set minimumHaloColor(value:Number):void
        {
            setSetting("minimumHaloColor", value);
            applyHaloSettings();
        }

        /** Opacity of that halo, 0 to 1. */
        public function get minimumHaloAlpha():Number
        {
            var value:Number = Number(setting("minimumHaloAlpha"));
            return value > 1 ? 1 : (value > 0 ? value : 0);
        }

        public function set minimumHaloAlpha(value:Number):void
        {
            setSetting("minimumHaloAlpha", value);
            applyHaloSettings();
        }

        private function applyHaloSettings():void
        {
            var width:Number = minimumHaloWidth;
            var color:Number = minimumHaloColor;
            var alpha:Number = minimumHaloAlpha;
            if (m_minimumHaloWidth != width || String(m_minimumHaloColor) != String(color) || m_minimumHaloAlpha != alpha)
            {
                m_minimumHaloWidth = width;
                m_minimumHaloColor = color;
                m_minimumHaloAlpha = alpha;
                applyHalo();
            }
        }

        private function applyHalo():void
        {
            if (m_placer != null)
            {
                m_placer.minimumHaloWidth = m_minimumHaloWidth;
                m_placer.minimumHaloColor = m_minimumHaloColor;
                m_placer.minimumHaloAlpha = m_minimumHaloAlpha;
                requestLabels();
            }
        }

        /** What the url was recognized as: "arcgis", "maplibre", or null (no url, or not loaded yet). */
        public function get detectedFormat():String
        {
            return m_definition != null ? m_definition.detectedFormat : null;
        }

        /** Where the style in use comes from: "item", "service", "document" or "inline" (null until loaded). */
        public function get styleOrigin():String
        {
            return m_definition != null ? m_definition.styleOrigin : null;
        }

        /** The parsed style in use (null until the basemap is loaded). */
        public function get styleDefinition():Style
        {
            return m_definition != null ? m_definition.style : null;
        }

        private function reload():void
        {
            if (host != null)
            {
                host.invalidateContent();
            }
        }

        // ------------------------------------------------------------------
        // attachment and loading
        // ------------------------------------------------------------------

        override tile_internal function attach(layer:AbstractTileLayer):void
        {
            super.attach(layer);
            m_labelBitmap.visible = m_labelsVisible;
            host.tileRoot.addChild(m_labelBitmap);
        }

        override tile_internal function detach():void
        {
            if (m_labelBitmap.parent != null)
            {
                m_labelBitmap.parent.removeChild(m_labelBitmap);
            }
            super.detach();
        }

        override public function get ready():Boolean
        {
            return m_definition != null;
        }

        override public function load(loader:ResourceLoader, url:String):void
        {
            // the settings in use, with the defaults of now
            m_tilingScheme = tilingScheme;
            applyLabelsVisible();
            applyHaloSettings();
            var styleJson:Object = m_style;
            if (styleJson is String)
            {
                try
                {
                    styleJson = JSON.parse(String(styleJson));
                }
                catch (error:Error)
                {
                    host.contentFailed("Invalid style JSON: " + error.message);
                    return;
                }
            }
            if ((url == null || url.length == 0) && styleJson == null)
            {
                return;
            }
            m_loader = loader;
            var resolver:BasemapResolver = new BasemapResolver(loader);
            m_resolver = resolver;
            resolver.resolve(url, styleJson, function(definition:BasemapDefinition):void
            {
                if (m_resolver == resolver)
                {
                    m_resolver = null;
                    definitionLoaded(definition);
                }
            }, function(message:String):void
            {
                if (m_resolver == resolver)
                {
                    m_resolver = null;
                    host.contentFailed(message);
                }
            });
        }

        override public function unload():void
        {
            if (m_resolver != null)
            {
                m_resolver.cancel();
                m_resolver = null;
            }
            cancelRetry();
            m_loader = null;
            m_definition = null;
            m_renderer = null;
            m_placer = null;
            m_glyphs = null;
            m_sprites = null;
            m_grid = null;
            tileInfo = null;
            fullExtent = null;
            initialExtent = null;
            spatialReference = null;
            copyright = null;
            m_tileSecurityReported = false;
            m_labelsDirty = false;
        }

        private function definitionLoaded(definition:BasemapDefinition):void
        {
            m_grid = definition.primarySource;
            originX = m_grid.originX;
            originY = m_grid.originY;
            buildTilingScheme(definition);
            copyright = definition.copyright;
            var loader:ResourceLoader = m_loader;
            var finish:Function = function(spritesOk:Boolean):void
            {
                if (loader != m_loader)
                {
                    return;
                }
                m_definition = definition;
                m_renderer = new TileRenderer(definition.style, m_sprites);
                m_glyphs = new GlyphManager(loader);
                m_glyphs.glyphsURL = definition.style.glyphsURL;
                m_glyphs.onGlyphsLoaded = requestLabels;
                m_placer = new SymbolPlacer(m_glyphs, m_sprites);
                m_placer.minimumHaloWidth = m_minimumHaloWidth;
                m_placer.minimumHaloColor = m_minimumHaloColor;
                m_placer.minimumHaloAlpha = m_minimumHaloAlpha;
                host.contentReady();
            };
            if (definition.style.sprites != null)
            {
                m_sprites = new SpriteAtlas();
                m_sprites.load(definition.style.sprites, loader, finish);
            }
            else
            {
                m_sprites = null;
                finish(false);
            }
        }

        private function buildTilingScheme(definition:BasemapDefinition):void
        {
            var service:Object = definition.esriService;
            var serviceInfo:Object = service != null ? service.tileInfo : null;
            spatialReference = ServiceJson.spatialReference(serviceInfo != null ? serviceInfo.spatialReference : null);
            var mercator:Boolean = spatialReference.wkid == WebMercator.WKID;

            var info:TileInfo = new TileInfo();
            var lods:Array;
            if (mercator && m_tilingScheme != SCHEME_SERVICE)
            {
                // the 24 levels of the classic raster basemaps
                info.width = 256;
                info.height = 256;
                info.origin = WebMercator.origin(spatialReference);
                lods = WebMercator.lods(256, 23);
            }
            else if (serviceInfo != null && serviceInfo.lods is Array)
            {
                info.width = Number(serviceInfo.cols);
                info.height = Number(serviceInfo.rows);
                info.origin = new MapPoint(Number(serviceInfo.origin.x), Number(serviceInfo.origin.y), spatialReference);
                lods = ServiceJson.lods(serviceInfo.lods);
            }
            else
            {
                info.width = TILE_SIZE;
                info.height = TILE_SIZE;
                info.origin = WebMercator.origin(spatialReference);
                lods = WebMercator.lods(TILE_SIZE, 22);
            }
            info.dpi = WebMercator.DPI;
            info.format = "pbf";
            info.spatialReference = spatialReference;
            info.lods = lods;
            tileInfo = info;

            fullExtent = ServiceJson.extent(service != null ? service.fullExtent : null, spatialReference);
            if (fullExtent == null)
            {
                fullExtent = WebMercator.world(spatialReference);
            }
            initialExtent = ServiceJson.extent(service != null ? service.initialExtent : null, spatialReference);
            if (initialExtent == null)
            {
                initialExtent = fullExtent;
            }
        }

        // ------------------------------------------------------------------
        // tile grid
        // ------------------------------------------------------------------

        override public function levelFor(resolution:Number):Number
        {
            var zoom:Number = Math.log(m_grid.span0 / TILE_SIZE / resolution) / Math.LN2;
            var rounded:Number = Math.round(zoom);
            if (Math.abs(zoom - rounded) < 0.001)
            {
                zoom = rounded;
            }
            return zoom;
        }

        override public function tileLevel(level:int):int
        {
            return Math.max(0, Math.min(30, level));
        }

        override public function span(level:int):Number
        {
            return m_grid.span(level);
        }

        override public function worldColumns(level:int):int
        {
            return worldColumnsOf(span(level));
        }

        // ------------------------------------------------------------------
        // tiles
        // ------------------------------------------------------------------

        override public function createTile(tile:Object):void
        {
            tile.symbols = null;
            loadData(tile);
        }

        /** Asks for the data of every source of the tile; when all of it is there the tile is drawn. */
        private function loadData(tile:Object):void
        {
            tile.pending = 1;
            tile.sources = {};
            tile.dataKeys = [];
            for each (var source:TileSource in m_definition.sources)
            {
                if (tile.z < source.minzoom)
                {
                    continue;
                }
                requestData(tile, source, Math.min(tile.z, source.maxzoom), 0);
            }
            dataDone(tile);
        }

        /** Asks for the data tile covering the display tile at the given data zoom. */
        private function requestData(tile:Object, source:TileSource, dataZoom:int, attempt:int):void
        {
            var dz:int = tile.z - dataZoom;
            var dataX:int = tile.x >> dz;
            var dataY:int = tile.y >> dz;
            var key:String = source.name + "|" + dataZoom + "|" + dataX + "|" + dataY;
            // known holes of sparse (indexed) caches: go straight to the ancestor
            while (source.indexed && isMissing(key) && dataZoom > 0 && attempt < MAX_FALLBACK_LEVELS)
            {
                dataZoom--;
                attempt++;
                dz = tile.z - dataZoom;
                dataX = tile.x >> dz;
                dataY = tile.y >> dz;
                key = source.name + "|" + dataZoom + "|" + dataX + "|" + dataY;
            }
            if (isMissing(key))
            {
                if (m_missing[key] !== true)
                {
                    markIncomplete(tile, m_missing[key]);
                }
                return;
            }
            var parsed:VectorTile = m_parsed[key] as VectorTile;
            if (parsed != null)
            {
                attachData(tile, source, parsed, dataZoom, dataX, dataY);
                return;
            }
            tile.pending++;
            tile.dataKeys.push(key);
            var pending:Object = m_dataRequests[key];
            if (pending != null)
            {
                pending.waiters.push(tile, attempt);
                return;
            }
            pending = {waiters: [tile, attempt]};
            m_dataRequests[key] = pending;
            var loader:ResourceLoader = m_loader;
            var direct:Boolean = !host.proxyTiles;
            pending.request = loader.load(source.tileURL(dataZoom, dataX, dataY), true,
                function(bytes:ByteArray, request:ResourceRequest):void
                {
                    if (loader != m_loader || m_dataRequests[key] != pending)
                    {
                        return;
                    }
                    delete m_dataRequests[key];
                    var vectorTile:VectorTile = null;
                    try
                    {
                        if (bytes != null && bytes.length > 0 && bytes[0] != 0x7b && bytes[0] != 0x3c)
                        {
                            vectorTile = new VectorTile(bytes);
                        }
                    }
                    catch (error:Error)
                    {
                        vectorTile = null;
                    }
                    if (vectorTile == null)
                    {
                        dataFailed(pending, key, source, dataZoom, true);
                        return;
                    }
                    cacheParsed(key, vectorTile);
                    var tiles:Object = host.tiles;
                    for (var i:int = 0; i < pending.waiters.length; i += 2)
                    {
                        var waiter:Object = pending.waiters[i];
                        if (tiles[waiter.key] == waiter)
                        {
                            attachData(waiter, source, vectorTile, dataZoom, dataX, dataY);
                            dataDone(waiter);
                        }
                    }
                },
                function(message:String, request:ResourceRequest):void
                {
                    if (loader != m_loader || m_dataRequests[key] != pending)
                    {
                        return;
                    }
                    delete m_dataRequests[key];
                    if (direct && host.transport == AbstractTileLayer.TRANSPORT_FLASH && message.indexOf("2048") >= 0)
                    {
                        reportTileSecurity(message);
                    }
                    dataFailed(pending, key, source, dataZoom, request.status == 404 || request.status == 410);
                },
                false, direct);
        }

        /** Tiles sent without the proxy to a server that has no crossdomain.xml: said once per basemap. */
        private function reportTileSecurity(message:String):void
        {
            if (m_tileSecurityReported)
            {
                return;
            }
            m_tileSecurityReported = true;
            host.reportFault("VectorTileLayer.tiles", "The tiles cannot be read without the proxy: their " +
                "server publishes no valid crossdomain.xml (set proxyTiles to true). " + message);
        }

        /**
         * A data tile failed: sparse caches replace it with its closest ancestor. When it does not exist it is never
         * asked again (until the data is cleared); after other errors it is asked again after RETRY_MS.
         */
        private function dataFailed(pending:Object, key:String, source:TileSource, dataZoom:int, absent:Boolean):void
        {
            m_missing[key] = absent ? true : getTimer() + RETRY_MS;
            var tiles:Object = host.tiles;
            for (var i:int = 0; i < pending.waiters.length; i += 2)
            {
                var waiter:Object = pending.waiters[i];
                var attempt:int = pending.waiters[i + 1];
                if (tiles[waiter.key] != waiter)
                {
                    continue;
                }
                if (!absent)
                {
                    markIncomplete(waiter, m_missing[key]);
                }
                if (source.indexed && dataZoom > 0 && attempt < MAX_FALLBACK_LEVELS)
                {
                    requestData(waiter, source, dataZoom - 1, attempt + 1);
                }
                dataDone(waiter);
            }
        }

        /**
         * The tile is drawn without part of its data (a temporary failure): it is not kept in the cache of the layer,
         * and while it stays in view its data is asked again at retryAt (retryTiles).
         */
        private function markIncomplete(tile:Object, retryAt:int):void
        {
            tile.incomplete = true;
            tile.retryAt = Math.max(int(tile.retryAt), retryAt);
            scheduleRetry(tile.retryAt);
        }

        private function scheduleRetry(time:int):void
        {
            if (m_retryTimer != 0 && m_retryTime <= time)
            {
                return;
            }
            if (m_retryTimer != 0)
            {
                clearTimeout(m_retryTimer);
            }
            m_retryTime = time;
            m_retryTimer = setTimeout(retryTiles, Math.max(0, time - getTimer()) + 50);
        }

        private function cancelRetry():void
        {
            if (m_retryTimer != 0)
            {
                clearTimeout(m_retryTimer);
                m_retryTimer = 0;
            }
        }

        /** The incomplete tiles still in view whose time has come ask for their data again, and are drawn again. */
        private function retryTiles():void
        {
            m_retryTimer = 0;
            if (m_definition == null)
            {
                return;
            }
            var now:int = getTimer();
            var next:int = int.MAX_VALUE;
            for each (var tile:Object in host.tiles)
            {
                if (!tile.incomplete || !tile.needed)
                {
                    continue;
                }
                if (tile.state != AbstractTileLayer.DONE || tile.pending > 0)
                {
                    // still loading or being drawn: looked at again in a moment
                    next = Math.min(next, now + 1000);
                }
                else if (now >= tile.retryAt)
                {
                    tile.incomplete = false;
                    tile.retryAt = 0;
                    tile.redraw = true;
                    loadData(tile);
                }
                else
                {
                    next = Math.min(next, tile.retryAt);
                }
            }
            if (next < int.MAX_VALUE)
            {
                scheduleRetry(next);
            }
        }

        /** Whether the data tile is not to be asked: it does not exist, or it failed less than RETRY_MS ago. */
        private function isMissing(key:String):Boolean
        {
            var failed:* = m_missing[key];
            if (failed === undefined)
            {
                return false;
            }
            if (failed === true || getTimer() < failed)
            {
                return true;
            }
            delete m_missing[key];
            return false;
        }

        private function attachData(tile:Object, source:TileSource, data:VectorTile, dataZoom:int, dataX:int, dataY:int):void
        {
            var scale:Number = Math.pow(2, tile.z - dataZoom);
            tile.sources[source.name] = new SourceTile(data, scale, tile.x - dataX * scale, tile.y - dataY * scale);
        }

        private function dataDone(tile:Object):void
        {
            if (--tile.pending == 0)
            {
                host.tileReady(tile);
            }
        }

        private function cacheParsed(key:String, tile:VectorTile):void
        {
            m_parsed[key] = tile;
            m_parsedOrder.push(key);
            while (m_parsedOrder.length > MAX_PARSED_TILES)
            {
                delete m_parsed[m_parsedOrder.shift()];
            }
        }

        override public function renderTile(tile:Object):DisplayObject
        {
            var size:int = tile.size;
            var data:BitmapData = new BitmapData(size, size, true, 0);
            var symbols:Vector.<SymbolCandidate> = new Vector.<SymbolCandidate>();
            try
            {
                m_renderer.render(data, size, tile.zoom, tile.sources, tile.x * size, tile.y * size, symbols);
            }
            catch (error:Error)
            {
                // a broken tile must not stop the others
            }
            tile.symbols = symbols;
            // drawn again (retryTiles): the layer puts the new bitmap in place of the old one right away
            var previous:Bitmap = tile.display as Bitmap;
            if (previous != null && previous.bitmapData != null)
            {
                previous.bitmapData.dispose();
            }
            return new Bitmap(data);
        }

        override public function tileCached(tile:Object):void
        {
            // the data of the tile served to draw it: the bitmap and the symbols of its labels are what stays
            tile.sources = null;
        }

        override public function releaseTile(tile:Object):void
        {
            var bitmap:Bitmap = tile.display as Bitmap;
            if (bitmap != null && bitmap.bitmapData != null)
            {
                bitmap.bitmapData.dispose();
            }
            // cancel the downloads nobody else waits for
            var tiles:Object = host.tiles;
            for each (var key:String in tile.dataKeys)
            {
                var pending:Object = m_dataRequests[key];
                if (pending == null)
                {
                    continue;
                }
                var alive:Boolean = false;
                for (var i:int = 0; i < pending.waiters.length; i += 2)
                {
                    if (tiles[pending.waiters[i].key] == pending.waiters[i])
                    {
                        alive = true;
                        break;
                    }
                }
                if (!alive)
                {
                    delete m_dataRequests[key];
                    if (m_loader != null)
                    {
                        m_loader.cancel(pending.request);
                    }
                }
            }
            tile.sources = null;
            tile.symbols = null;
        }

        override public function clearData():void
        {
            m_parsed = {};
            m_parsedOrder = [];
            m_missing = {};
            cancelRetry();
        }

        override public function clear():void
        {
            removePieces();
            if (m_labelBitmap.bitmapData != null)
            {
                m_labelBitmap.bitmapData.dispose();
                m_labelBitmap.bitmapData = null;
            }
        }

        // ------------------------------------------------------------------
        // frames
        // ------------------------------------------------------------------

        override public function frameStart(now:int):Boolean
        {
            // dragging: the labels of the area brought into view are placed while the button is still held,
            // at intervals while the map moves and as soon as it stays still for a moment. In that frame no
            // tile is drawn, so that the two costs do not add up
            var moveTime:int = host.moveTime;
            m_panWaiting = host.panning && m_labelsVisible && m_definition.style.hasSymbols &&
                (moveTime > m_panPlaced || m_panDirty);
            var paused:Boolean = moveTime > m_panPlaced && now - moveTime >= PAN_PAUSE_MS;
            if (m_panWaiting && (paused || now - m_panPlaced >= Math.max(PAN_INTERVAL_MS, m_placeMs * 8)))
            {
                m_panDirty = false;
                var scrollRect:Rectangle = host.viewportScrollRect();
                if (scrollRect != null && scrollRect.width > 0)
                {
                    placeLabels(scrollRect);
                }
                m_panPlaced = getTimer();
                return true;
            }
            return false;
        }

        override public function tilesRendered():void
        {
            m_labelsDirty = true;
            m_panDirty = true;
        }

        override public function idle(now:int, loading:Boolean):void
        {
            if (m_labelsDirty && !host.panning && (host.panEndTime == 0 || now - host.panEndTime > 1000))
            {
                // after a drag, the labels wait for the new extent (a release without movement has none)
                host.panEndTime = 0;
                // wait for a quiet moment: placing labels while tiles keep arriving would be wasted work
                if (!loading || getTimer() - m_labelsTime > 1500)
                {
                    placeLabels();
                }
            }
        }

        override public function get busy():Boolean
        {
            return m_labelsDirty || m_panWaiting;
        }

        override public function get settled():Boolean
        {
            return !m_labelsDirty || !m_labelsVisible || !m_definition.style.hasSymbols;
        }

        override public function get timings():String
        {
            return "labels placed " + m_statPlaceCount + "x in " + m_statPlaceMs + " ms, ";
        }

        override public function resetStats():void
        {
            m_statPlaceCount = 0;
            m_statPlaceMs = 0;
        }

        // ------------------------------------------------------------------
        // view
        // ------------------------------------------------------------------

        override public function viewChanged():void
        {
            positionLabels();
            positionPieces();
            requestLabels();
        }

        override public function levelChanged():void
        {
            m_labelBitmap.visible = false;
        }

        override public function rebased():void
        {
            positionLabels();
            positionPieces();
        }

        override public function zoomStarted():void
        {
            splitLabels();
        }

        override public function zoomUpdated():void
        {
            positionPieces();
        }

        override public function panStarted():void
        {
            m_panPlaced = getTimer();
            m_panDirty = false;
        }

        override public function panMoved():void
        {
            if (host.panning && m_labelsVisible && m_definition.style.hasSymbols)
            {
                // the frame loop watches for a pause of the drag (see frameStart)
                host.startFrames();
            }
        }

        // ------------------------------------------------------------------
        // labels
        // ------------------------------------------------------------------

        private function requestLabels():void
        {
            if (m_definition == null || host == null || !host.hasView)
            {
                return;
            }
            m_labelsDirty = true;
            m_panDirty = true;
            host.startFrames();
        }

        private function positionLabels():void
        {
            if (m_labelBitmap.bitmapData == null)
            {
                return;
            }
            var resolution:Number = host.resolution;
            if (Math.abs(m_labelResolution - resolution) > resolution * 0.0001)
            {
                m_labelBitmap.visible = false;
                return;
            }
            m_labelBitmap.x = Math.round(host.viewX + (m_labelMapX - host.mapX) / resolution);
            m_labelBitmap.y = Math.round(host.viewY + (host.mapY - m_labelMapY) / resolution);
        }

        /**
         * Places the labels of the view into a new overlay.
         * @param area while the map is dragged: the visible rectangle in layer pixels. The update is not
         *        over: the labels are placed again for the final view when the drag ends
         */
        private function placeLabels(area:Rectangle = null):void
        {
            var interim:Boolean = area != null;
            // the labels placed at the new scale replace the pieces of the zoom animation
            removePieces();
            if (!interim)
            {
                m_labelsDirty = false;
                m_labelsTime = getTimer();
            }
            if (!m_labelsVisible || m_placer == null || !m_definition.style.hasSymbols)
            {
                if (!interim && !host.hasLoadingTiles())
                {
                    host.finishUpdate();
                }
                return;
            }
            var viewX:Number = host.viewX;
            var viewY:Number = host.viewY;
            if (!interim)
            {
                area = new Rectangle(viewX, viewY, host.viewWidth, host.viewHeight);
            }
            var width:int = Math.ceil(area.width + LABEL_MARGIN * 2);
            var height:int = Math.ceil(area.height + LABEL_MARGIN * 2);
            if (width < 1 || height < 1 || width > 8000 || height > 8000 || width * height > 16000000)
            {
                if (!interim && !host.hasLoadingTiles())
                {
                    host.finishUpdate();
                }
                return;
            }
            var originX:Number = Math.round(area.x - LABEL_MARGIN);
            var originY:Number = Math.round(area.y - LABEL_MARGIN);
            var list:Array = [];
            for each (var tile:Object in host.tiles)
            {
                var bitmap:Bitmap = tile.display as Bitmap;
                if (tile.state == AbstractTileLayer.DONE && tile.needed && bitmap != null && tile.symbols != null)
                {
                    list.push({x: bitmap.x - originX, y: bitmap.y - originY, size: tile.size, symbols: tile.symbols,
                        row: tile.y, col: tile.column});
                }
            }
            // a fixed order: between symbols of the same priority the first one wins, and the order of the tiles
            // of the layer depends on when they were created and dropped
            list.sortOn(["row", "col"], Array.NUMERIC);
            var overlay:BitmapData = new BitmapData(width, height, true, 0);
            var placeStart:int = getTimer();
            var previous:BitmapData = m_labelBitmap.bitmapData;
            var resolution:Number = host.resolution;
            var zoom:Number = host.zoom;
            // while dragging, at the same scale: the labels already shown are kept (copied to the new origin) and
            // only the symbols of the area brought into view are placed
            var incremental:Boolean = interim && previous != null && m_labelBitmap.visible &&
                Math.abs(m_labelResolution - resolution) <= resolution * 0.0001;
            try
            {
                if (incremental)
                {
                    overlay.copyPixels(previous, previous.rect,
                        new Point(Math.round(m_labelBitmap.x - originX), Math.round(m_labelBitmap.y - originY)));
                    m_placer.placeMore(overlay, zoom, list, originX, originY);
                }
                else
                {
                    m_placer.place(overlay, zoom, list, originX, originY);
                }
            }
            catch (error:Error)
            {
            }
            m_placeMs = getTimer() - placeStart;
            m_statPlaceCount++;
            m_statPlaceMs += m_placeMs;
            m_labelBitmap.bitmapData = overlay;
            m_labelBitmap.x = originX;
            m_labelBitmap.y = originY;
            m_labelBitmap.visible = true;
            m_labelMapX = host.mapX + (originX - viewX) * resolution;
            m_labelMapY = host.mapY - (originY - viewY) * resolution;
            m_labelResolution = resolution;
            if (previous != null)
            {
                previous.dispose();
            }
            // labels still waiting for their glyphs: onGlyphsLoaded places them again later
            var waitingGlyphs:Boolean = m_placer.incomplete && m_glyphs != null && m_glyphs.pending > 0;
            if (!interim && !host.hasLoadingTiles() && !waitingGlyphs)
            {
                host.finishUpdate();
            }
        }

        /** Splits the label overlay into one piece per symbol (see m_pieces). */
        private function splitLabels():void
        {
            var overlay:BitmapData = m_labelBitmap.bitmapData;
            if (m_pieces != null || m_placer == null || !m_labelsVisible || overlay == null || !m_labelBitmap.visible)
            {
                return;
            }
            var shown:Array = m_placer.shownSymbols();
            // every pixel goes to one piece only: where two symbols touch, the overlay must not be drawn twice
            var work:BitmapData = overlay.clone();
            m_pieces = new Sprite();
            m_pieces.mouseEnabled = false;
            m_pieces.mouseChildren = false;
            m_pieceList = [];
            var origin:Point = new Point(0, 0);
            for each (var symbol:Object in shown)
            {
                var area:Rectangle = (symbol.drawn as Rectangle).intersection(work.rect);
                area.x = Math.floor(area.x);
                area.y = Math.floor(area.y);
                area.width = Math.ceil(area.width);
                area.height = Math.ceil(area.height);
                if (area.width < 1 || area.height < 1)
                {
                    continue;
                }
                var data:BitmapData = new BitmapData(area.width, area.height, true, 0);
                data.copyPixels(work, area, origin);
                work.fillRect(area, 0);
                var bitmap:Bitmap = new Bitmap(data);
                m_pieces.addChild(bitmap);
                var boxes:Vector.<Number> = symbol.boxes;
                for (var i:int = 0; i < boxes.length; i += 2)
                {
                    boxes[i] -= symbol.x;
                    boxes[i + 1] -= symbol.y;
                }
                m_pieceList.push({bitmap: bitmap, hidden: false, boxes: boxes,
                    mapX: m_labelMapX + symbol.x * m_labelResolution, mapY: m_labelMapY - symbol.y * m_labelResolution,
                    dx: area.x - symbol.x, dy: area.y - symbol.y});
            }
            work.dispose();
            host.addChild(m_pieces);
            m_labelBitmap.visible = false;
            positionPieces();
        }

        /**
         * Puts every piece where its point of the map is now, at its own size. When the labels come closer than
         * they were placed (zooming out), the ones that would overlap a more important one are hidden, and stay
         * hidden: labels that come back and forth would flicker.
         */
        private function positionPieces():void
        {
            var resolution:Number = host.resolution;
            if (m_pieces == null || resolution <= 0)
            {
                return;
            }
            var root:Sprite = host.tileRoot;
            var scale:Number = root.scaleX;
            var offsetX:Number = root.x;
            var offsetY:Number = root.y;
            var viewX:Number = host.viewX;
            var viewY:Number = host.viewY;
            var mapX:Number = host.mapX;
            var mapY:Number = host.mapY;
            var closer:Boolean = m_labelResolution / resolution * scale < 0.999;
            var cells:Object = closer ? {} : null;
            for each (var piece:Object in m_pieceList)
            {
                var bitmap:Bitmap = piece.bitmap;
                var x:Number = offsetX + (viewX + (piece.mapX - mapX) / resolution) * scale;
                var y:Number = offsetY + (viewY + (mapY - piece.mapY) / resolution) * scale;
                bitmap.x = Math.round(x + piece.dx);
                bitmap.y = Math.round(y + piece.dy);
                if (cells == null || piece.hidden)
                {
                    continue;
                }
                // the collision boxes of the placement, which do not overlap where the labels were placed
                if (overlapsPieces(cells, piece.boxes, x, y, false))
                {
                    piece.hidden = true;
                    bitmap.visible = false;
                }
                else
                {
                    overlapsPieces(cells, piece.boxes, x, y, true);
                }
            }
        }

        /** Grid of the boxes of the pieces kept: tells whether some of the boxes overlap them, or adds them. */
        private static function overlapsPieces(cells:Object, boxes:Vector.<Number>, x:Number, y:Number, add:Boolean):Boolean
        {
            var size:Number = 64;
            // the boxes include the padding of the style and touch where labels were placed close together:
            // a few pixels of tolerance, so that labels are hidden only when they really come over each other
            var tolerance:Number = 3;
            for (var b:int = 0; b < boxes.length; b += 4)
            {
                var x1:Number = boxes[b] + x + tolerance;
                var y1:Number = boxes[int(b + 1)] + y + tolerance;
                var x2:Number = Math.max(x1, boxes[int(b + 2)] + x - tolerance);
                var y2:Number = Math.max(y1, boxes[int(b + 3)] + y - tolerance);
                for (var cx:int = Math.floor(x1 / size); cx <= Math.floor(x2 / size); cx++)
                {
                    for (var cy:int = Math.floor(y1 / size); cy <= Math.floor(y2 / size); cy++)
                    {
                        var key:String = cx + "," + cy;
                        var cell:Array = cells[key] as Array;
                        if (add)
                        {
                            if (cell == null)
                            {
                                cell = cells[key] = [];
                            }
                            cell.push(x1, y1, x2, y2);
                            continue;
                        }
                        if (cell == null)
                        {
                            continue;
                        }
                        for (var i:int = 0; i < cell.length; i += 4)
                        {
                            if (x1 < cell[i + 2] && x2 > cell[i] && y1 < cell[i + 3] && y2 > cell[i + 1])
                            {
                                return true;
                            }
                        }
                    }
                }
            }
            return false;
        }

        private function removePieces():void
        {
            if (m_pieces == null)
            {
                return;
            }
            for each (var piece:Object in m_pieceList)
            {
                (piece.bitmap as Bitmap).bitmapData.dispose();
            }
            if (m_pieces.parent != null)
            {
                m_pieces.parent.removeChild(m_pieces);
            }
            m_pieces = null;
            m_pieceList = null;
        }
    }
}
