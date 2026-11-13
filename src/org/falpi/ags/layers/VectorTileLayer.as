package org.falpi.ags.layers
{
    import com.esri.ags.SpatialReference;
    import com.esri.ags.events.ExtentEvent;
    import com.esri.ags.events.LayerEvent;
    import com.esri.ags.events.PanEvent;
    import com.esri.ags.events.ZoomEvent;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.geometry.MapPoint;
    import com.esri.ags.layers.TiledMapServiceLayer;
    import com.esri.ags.layers.supportClasses.LOD;
    import com.esri.ags.layers.supportClasses.TileInfo;
    import org.falpi.ags.layers.vectorTiles.labels.GlyphManager;
    import org.falpi.ags.layers.vectorTiles.labels.SymbolPlacer;
    import org.falpi.ags.layers.vectorTiles.mvt.VectorTile;
    import org.falpi.ags.layers.vectorTiles.net.ResourceLoader;
    import org.falpi.ags.layers.vectorTiles.net.ResourceRequest;
    import org.falpi.ags.layers.vectorTiles.render.SourceTile;
    import org.falpi.ags.layers.vectorTiles.render.SpriteAtlas;
    import org.falpi.ags.layers.vectorTiles.render.SymbolCandidate;
    import org.falpi.ags.layers.vectorTiles.render.TileRenderer;
    import org.falpi.ags.layers.vectorTiles.source.BasemapDefinition;
    import org.falpi.ags.layers.vectorTiles.source.BasemapResolver;
    import org.falpi.ags.layers.vectorTiles.source.TileSource;
    import org.falpi.ags.layers.vectorTiles.style.Style;

    import flash.display.Bitmap;
    import flash.display.BitmapData;
    import flash.display.DisplayObject;
    import flash.display.Sprite;
    import flash.events.Event;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.net.URLRequest;
    import flash.system.Capabilities;
    import flash.text.TextField;
    import flash.text.TextFieldAutoSize;
    import flash.text.TextFormat;
    import flash.utils.ByteArray;
    import flash.utils.getTimer;

    import mx.rpc.Fault;
    import mx.rpc.events.FaultEvent;

    /**
     * Dispatched when the basemap definition (service, style, sources) cannot be loaded.
     * A LayerEvent.LOAD_ERROR is dispatched as well.
     */
    [Event(name="fault", type="mx.rpc.events.FaultEvent")]

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
     *     &lt;vb:VectorTileLayer
     *         url="https://basemaps.arcgis.com/arcgis/rest/services/World_Basemap_v2/VectorTileServer"
     *         proxyURL="https://myserver/proxy/proxy.ashx"/&gt;
     * &lt;/esri:Map&gt;
     * </listing>
     */
    public class VectorTileLayer extends TiledMapServiceLayer
    {
        /** Levels of the classic ArcGIS Online / Google / Bing raster scheme (256 px tiles). */
        public static const SCHEME_ARCGIS:String = "arcgis";
        /** Levels declared by the vector tile service (512 px tiles). */
        public static const SCHEME_SERVICE:String = "service";

        private static const AGS_INTERNAL:Namespace = new Namespace("http://www.esri.com/2008/ags/internal");
        private static const TILE_SIZE:Number = 512;
        private static const WEB_MERCATOR_EXTENT:Number = 20037508.342787;
        private static const INCHES_PER_METER:Number = 39.37007874015748;
        private static const VIEW_MARGIN:Number = 32;
        private static const LABEL_MARGIN:Number = 128;
        private static const MAX_PARSED_TILES:int = 96;
        private static const MAX_FALLBACK_LEVELS:int = 12;
        private static const FRAME_BUDGET_MS:int = 18;

        private static const LOADING:int = 0;
        private static const QUEUED:int = 1;
        private static const DONE:int = 2;

        public function VectorTileLayer(url:String = null, proxyURL:String = null, token:String = null)
        {
            super();
            m_content = new Sprite();
            m_tileContainer = new Sprite();
            m_labelBitmap = new Bitmap();
            m_content.mouseEnabled = false;
            m_content.mouseChildren = false;
            m_content.addChild(m_tileContainer);
            m_content.addChild(m_labelBitmap);
            addChild(m_content);
            this.url = url;
            this.proxyURL = proxyURL;
            this.token = token;
        }

        // ------------------------------------------------------------------
        // state
        // ------------------------------------------------------------------

        private var m_content:Sprite;
        private var m_tileContainer:Sprite;
        private var m_labelBitmap:Bitmap;

        private var m_definitionDirty:Boolean = false;
        private var m_resolver:BasemapResolver;
        private var m_loader:ResourceLoader;
        private var m_definition:BasemapDefinition;
        private var m_grid:TileSource;
        private var m_sprites:SpriteAtlas;
        private var m_glyphs:GlyphManager;
        private var m_renderer:TileRenderer;
        private var m_placer:SymbolPlacer;

        private var m_tileInfo:TileInfo;
        private var m_fullExtent:Extent;
        private var m_initialExtent:Extent;
        private var m_spatialReference:SpatialReference;

        /** key -> tile entry (see createTile). */
        private var m_tiles:Object = {};
        private var m_renderQueue:Array = [];
        /** data tile key -> VectorTile. */
        private var m_parsed:Object = {};
        private var m_parsedOrder:Array = [];
        /** data tile key -> {request, waiters}. */
        private var m_dataRequests:Object = {};
        /** data tile keys known not to exist. */
        private var m_missing:Object = {};

        // current view: layer pixel = m_viewX + (mapX - m_mapX) / m_resolution
        private var m_hasView:Boolean = false;
        private var m_mapX:Number;
        private var m_mapY:Number;
        private var m_viewX:Number;
        private var m_viewY:Number;
        private var m_viewWidth:Number;
        private var m_viewHeight:Number;
        private var m_resolution:Number;
        private var m_zoom:Number;
        private var m_tileZoom:int = -1;

        private var m_labelsDirty:Boolean = false;
        private var m_labelsTime:int = 0;
        private var m_labelMapX:Number;
        private var m_labelMapY:Number;
        private var m_labelResolution:Number;
        private var m_updatePending:Boolean = false;
        private var m_frameListener:Boolean = false;
        private var m_panListener:Boolean = false;
        /** getTimer of the last pan or zoom step. */
        private var m_moveTime:int = -10000;
        private var m_statStart:int;
        private var m_statTiles:int;
        private var m_statPlaceCount:int;
        private var m_statPlaceMs:int;
        private var m_statRenderMs:int;
        private var m_statRenderCount:int;

        // ------------------------------------------------------------------
        // public properties
        // ------------------------------------------------------------------

        private var m_url:String;

        [Bindable("urlChanged")]
        /**
         * URL of the basemap: an Esri VectorTileServer
         * (.../VectorTileServer), an ArcGIS item with a custom style
         * (.../sharing/rest/content/items/{id}) or a Mapbox GL style
         * document (.../style.json, .../root.json, mapbox://styles/...).
         */
        public function get url():String
        {
            return m_url;
        }

        public function set url(value:String):void
        {
            if (m_url != value)
            {
                m_url = value;
                invalidateDefinition();
                dispatchEvent(new Event("urlChanged"));
            }
        }

        private var m_proxyURL:String;

        /**
         * The URL to proxy the requests through (requests are sent as proxyURL?targetURL).
         * Needed in the browser whenever the tile server has no crossdomain.xml,
         * which is the case of the Esri vector basemap servers.
         */
        public function get proxyURL():String
        {
            return m_proxyURL;
        }

        public function set proxyURL(value:String):void
        {
            if (m_proxyURL != value)
            {
                m_proxyURL = value;
                invalidateDefinition();
            }
        }

        private var m_token:String;

        /** Token or API key appended to every request (ArcGIS token, Mapbox access token, MapTiler key...). */
        public function get token():String
        {
            return m_token;
        }

        public function set token(value:String):void
        {
            if (m_token != value)
            {
                m_token = value;
                invalidateDefinition();
            }
        }

        private var m_tokenParameter:String = "token";

        /** Name of the query parameter carrying the token: "token" (ArcGIS, default), "access_token" (Mapbox), "key" (MapTiler). */
        public function get tokenParameter():String
        {
            return m_tokenParameter;
        }

        public function set tokenParameter(value:String):void
        {
            if (m_tokenParameter != value)
            {
                m_tokenParameter = value;
                invalidateDefinition();
            }
        }

        private var m_style:Object;

        /**
         * Optional style overriding the one published at the URL: a Mapbox GL
         * style as a parsed Object or as a JSON String. When the url is not
         * set the style must define its sources with absolute tile URLs.
         */
        public function get style():Object
        {
            return m_style;
        }

        public function set style(value:Object):void
        {
            m_style = value;
            invalidateDefinition();
        }

        private var m_tilingScheme:String = SCHEME_ARCGIS;

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
            return m_tilingScheme;
        }

        public function set tilingScheme(value:String):void
        {
            if (m_tilingScheme != value)
            {
                m_tilingScheme = value;
                invalidateDefinition();
            }
        }

        private var m_labelsVisible:Boolean = true;

        /** Shows or hides labels and icons (symbol layers). */
        public function get labelsVisible():Boolean
        {
            return m_labelsVisible;
        }

        public function set labelsVisible(value:Boolean):void
        {
            if (m_labelsVisible != value)
            {
                m_labelsVisible = value;
                m_labelBitmap.visible = value;
                if (value)
                {
                    requestLabels();
                }
            }
        }

        /** Maximum number of parallel HTTP requests. */
        public var maxConnections:int = 6;

        /** Diagnostics: where the time of the last completed update went. */
        public var updateTimings:String = "";

        private var m_diagnostics:Boolean = false;
        private var m_diagnosticsText:TextField;
        private var m_diagnosticsFrames:int = 0;
        private var m_diagnosticsTime:int = 0;
        private var m_diagnosticsWorst:int = 0;
        private var m_diagnosticsLast:int = 0;

        /**
         * Shows a box at the top left of the map with the player, the real frame rate and where the time
         * of the last update went (to report performance problems).
         */
        public function get diagnostics():Boolean
        {
            return m_diagnostics;
        }

        public function set diagnostics(value:Boolean):void
        {
            if (m_diagnostics == value)
            {
                return;
            }
            m_diagnostics = value;
            if (value)
            {
                addEventListener(Event.ENTER_FRAME, diagnosticsFrame);
            }
            else
            {
                removeEventListener(Event.ENTER_FRAME, diagnosticsFrame);
                if (m_diagnosticsText != null && m_diagnosticsText.parent != null)
                {
                    m_diagnosticsText.parent.removeChild(m_diagnosticsText);
                }
                m_diagnosticsText = null;
            }
        }

        private function diagnosticsFrame(event:Event):void
        {
            var now:int = getTimer();
            if (m_diagnosticsLast > 0 && now - m_diagnosticsLast > m_diagnosticsWorst)
            {
                m_diagnosticsWorst = now - m_diagnosticsLast;
            }
            m_diagnosticsLast = now;
            m_diagnosticsFrames++;
            if (stage == null || map == null || now - m_diagnosticsTime < 1000)
            {
                return;
            }
            if (m_diagnosticsText == null)
            {
                m_diagnosticsText = new TextField();
                m_diagnosticsText.autoSize = TextFieldAutoSize.LEFT;
                m_diagnosticsText.background = true;
                m_diagnosticsText.backgroundColor = 0xFFFFE0;
                m_diagnosticsText.border = true;
                m_diagnosticsText.selectable = true;
                m_diagnosticsText.defaultTextFormat = new TextFormat("_sans", 11, 0x000000);
                stage.addChild(m_diagnosticsText);
            }
            var fps:Number = m_diagnosticsFrames * 1000 / (now - m_diagnosticsTime);
            var loading:int = 0;
            var total:int = 0;
            for each (var tile:Object in m_tiles)
            {
                total++;
                if (tile.needed && tile.state != DONE)
                {
                    loading++;
                }
            }
            var onScreen:Boolean = visible;
            for (var d:DisplayObject = this; onScreen && d != null && d != stage; d = d.parent)
            {
                onScreen = d.visible;
            }
            var topLeft:Point = map.localToGlobal(new Point(0, 0));
            m_diagnosticsText.x = topLeft.x + 60;
            m_diagnosticsText.y = topLeft.y + 8;
            m_diagnosticsText.visible = onScreen;
            m_diagnosticsText.text = "VectorTileLayer " + id + " | " + Capabilities.playerType + " " + Capabilities.version +
                (Capabilities.isDebugger ? " debugger" : "") + "\n" +
                "fps " + fps.toFixed(0) + " (stage " + stage.frameRate + "), worst frame " + m_diagnosticsWorst + " ms | level " +
                map.level + ", tiles " + total + " (" + loading + " loading), queue " + m_renderQueue.length + "\n" +
                "last update: " + updateTimings;
            m_diagnosticsFrames = 0;
            m_diagnosticsTime = now;
            m_diagnosticsWorst = 0;
        }

        /** The parsed style in use (null until the layer is loaded). */
        public function get styleDefinition():Style
        {
            return m_definition != null ? m_definition.style : null;
        }

        override public function get tileInfo():TileInfo
        {
            return m_tileInfo;
        }

        override public function get fullExtent():Extent
        {
            return m_fullExtent;
        }

        override public function get initialExtent():Extent
        {
            return m_initialExtent;
        }

        override public function get spatialReference():SpatialReference
        {
            return m_spatialReference;
        }

        // ------------------------------------------------------------------
        // definition loading
        // ------------------------------------------------------------------

        private function invalidateDefinition():void
        {
            m_definitionDirty = true;
            invalidateProperties();
        }

        override protected function commitProperties():void
        {
            super.commitProperties();
            if (m_definitionDirty)
            {
                m_definitionDirty = false;
                loadDefinition();
            }
        }

        private function loadDefinition():void
        {
            if (m_resolver != null)
            {
                m_resolver.cancel();
                m_resolver = null;
            }
            if (m_loader != null)
            {
                m_loader.cancelAll();
            }
            clearTiles(true);
            m_definition = null;
            m_renderer = null;
            m_placer = null;
            m_glyphs = null;
            m_sprites = null;
            setLoaded(false);

            var styleJson:Object = m_style;
            if (styleJson is String)
            {
                try
                {
                    styleJson = JSON.parse(String(styleJson));
                }
                catch (error:Error)
                {
                    definitionFailed("Invalid style JSON: " + error.message);
                    return;
                }
            }
            if ((m_url == null || m_url.length == 0) && styleJson == null)
            {
                return;
            }
            m_loader = new ResourceLoader();
            m_loader.proxyURL = m_proxyURL;
            m_loader.token = m_token;
            m_loader.tokenParameter = m_tokenParameter;
            m_loader.maxConnections = maxConnections;
            var resolver:BasemapResolver = new BasemapResolver(m_loader);
            m_resolver = resolver;
            resolver.resolve(m_url, styleJson, function(definition:BasemapDefinition):void
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
                    definitionFailed(message);
                }
            });
        }

        private function definitionFailed(message:String):void
        {
            var fault:Fault = new Fault("VectorTileLayer.load", message);
            if (hasEventListener(FaultEvent.FAULT))
            {
                dispatchEvent(new FaultEvent(FaultEvent.FAULT, false, false, fault));
            }
            dispatchEvent(new LayerEvent(LayerEvent.LOAD_ERROR, this, fault));
        }

        private function definitionLoaded(definition:BasemapDefinition):void
        {
            m_grid = definition.primarySource;
            buildTilingScheme(definition);
            if (copyright == null && definition.copyright != null)
            {
                copyright = definition.copyright;
            }
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
                setLoaded(true);
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
            var wkid:int = 102100;
            if (serviceInfo != null && serviceInfo.spatialReference != null && serviceInfo.spatialReference.wkid)
            {
                wkid = int(serviceInfo.spatialReference.wkid);
            }
            var mercator:Boolean = wkid == 102100 || wkid == 3857 || wkid == 102113 || wkid == 900913;
            if (mercator)
            {
                wkid = 102100;
            }
            m_spatialReference = new SpatialReference(wkid);

            var info:TileInfo = new TileInfo();
            var lods:Array = [];
            var i:int;
            var resolution:Number;
            if (mercator && m_tilingScheme != SCHEME_SERVICE)
            {
                info.width = 256;
                info.height = 256;
                info.origin = new MapPoint(-WEB_MERCATOR_EXTENT, WEB_MERCATOR_EXTENT, m_spatialReference);
                for (i = 0; i <= 23; i++)
                {
                    resolution = WEB_MERCATOR_EXTENT * 2 / 256 / Math.pow(2, i);
                    lods.push(new LOD(i, resolution, resolution * 96 * INCHES_PER_METER));
                }
            }
            else if (serviceInfo != null && serviceInfo.lods is Array)
            {
                info.width = Number(serviceInfo.cols);
                info.height = Number(serviceInfo.rows);
                info.origin = new MapPoint(Number(serviceInfo.origin.x), Number(serviceInfo.origin.y), m_spatialReference);
                for each (var lod:Object in serviceInfo.lods)
                {
                    lods.push(new LOD(Number(lod.level), Number(lod.resolution), Number(lod.scale)));
                }
            }
            else
            {
                info.width = TILE_SIZE;
                info.height = TILE_SIZE;
                info.origin = new MapPoint(-WEB_MERCATOR_EXTENT, WEB_MERCATOR_EXTENT, m_spatialReference);
                for (i = 0; i <= 22; i++)
                {
                    resolution = WEB_MERCATOR_EXTENT * 2 / TILE_SIZE / Math.pow(2, i);
                    lods.push(new LOD(i, resolution, resolution * 96 * INCHES_PER_METER));
                }
            }
            info.dpi = 96;
            info.format = "pbf";
            info.spatialReference = m_spatialReference;
            info.lods = lods;
            m_tileInfo = info;

            m_fullExtent = toExtent(service != null ? service.fullExtent : null);
            if (m_fullExtent == null)
            {
                m_fullExtent = new Extent(-WEB_MERCATOR_EXTENT, -WEB_MERCATOR_EXTENT, WEB_MERCATOR_EXTENT, WEB_MERCATOR_EXTENT, m_spatialReference);
            }
            m_initialExtent = toExtent(service != null ? service.initialExtent : null);
            if (m_initialExtent == null)
            {
                m_initialExtent = m_fullExtent;
            }
        }

        private function toExtent(json:Object):Extent
        {
            if (json == null || isNaN(Number(json.xmin)) || isNaN(Number(json.xmax)))
            {
                return null;
            }
            return new Extent(Number(json.xmin), Number(json.ymin), Number(json.xmax), Number(json.ymax), m_spatialReference);
        }

        // ------------------------------------------------------------------
        // Layer / TiledMapServiceLayer integration
        // ------------------------------------------------------------------

        /** Not used: tiles are vector data loaded and drawn by this class. */
        override protected function getTileURL(level:Number, row:Number, col:Number):URLRequest
        {
            return null;
        }

        override public function refresh():void
        {
            clearTiles(true);
            invalidateLayer();
        }

        override protected function removeAllChildren():void
        {
            // the base class calls this to drop its image tiles; ours live in m_content
            clearTiles(false);
        }

        override protected function addMapListeners():void
        {
            super.addMapListeners();
            if (map != null && !m_panListener)
            {
                map.addEventListener(PanEvent.PAN_UPDATE, panUpdate, false, 0, true);
                m_panListener = true;
            }
        }

        override protected function removeMapListeners():void
        {
            super.removeMapListeners();
            if (map != null && m_panListener)
            {
                map.removeEventListener(PanEvent.PAN_UPDATE, panUpdate);
            }
            m_panListener = false;
        }

        override protected function removedHandler(event:Event):void
        {
            super.removedHandler(event);
            if (event.target == this)
            {
                clearTiles(false);
            }
        }

        override protected function zoomStartHandler(event:ZoomEvent):void
        {
            // the base implementations snapshot / rescale image tiles; we scale our own content.
            // When zoom steps follow each other the map does not update the layer in between: the tiles
            // are still laid out for an older extent, while the new animation is relative to the current
            // one. Lay them out again first, or they would jump back to their old size at every step
            rebase();
        }

        /** Lays out the existing tiles (kept as placeholders) and the labels for the current map extent. */
        private function rebase():void
        {
            if (m_definition == null || map == null || !m_hasView)
            {
                return;
            }
            m_content.x = 0;
            m_content.y = 0;
            m_content.scaleX = 1;
            m_content.scaleY = 1;
            if (!computeView())
            {
                return;
            }
            for each (var tile:Object in m_tiles)
            {
                positionTile(tile);
            }
            positionLabels();
        }

        override protected function zoomUpdateHandler(event:ZoomEvent):void
        {
            m_moveTime = getTimer();
            var scrollRect:Rectangle = viewportScrollRect();
            var width:Number = Number(internalValue(event, "width"));
            var x:Number = Number(internalValue(event, "x"));
            var y:Number = Number(internalValue(event, "y"));
            if (scrollRect == null || scrollRect.width <= 0 || isNaN(width) || isNaN(x) || isNaN(y))
            {
                return;
            }
            var ratio:Number = width / scrollRect.width;
            m_content.scaleX = ratio;
            m_content.scaleY = ratio;
            m_content.x = x + scrollRect.x - scrollRect.x * ratio;
            m_content.y = y + scrollRect.y - scrollRect.y * ratio;
        }

        override protected function zoomEndHandler(event:ZoomEvent):void
        {
            // the extent change that follows redraws the layer at the new scale
        }

        override protected function updateLayer():void
        {
            if (m_definition == null || map == null)
            {
                return;
            }
            m_updatePending = true;
            m_statStart = getTimer();
            m_statTiles = -1;
            m_statPlaceCount = 0;
            m_statPlaceMs = 0;
            m_statRenderMs = 0;
            m_statRenderCount = 0;
            m_content.x = 0;
            m_content.y = 0;
            m_content.scaleX = 1;
            m_content.scaleY = 1;
            if (!isInScaleRange || !computeView())
            {
                clearTiles(false);
                finishUpdate();
                return;
            }
            updateTiles(new Rectangle(m_viewX, m_viewY, m_viewWidth, m_viewHeight));
            positionLabels();
            requestLabels();
            checkComplete();
        }

        private function computeView():Boolean
        {
            var extent:Extent = rotatedMapExtent;
            if (extent == null)
            {
                extent = map.extent;
            }
            if (extent == null || extent.width <= 0)
            {
                return false;
            }
            var x0:Number = toScreenX(extent.xmin);
            var x1:Number = toScreenX(extent.xmax);
            var y0:Number = toScreenY(extent.ymax);
            var y1:Number = toScreenY(extent.ymin);
            if (isNaN(x0) || isNaN(x1) || x1 <= x0)
            {
                return false;
            }
            m_mapX = extent.xmin;
            m_mapY = extent.ymax;
            m_viewX = x0;
            m_viewY = y0;
            m_viewWidth = x1 - x0;
            m_viewHeight = y1 - y0;
            m_resolution = extent.width / m_viewWidth;
            var zoom:Number = Math.log(m_grid.span0 / TILE_SIZE / m_resolution) / Math.LN2;
            var rounded:Number = Math.round(zoom);
            if (Math.abs(zoom - rounded) < 0.001)
            {
                zoom = rounded;
            }
            m_zoom = zoom;
            m_hasView = true;
            return true;
        }

        private function panUpdate(event:PanEvent):void
        {
            m_moveTime = getTimer();
            if (m_definition == null || !m_hasView || !visible)
            {
                return;
            }
            var scrollRect:Rectangle = viewportScrollRect();
            if (scrollRect != null && scrollRect.width > 0)
            {
                updateTiles(scrollRect);
            }
        }

        private function viewportScrollRect():Rectangle
        {
            var viewport:Object = map != null ? internalValue(map, "viewport") : null;
            return viewport != null ? viewport.scrollRect as Rectangle : null;
        }

        private static function internalValue(target:Object, name:String):*
        {
            try
            {
                return target[new QName(AGS_INTERNAL, name)];
            }
            catch (error:Error)
            {
            }
            return undefined;
        }

        // ------------------------------------------------------------------
        // tiles
        // ------------------------------------------------------------------

        /** Makes sure the tiles covering the rectangle (layer pixels) exist, and repositions all of them. */
        private function updateTiles(rect:Rectangle):void
        {
            var z:int = Math.max(0, Math.min(30, Math.floor(m_zoom + 0.0001)));
            if (z != m_tileZoom)
            {
                m_tileZoom = z;
                m_labelBitmap.visible = false;
            }
            var span:Number = m_grid.span(z);
            var limit:int = Math.pow(2, z) - 1;
            var mapLeft:Number = m_mapX + (rect.x - VIEW_MARGIN - m_viewX) * m_resolution;
            var mapRight:Number = m_mapX + (rect.right + VIEW_MARGIN - m_viewX) * m_resolution;
            var mapTop:Number = m_mapY - (rect.y - VIEW_MARGIN - m_viewY) * m_resolution;
            var mapBottom:Number = m_mapY - (rect.bottom + VIEW_MARGIN - m_viewY) * m_resolution;
            var col0:int = Math.max(0, Math.floor((mapLeft - m_grid.originX) / span));
            var col1:int = Math.min(limit, Math.floor((mapRight - m_grid.originX) / span));
            var row0:int = Math.max(0, Math.floor((m_grid.originY - mapTop) / span));
            var row1:int = Math.min(limit, Math.floor((m_grid.originY - mapBottom) / span));
            var size:int = Math.max(1, Math.round(span / m_resolution));
            var needed:Object = {};
            var key:String;
            var tile:Object;
            if ((col1 - col0 + 1) * (row1 - row0 + 1) <= 400)
            {
                for (var row:int = row0; row <= row1; row++)
                {
                    for (var col:int = col0; col <= col1; col++)
                    {
                        key = z + "/" + col + "/" + row + "@" + size;
                        needed[key] = true;
                        if (m_tiles[key] == null)
                        {
                            createTile(key, z, col, row, size, span);
                        }
                    }
                }
            }
            for (key in m_tiles)
            {
                tile = m_tiles[key];
                tile.needed = needed[key] === true;
                if (!tile.needed && (tile.z == z && tile.size == size || tile.state != DONE))
                {
                    // same level but out of view, or an obsolete tile that never got drawn
                    removeTile(tile);
                }
                else
                {
                    positionTile(tile);
                }
            }
            startFrames();
        }

        private function createTile(key:String, z:int, col:int, row:int, size:int, span:Number):void
        {
            var tile:Object = {key: key, z: z, x: col, y: row, size: size, span: span, state: LOADING, needed: true,
                    mapX: m_grid.originX + col * span, mapY: m_grid.originY - row * span,
                    zoom: m_zoom, pending: 0, sources: {}, symbols: null, bitmap: null, dataKeys: []};
            m_tiles[key] = tile;
            tile.pending = 1;
            for each (var source:TileSource in m_definition.sources)
            {
                if (z < source.minzoom)
                {
                    continue;
                }
                requestData(tile, source, Math.min(z, source.maxzoom), 0);
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
            while (m_missing[key] === true && dataZoom > 0 && attempt < MAX_FALLBACK_LEVELS)
            {
                dataZoom--;
                attempt++;
                dz = tile.z - dataZoom;
                dataX = tile.x >> dz;
                dataY = tile.y >> dz;
                key = source.name + "|" + dataZoom + "|" + dataX + "|" + dataY;
            }
            if (m_missing[key] === true)
            {
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
                        dataFailed(pending, key, source, dataZoom);
                        return;
                    }
                    cacheParsed(key, vectorTile);
                    for (var i:int = 0; i < pending.waiters.length; i += 2)
                    {
                        var waiter:Object = pending.waiters[i];
                        if (m_tiles[waiter.key] == waiter)
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
                    dataFailed(pending, key, source, dataZoom);
                });
        }

        /** A data tile does not exist: sparse caches replace it with its closest ancestor. */
        private function dataFailed(pending:Object, key:String, source:TileSource, dataZoom:int):void
        {
            m_missing[key] = true;
            for (var i:int = 0; i < pending.waiters.length; i += 2)
            {
                var waiter:Object = pending.waiters[i];
                var attempt:int = pending.waiters[i + 1];
                if (m_tiles[waiter.key] != waiter)
                {
                    continue;
                }
                if (source.indexed && dataZoom > 0 && attempt < MAX_FALLBACK_LEVELS)
                {
                    requestData(waiter, source, dataZoom - 1, attempt + 1);
                }
                dataDone(waiter);
            }
        }

        private function attachData(tile:Object, source:TileSource, data:VectorTile, dataZoom:int, dataX:int, dataY:int):void
        {
            var scale:Number = Math.pow(2, tile.z - dataZoom);
            tile.sources[source.name] = new SourceTile(data, scale, tile.x - dataX * scale, tile.y - dataY * scale);
        }

        private function dataDone(tile:Object):void
        {
            if (--tile.pending == 0 && tile.state == LOADING)
            {
                tile.state = QUEUED;
                m_renderQueue.push(tile);
                startFrames();
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

        private function positionTile(tile:Object):void
        {
            var bitmap:Bitmap = tile.bitmap as Bitmap;
            if (bitmap == null)
            {
                return;
            }
            var x0:Number = Math.round(m_viewX + (tile.mapX - m_mapX) / m_resolution);
            var y0:Number = Math.round(m_viewY + (m_mapY - tile.mapY) / m_resolution);
            var x1:Number = Math.round(m_viewX + (tile.mapX + tile.span - m_mapX) / m_resolution);
            var y1:Number = Math.round(m_viewY + (m_mapY - tile.mapY + tile.span) / m_resolution);
            bitmap.x = x0;
            bitmap.y = y0;
            if (bitmap.bitmapData.width != x1 - x0 || bitmap.bitmapData.height != y1 - y0)
            {
                // a tile of another level kept as placeholder until the new ones are drawn
                bitmap.width = x1 - x0;
                bitmap.height = y1 - y0;
                bitmap.smoothing = true;
            }
            else
            {
                bitmap.scaleX = 1;
                bitmap.scaleY = 1;
                bitmap.smoothing = false;
            }
        }

        private function removeTile(tile:Object):void
        {
            delete m_tiles[tile.key];
            var bitmap:Bitmap = tile.bitmap as Bitmap;
            if (bitmap != null)
            {
                if (bitmap.parent != null)
                {
                    bitmap.parent.removeChild(bitmap);
                }
                bitmap.bitmapData.dispose();
                tile.bitmap = null;
            }
            // cancel the downloads nobody else waits for
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
                    if (m_tiles[pending.waiters[i].key] == pending.waiters[i])
                    {
                        alive = true;
                        break;
                    }
                }
                if (!alive)
                {
                    delete m_dataRequests[key];
                    m_loader.cancel(pending.request);
                }
            }
            tile.sources = null;
            tile.symbols = null;
            tile.state = -1;
        }

        private function clearTiles(clearData:Boolean):void
        {
            for each (var tile:Object in m_tiles)
            {
                removeTile(tile);
            }
            m_tiles = {};
            m_renderQueue = [];
            m_tileZoom = -1;
            if (m_labelBitmap.bitmapData != null)
            {
                m_labelBitmap.bitmapData.dispose();
                m_labelBitmap.bitmapData = null;
            }
            if (clearData)
            {
                m_parsed = {};
                m_parsedOrder = [];
                m_missing = {};
            }
        }

        // ------------------------------------------------------------------
        // frame loop: rendering and label placement are spread over frames
        // ------------------------------------------------------------------

        private function startFrames():void
        {
            if (!m_frameListener)
            {
                m_frameListener = true;
                addEventListener(Event.ENTER_FRAME, frameHandler);
            }
        }

        private function stopFrames():void
        {
            if (m_frameListener)
            {
                m_frameListener = false;
                removeEventListener(Event.ENTER_FRAME, frameHandler);
            }
        }

        private function frameHandler(event:Event):void
        {
            if (m_definition == null || !m_hasView)
            {
                stopFrames();
                return;
            }
            var start:int = getTimer();
            var rendered:Boolean = false;
            // while the user moves the map: under half of the frame interval, to keep pan and zoom smooth;
            // otherwise most of it, to finish sooner (the frame rate drops a little only while loading)
            var interval:Number = stage != null ? 1000 / stage.frameRate : 40;
            var budget:int = start - m_moveTime < 600 ? Math.max(4, interval * 0.45)
                                                      : Math.max(FRAME_BUDGET_MS, Math.min(40, interval * 0.8));
            while (m_renderQueue.length > 0 && getTimer() - start < budget)
            {
                var tile:Object = nextQueuedTile();
                if (tile == null)
                {
                    break;
                }
                renderTile(tile);
                rendered = true;
            }
            if (rendered)
            {
                m_labelsDirty = true;
                checkComplete();
            }
            else if (m_labelsDirty && m_renderQueue.length == 0)
            {
                // wait for a quiet moment: placing labels while tiles keep arriving would be wasted work
                if (!hasLoadingTiles() || getTimer() - m_labelsTime > 1500)
                {
                    placeLabels();
                }
            }
            if (m_renderQueue.length == 0 && !m_labelsDirty && !hasLoadingTiles())
            {
                stopFrames();
            }
        }

        /** The queued tile closest to the center of the view. */
        private function nextQueuedTile():Object
        {
            var centerX:Number = m_mapX + m_viewWidth * m_resolution / 2;
            var centerY:Number = m_mapY - m_viewHeight * m_resolution / 2;
            var best:int = -1;
            var bestDistance:Number = Number.MAX_VALUE;
            for (var i:int = m_renderQueue.length - 1; i >= 0; i--)
            {
                var tile:Object = m_renderQueue[i];
                if (tile.state != QUEUED || m_tiles[tile.key] != tile)
                {
                    m_renderQueue.splice(i, 1);
                    if (best > i)
                    {
                        best--;
                    }
                    continue;
                }
                var dx:Number = tile.mapX + tile.span / 2 - centerX;
                var dy:Number = tile.mapY - tile.span / 2 - centerY;
                var distance:Number = dx * dx + dy * dy;
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    best = i;
                }
            }
            if (best < 0)
            {
                return null;
            }
            return m_renderQueue.splice(best, 1)[0];
        }

        private function renderTile(tile:Object):void
        {
            var size:int = tile.size;
            var data:BitmapData = new BitmapData(size, size, true, 0);
            var symbols:Vector.<SymbolCandidate> = new Vector.<SymbolCandidate>();
            var renderStart:int = getTimer();
            try
            {
                m_renderer.render(data, size, tile.zoom, tile.sources, tile.x * size, tile.y * size, symbols);
            }
            catch (error:Error)
            {
                // a broken tile must not stop the others
            }
            m_statRenderMs += getTimer() - renderStart;
            m_statRenderCount++;
            tile.symbols = symbols;
            var bitmap:Bitmap = new Bitmap(data);
            tile.bitmap = bitmap;
            tile.state = DONE;
            m_tileContainer.addChild(bitmap);
            positionTile(tile);
        }

        private function hasLoadingTiles():Boolean
        {
            for each (var tile:Object in m_tiles)
            {
                if (tile.needed && tile.state != DONE)
                {
                    return true;
                }
            }
            return false;
        }

        /** When every tile of the view is drawn: drops the placeholders and notifies the update. */
        private function checkComplete():void
        {
            if (hasLoadingTiles())
            {
                return;
            }
            if (m_statTiles < 0)
            {
                m_statTiles = getTimer() - m_statStart;
            }
            for each (var tile:Object in m_tiles)
            {
                if (!tile.needed)
                {
                    removeTile(tile);
                }
            }
            if (!m_labelsDirty || !m_labelsVisible || !m_definition.style.hasSymbols)
            {
                finishUpdate();
            }
        }

        private function finishUpdate():void
        {
            if (m_updatePending)
            {
                updateTimings = "tiles " + m_statTiles + " ms (drawing " + m_statRenderMs + " ms in " + m_statRenderCount +
                    " tiles), labels placed " + m_statPlaceCount + "x in " + m_statPlaceMs + " ms, total " +
                    (getTimer() - m_statStart) + " ms";
                m_updatePending = false;
                dispatchEvent(new LayerEvent(LayerEvent.UPDATE_END, this, null, true));
            }
        }

        // ------------------------------------------------------------------
        // labels
        // ------------------------------------------------------------------

        private function requestLabels():void
        {
            if (m_definition == null || !m_hasView)
            {
                return;
            }
            m_labelsDirty = true;
            startFrames();
        }

        private function positionLabels():void
        {
            if (m_labelBitmap.bitmapData == null)
            {
                return;
            }
            if (Math.abs(m_labelResolution - m_resolution) > m_resolution * 0.0001)
            {
                m_labelBitmap.visible = false;
                return;
            }
            m_labelBitmap.x = Math.round(m_viewX + (m_labelMapX - m_mapX) / m_resolution);
            m_labelBitmap.y = Math.round(m_viewY + (m_mapY - m_labelMapY) / m_resolution);
        }

        private function placeLabels():void
        {
            m_labelsDirty = false;
            m_labelsTime = getTimer();
            if (!m_labelsVisible || m_placer == null || !m_definition.style.hasSymbols)
            {
                finishUpdate();
                return;
            }
            var width:int = Math.ceil(m_viewWidth + LABEL_MARGIN * 2);
            var height:int = Math.ceil(m_viewHeight + LABEL_MARGIN * 2);
            if (width < 1 || height < 1 || width > 8000 || height > 8000 || width * height > 16000000)
            {
                finishUpdate();
                return;
            }
            var originX:Number = Math.round(m_viewX - LABEL_MARGIN);
            var originY:Number = Math.round(m_viewY - LABEL_MARGIN);
            var list:Array = [];
            for each (var tile:Object in m_tiles)
            {
                var bitmap:Bitmap = tile.bitmap as Bitmap;
                if (tile.state == DONE && tile.needed && bitmap != null && tile.symbols != null)
                {
                    list.push({x: bitmap.x - originX, y: bitmap.y - originY, size: tile.size, symbols: tile.symbols});
                }
            }
            var overlay:BitmapData = new BitmapData(width, height, true, 0);
            var placeStart:int = getTimer();
            try
            {
                m_placer.place(overlay, m_zoom, list);
            }
            catch (error:Error)
            {
            }
            m_statPlaceCount++;
            m_statPlaceMs += getTimer() - placeStart;
            var previous:BitmapData = m_labelBitmap.bitmapData;
            m_labelBitmap.bitmapData = overlay;
            m_labelBitmap.x = originX;
            m_labelBitmap.y = originY;
            m_labelBitmap.visible = true;
            m_labelMapX = m_mapX + (originX - m_viewX) * m_resolution;
            m_labelMapY = m_mapY - (originY - m_viewY) * m_resolution;
            m_labelResolution = m_resolution;
            if (previous != null)
            {
                previous.dispose();
            }
            // labels still waiting for their glyphs: onGlyphsLoaded places them again later
            var waitingGlyphs:Boolean = m_placer.incomplete && m_glyphs != null && m_glyphs.pending > 0;
            if (!hasLoadingTiles() && !waitingGlyphs)
            {
                finishUpdate();
            }
        }
    }
}
