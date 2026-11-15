package org.falpi.ags.layers
{
    import com.esri.ags.Map;
    import com.esri.ags.SpatialReference;
    import com.esri.ags.events.LayerEvent;
    import com.esri.ags.events.MapEvent;
    import com.esri.ags.events.PanEvent;
    import com.esri.ags.events.ZoomEvent;
    import com.esri.ags.geometry.Extent;
    import com.esri.ags.layers.TiledMapServiceLayer;
    import com.esri.ags.layers.supportClasses.LOD;
    import com.esri.ags.layers.supportClasses.TileInfo;

    import flash.display.Bitmap;
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
    import flash.utils.getQualifiedClassName;
    import flash.utils.getTimer;

    import mx.events.FlexEvent;
    import mx.rpc.Fault;
    import mx.rpc.events.FaultEvent;

    import org.falpi.ags.layers.supportClasses.TileCache;
    import org.falpi.ags.layers.supportClasses.TileContent;
    import org.falpi.ags.layers.supportClasses.tile_internal;
    import org.falpi.ags.net.JavaScriptTransport;
    import org.falpi.ags.net.ResourceLoader;
    import org.falpi.ags.utils.UrlUtil;

    use namespace tile_internal;

    /**
     * Dispatched when the basemap cannot be loaded (a LayerEvent.LOAD_ERROR is dispatched as well), or when
     * its tiles cannot be read.
     */
    [Event(name="fault", type="mx.rpc.events.FaultEvent")]

    /**
     * Base of the tile layers of this library: what vector and raster basemaps have in common. It integrates with
     * the Map (levels of detail, extent, zoom and pan animations), keeps the tiles of the view and lays them out,
     * spreads the drawing over the frames, loads through a proxy, with a token, by Flash or by the page (transport).
     * What depends on the kind of tiles is delegated to a TileContent.
     *
     * <p>Not meant to be used directly: see VectorTileLayer, RasterTileLayer and HybridTileLayer.</p>
     */
    public class AbstractTileLayer extends TiledMapServiceLayer
    {
        /** Requests made by Flash. */
        public static const TRANSPORT_FLASH:String = "flash";
        /** Requests made by the page that hosts the SWF (fetch, through ExternalInterface). */
        public static const TRANSPORT_JAVASCRIPT:String = "javascript";

        private static const AGS_INTERNAL:Namespace = new Namespace("http://www.esri.com/2008/ags/internal");
        private static const VIEW_MARGIN:Number = 32;
        private static const FRAME_BUDGET_MS:int = 18;

        private static const LOADING:int = 0;
        private static const QUEUED:int = 1;
        /** State of a tile that is drawn. */
        tile_internal static const DONE:int = 2;

        public function AbstractTileLayer(url:String = null, proxyURL:String = null, token:String = null)
        {
            super();
            m_root = new Sprite();
            m_tileContainer = new Sprite();
            m_root.mouseEnabled = false;
            m_root.mouseChildren = false;
            m_root.addChild(m_tileContainer);
            addChild(m_root);
            addEventListener(LayerEvent.LOAD, loadHandler);
            addEventListener(FlexEvent.HIDE, hiddenHandler);
            this.url = url;
            this.proxyURL = proxyURL;
            this.token = token;
        }

        // ------------------------------------------------------------------
        // state
        // ------------------------------------------------------------------

        /** Tiles and overlays: scaled as a whole during the zoom animations. */
        private var m_root:Sprite;
        private var m_tileContainer:Sprite;

        private var m_content:TileContent;
        private var m_contentDirty:Boolean = false;
        private var m_loader:ResourceLoader;

        /** key -> tile: {key, z, x, y, size, span, state, needed, mapX, mapY, zoom, display} plus what the content adds. */
        private var m_tiles:Object = {};
        private var m_renderQueue:Array = [];

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
        /** Nothing shown at the scale of the view: out of minScale / maxScale, or a level not in displayLevels. */
        private var m_hidden:Boolean = false;
        /** Tiles fading in (fadeInFrameCount of TiledMapServiceLayer): their alpha grows by tile.fadeStep a frame. */
        private var m_fading:Array = [];
        /** Drawn tiles that left the view (tileCacheSize): key -> tile. */
        private var m_cache:TileCache = new TileCache(releaseTile);
        private var m_statCacheHits:int = 0;

        private var m_updatePending:Boolean = false;
        private var m_frameListener:Boolean = false;
        private var m_panListener:Boolean = false;
        /** True between PAN_START and PAN_END (the user is dragging the map). */
        private var m_panning:Boolean = false;
        /**
         * getTimer of the end of the drag while the extent change that follows it has not reached updateLayer
         * yet (0 otherwise). Until then the layer still has the view of the start of the drag.
         */
        private var m_panEndTime:int = 0;
        /** getTimer of the last pan or zoom step. */
        private var m_moveTime:int = -10000;
        private var m_statStart:int;
        private var m_statTiles:int;
        private var m_statRenderMs:int;
        private var m_statRenderCount:int;

        /** The copyright when the content was loaded: the one of the application (null if it set none). */
        private var m_copyrightBefore:String;
        /** The copyright when the layer loaded: if it is still that one at the next load, it was the basemap's. */
        private var m_copyrightLoaded:String;

        // ------------------------------------------------------------------
        // public properties
        // ------------------------------------------------------------------

        private var m_url:String;

        [Bindable("urlChanged")]
        /** URL of the basemap (see the subclasses). Changing it after the layer has loaded loads the basemap again. */
        public function get url():String
        {
            return m_url;
        }

        public function set url(value:String):void
        {
            if (m_url != value)
            {
                m_url = value;
                invalidateContent();
                dispatchEvent(new Event("urlChanged"));
            }
        }

        private var m_proxyURL:String;

        /**
         * The proxy page: requests are sent as proxyURL?targetURL. Needed by Flash in the browser whenever a server
         * has no crossdomain.xml, which is the case of the Esri basemap servers (for data, not for images).
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
                invalidateContent();
            }
        }

        private var m_token:String;

        /**
         * Token or API key (ArcGIS token, Mapbox access token, MapTiler key...), appended to the requests sent to the
         * site of url (its registered domain: www.arcgis.com and basemaps.arcgis.com are the same site). Requests to
         * other sites, such as fonts or sprites of a style kept elsewhere, go without it.
         */
        public function get token():String
        {
            return m_token;
        }

        public function set token(value:String):void
        {
            if (m_token != value)
            {
                m_token = value;
                invalidateContent();
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
                invalidateContent();
            }
        }

        private var m_proxyTiles:Boolean = true;

        /**
         * Whether the tiles go through the proxy too (true, the default, as the Esri layers do). False sends them
         * straight to their server, while metadata, styles, glyphs and sprites still go through the proxy. With
         * the Flash transport the raster tiles, which are images, are always shown; vector tiles are data, read only
         * from servers with a valid crossdomain.xml (a fault event says when it is missing).
         */
        public function get proxyTiles():Boolean
        {
            return m_proxyTiles;
        }

        public function set proxyTiles(value:Boolean):void
        {
            if (m_proxyTiles != value)
            {
                m_proxyTiles = value;
                invalidateContent();
            }
        }

        private var m_transport:String = TRANSPORT_FLASH;

        [Inspectable(enumeration="flash,javascript", defaultValue="flash")]
        /**
         * Who makes the requests: "flash" (default) or "javascript", the page that hosts the SWF, through
         * ExternalInterface (fetch: CORS applies instead of the crossdomain.xml policies of Flash). Independent of
         * the proxy, which applies the same way. With "javascript" every request goes through the page: when it
         * cannot (no ExternalInterface) the layer does not load.
         */
        public function get transport():String
        {
            return m_transport;
        }

        public function set transport(value:String):void
        {
            if (m_transport != value)
            {
                m_transport = value;
                invalidateContent();
            }
        }

        private var m_maxConnections:int = 6;

        /** Maximum number of parallel requests (default 6). */
        public function get maxConnections():int
        {
            return m_maxConnections;
        }

        public function set maxConnections(value:int):void
        {
            m_maxConnections = value;
            if (m_loader != null)
            {
                m_loader.maxConnections = value;
            }
        }

        private var m_tileCacheSize:Number = 64;

        /**
         * Megabytes of memory for the drawn tiles that left the view (default 64): when the view comes back to them
         * they are shown at once, without requests, decoding or drawing. The least recently seen are dropped first.
         * 0: no cache. Emptied by refresh, by a new url, by a new basemap, when the layer is hidden (visible false)
         * and when it leaves the map.
         */
        public function get tileCacheSize():Number
        {
            return m_tileCacheSize;
        }

        public function set tileCacheSize(value:Number):void
        {
            m_tileCacheSize = value;
            m_cache.trim(cacheLimit());
        }

        /** Diagnostics: where the time of the last completed update went. */
        public var updateTimings:String = "";

        private var m_updateMapLods:Boolean = false;

        /**
         * When true, while the layer is loaded and visible the Map takes its levels of detail: the zoom can reach
         * the last level of this basemap, and no further. A map whose level is past it is first brought back to
         * it. Meant for the basemaps of a map shown one at a time.
         */
        public function get updateMapLods():Boolean
        {
            return m_updateMapLods;
        }

        public function set updateMapLods(value:Boolean):void
        {
            m_updateMapLods = value;
            scheduleMapLods();
        }

        private var m_minScaleSet:Boolean = false;
        private var m_maxScaleSet:Boolean = false;

        /**
         * As in ArcGISTiledMapServiceLayer: when the application sets it, the scale range declared by the basemap
         * (minScale of the metadata of a MapServer) is not used. 0 shows the layer at every scale.
         */
        override public function set minScale(value:Number):void
        {
            m_minScaleSet = true;
            super.minScale = value;
        }

        /** See minScale. */
        override public function set maxScale(value:Number):void
        {
            m_maxScaleSet = true;
            super.maxScale = value;
        }

        override public function get tileInfo():TileInfo
        {
            return m_content != null ? m_content.tileInfo : null;
        }

        override public function get fullExtent():Extent
        {
            return m_content != null ? m_content.fullExtent : null;
        }

        override public function get initialExtent():Extent
        {
            return m_content != null ? m_content.initialExtent : null;
        }

        override public function get spatialReference():SpatialReference
        {
            return m_content != null ? m_content.spatialReference : null;
        }

        // ------------------------------------------------------------------
        // diagnostics
        // ------------------------------------------------------------------

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
            var name:String = getQualifiedClassName(this);
            m_diagnosticsText.text = name.substr(name.lastIndexOf(":") + 1) + " " + id + " | " + Capabilities.playerType + " " +
                Capabilities.version + (Capabilities.isDebugger ? " debugger" : "") + "\n" +
                "fps " + fps.toFixed(0) + " (stage " + stage.frameRate + "), worst frame " + m_diagnosticsWorst + " ms | level " +
                map.level + ", tiles " + total + " (" + loading + " loading), queue " + m_renderQueue.length +
                ", cache " + m_cache.count + " tiles " + (m_cache.bytes / 1048576).toFixed(1) + " MB\n" +
                "last update: " + updateTimings;
            m_diagnosticsFrames = 0;
            m_diagnosticsTime = now;
            m_diagnosticsWorst = 0;
        }

        // ------------------------------------------------------------------
        // content
        // ------------------------------------------------------------------

        /** The content shown (see TileContent). */
        protected function get content():TileContent
        {
            return m_content;
        }

        /** Replaces the content: the previous one is dropped and the new one is loaded. */
        protected function setContent(value:TileContent):void
        {
            if (m_content == value)
            {
                return;
            }
            if (m_content != null)
            {
                clearTiles(true);
                m_content.detach();
            }
            m_content = value;
            if (m_content != null)
            {
                m_content.attach(this);
            }
            invalidateContent();
        }

        /** Loads the basemap again at the next validation. */
        tile_internal function invalidateContent():void
        {
            m_contentDirty = true;
            invalidateProperties();
        }

        override protected function commitProperties():void
        {
            super.commitProperties();
            if (m_contentDirty)
            {
                m_contentDirty = false;
                loadContent();
            }
        }

        private function unloadContent():void
        {
            if (m_loader != null)
            {
                m_loader.cancelAll();
                m_loader = null;
            }
            clearTiles(true);
            if (m_content != null)
            {
                m_content.unload();
            }
            setLoaded(false);
            // the copyright of the previous basemap, set by the layer: back to the one of the application
            if (m_copyrightLoaded != null && copyright == m_copyrightLoaded && m_copyrightLoaded != m_copyrightBefore)
            {
                copyright = m_copyrightBefore;
            }
            m_copyrightBefore = copyright;
            m_copyrightLoaded = null;
            // the scale range of the previous basemap, unless the application set it
            applyScaleRange(0, 0);
        }

        private function applyScaleRange(min:Number, max:Number):void
        {
            if (!m_minScaleSet && super.minScale != min)
            {
                super.minScale = min;
            }
            if (!m_maxScaleSet && super.maxScale != max)
            {
                super.maxScale = max;
            }
        }

        private function loadContent():void
        {
            unloadContent();
            if (m_content == null)
            {
                return;
            }
            if (m_transport == TRANSPORT_JAVASCRIPT && !JavaScriptTransport.available)
            {
                contentFailed("The javascript transport is not available: the page cannot be reached through ExternalInterface");
                return;
            }
            m_loader = new ResourceLoader();
            m_loader.proxyURL = m_proxyURL;
            m_loader.token = m_token;
            m_loader.tokenParameter = m_tokenParameter;
            // the token goes only to the site of the service (null for a relative url: no restriction)
            m_loader.tokenSite = UrlUtil.site(UrlUtil.host(UrlUtil.normalizeMapbox(m_url)));
            m_loader.maxConnections = maxConnections;
            m_loader.transport = m_transport;
            m_content.load(m_loader, m_url);
        }

        /** Called by the content when the basemap is loaded. */
        tile_internal function contentReady():void
        {
            if (m_content.copyright != null && m_content.copyright.length > 0 && (copyright == null || copyright.length == 0))
            {
                copyright = m_content.copyright;
            }
            applyScaleRange(m_content.minScale, m_content.maxScale);
            setLoaded(true);
        }

        /** Called by the content when the basemap cannot be loaded. */
        tile_internal function contentFailed(message:String):void
        {
            loadFailed(message);
        }

        /** Reports that the layer cannot be loaded: a fault event and a LayerEvent.LOAD_ERROR. */
        protected function loadFailed(message:String):void
        {
            setLoaded(false);
            var name:String = getQualifiedClassName(this);
            var fault:Fault = new Fault(name.substr(name.lastIndexOf(":") + 1) + ".load", message);
            if (hasEventListener(FaultEvent.FAULT))
            {
                dispatchEvent(new FaultEvent(FaultEvent.FAULT, false, false, fault));
            }
            dispatchEvent(new LayerEvent(LayerEvent.LOAD_ERROR, this, fault));
        }

        /** A fault event that does not stop the layer (for example tiles that cannot be read). */
        tile_internal function reportFault(code:String, message:String):void
        {
            dispatchEvent(new FaultEvent(FaultEvent.FAULT, false, false, new Fault(code, message)));
        }

        private function loadHandler(event:LayerEvent):void
        {
            m_copyrightLoaded = copyright;
            scheduleMapLods();
        }

        // ------------------------------------------------------------------
        // what the content reads
        // ------------------------------------------------------------------

        /** The sprite that holds the tiles and the overlays of the content, scaled during the zoom animations. */
        tile_internal function get tileRoot():Sprite
        {
            return m_root;
        }

        tile_internal function get loader():ResourceLoader
        {
            return m_loader;
        }

        tile_internal function get tiles():Object
        {
            return m_tiles;
        }

        tile_internal function get hasView():Boolean
        {
            return m_hasView;
        }

        tile_internal function get mapX():Number
        {
            return m_mapX;
        }

        tile_internal function get mapY():Number
        {
            return m_mapY;
        }

        tile_internal function get viewX():Number
        {
            return m_viewX;
        }

        tile_internal function get viewY():Number
        {
            return m_viewY;
        }

        tile_internal function get viewWidth():Number
        {
            return m_viewWidth;
        }

        tile_internal function get viewHeight():Number
        {
            return m_viewHeight;
        }

        tile_internal function get resolution():Number
        {
            return m_resolution;
        }

        tile_internal function get zoom():Number
        {
            return m_zoom;
        }

        tile_internal function get panning():Boolean
        {
            return m_panning;
        }

        tile_internal function get moveTime():int
        {
            return m_moveTime;
        }

        tile_internal function get panEndTime():int
        {
            return m_panEndTime;
        }

        tile_internal function set panEndTime(value:int):void
        {
            m_panEndTime = value;
        }

        tile_internal function get updatePending():Boolean
        {
            return m_updatePending;
        }

        // ------------------------------------------------------------------
        // Layer / TiledMapServiceLayer integration
        // ------------------------------------------------------------------

        /** Not used: the tiles are loaded and drawn by the content. */
        override protected function getTileURL(level:Number, row:Number, col:Number):URLRequest
        {
            return null;
        }

        /** True while the showHandler of TiledMapServiceLayer runs (see removeAllChildren). */
        private var m_showing:Boolean = false;

        override public function refresh():void
        {
            if (m_content != null)
            {
                m_content.refresh();
            }
            clearTiles(true);
            invalidateLayer();
        }

        override protected function removeAllChildren():void
        {
            // the base class calls this to drop its image tiles; ours live in m_root. When the layer is shown again
            // it does so whenever the levels of the map changed meanwhile (an application that gives the map the
            // levels of the basemap shown): ours are kept, the update that follows lays them out for the view, so
            // that a basemap shown again at the same view appears at once
            if (!m_showing)
            {
                clearTiles(false);
            }
        }

        override protected function addMapListeners():void
        {
            super.addMapListeners();
            if (map != null && !m_panListener)
            {
                map.addEventListener(PanEvent.PAN_START, panStart, false, 0, true);
                map.addEventListener(PanEvent.PAN_UPDATE, panUpdate, false, 0, true);
                map.addEventListener(PanEvent.PAN_END, panEnd, false, 0, true);
                m_panListener = true;
            }
            scheduleMapLods();
        }

        override protected function removeMapListeners():void
        {
            super.removeMapListeners();
            if (map != null && m_panListener)
            {
                map.removeEventListener(PanEvent.PAN_START, panStart);
                map.removeEventListener(PanEvent.PAN_UPDATE, panUpdate);
                map.removeEventListener(PanEvent.PAN_END, panEnd);
            }
            m_panListener = false;
            m_panning = false;
        }

        override protected function removedHandler(event:Event):void
        {
            super.removedHandler(event);
            if (event.target == this)
            {
                clearTiles(false);
                // out of the map: the memory of the cache is given back
                m_cache.flush();
            }
        }

        /**
         * Hidden (visible false): the cache (the tiles that left the view) is released, so that the layers not shown
         * (alternative basemaps, say) do not hold its memory. The tiles of the view stay: shown again at the same
         * view, the layer appears at once.
         */
        private function hiddenHandler(event:FlexEvent):void
        {
            if (event.target == this)
            {
                m_cache.flush();
            }
        }

        override protected function showHandler(event:FlexEvent):void
        {
            m_showing = true;
            try
            {
                super.showHandler(event);
            }
            finally
            {
                m_showing = false;
            }
            scheduleMapLods();
        }

        override protected function zoomStartHandler(event:ZoomEvent):void
        {
            // the base implementations snapshot / rescale image tiles; we scale our own content.
            // When zoom steps follow each other the map does not update the layer in between: the tiles
            // are still laid out for an older extent, while the new animation is relative to the current
            // one. Lay them out again first, or they would jump back to their old size at every step
            rebase();
            if (m_content != null && m_content.ready)
            {
                m_content.zoomStarted();
            }
        }

        /** Lays out the existing tiles (kept as placeholders) and the overlays for the current map extent. */
        private function rebase():void
        {
            if (m_content == null || !m_content.ready || map == null || !m_hasView)
            {
                return;
            }
            m_root.x = 0;
            m_root.y = 0;
            m_root.scaleX = 1;
            m_root.scaleY = 1;
            if (!computeView())
            {
                return;
            }
            for each (var tile:Object in m_tiles)
            {
                positionTile(tile);
            }
            m_content.rebased();
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
            m_root.scaleX = ratio;
            m_root.scaleY = ratio;
            m_root.x = x + scrollRect.x - scrollRect.x * ratio;
            m_root.y = y + scrollRect.y - scrollRect.y * ratio;
            overlapTiles(ratio);
            if (m_content != null && m_content.ready)
            {
                m_content.zoomUpdated();
            }
        }

        /**
         * During a zoom animation the tiles are scaled with m_root and their edges fall between the pixels of the
         * screen: two neighbors cover the pixel of their common edge only in part, and the background shows
         * through as a thin light line. Each tile is drawn one pixel of the screen wider and taller, so that the
         * pixel of the edge is covered. The next layout (rebase, updateLayer) gives them their size back.
         */
        private function overlapTiles(ratio:Number):void
        {
            if (!(ratio > 0))
            {
                return;
            }
            var extra:Number = 1 / ratio;
            for each (var tile:Object in m_tiles)
            {
                var display:DisplayObject = tile.display as DisplayObject;
                if (display != null && tile.slotNative > 0)
                {
                    display.scaleX = (tile.slotWidth + extra) / tile.slotNative;
                    display.scaleY = (tile.slotHeight + extra) / tile.slotNative;
                }
            }
        }

        override protected function zoomEndHandler(event:ZoomEvent):void
        {
            // the extent change that follows redraws the layer at the new scale
        }

        override protected function updateLayer():void
        {
            m_panEndTime = 0;
            if (m_content == null || !m_content.ready || map == null)
            {
                return;
            }
            m_updatePending = true;
            m_statStart = getTimer();
            m_statTiles = -1;
            m_statRenderMs = 0;
            m_statRenderCount = 0;
            m_statCacheHits = 0;
            m_content.resetStats();
            m_root.x = 0;
            m_root.y = 0;
            m_root.scaleX = 1;
            m_root.scaleY = 1;
            m_hidden = !isInScaleRange || !computeView() || !levelDisplayed();
            if (m_hidden)
            {
                clearTiles(false);
                finishUpdate();
                return;
            }
            updateTiles(new Rectangle(m_viewX, m_viewY, m_viewWidth, m_viewHeight));
            m_content.viewChanged();
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
            m_zoom = m_content.levelFor(m_resolution);
            m_hasView = true;
            return true;
        }

        /**
         * Whether displayLevels (of TiledMapServiceLayer: LOD.level values, null for all) includes the level of
         * the basemap nearest to the resolution of the view. Esri shows a tiled layer only when the scale of the
         * map is the one of a level; this engine draws at any scale, so the nearest level counts.
         */
        private function levelDisplayed():Boolean
        {
            var levels:Array = displayLevels;
            var info:TileInfo = tileInfo;
            if (levels == null || info == null || info.lods == null || info.lods.length == 0)
            {
                return true;
            }
            var nearest:LOD = null;
            var nearestDistance:Number = Number.MAX_VALUE;
            for each (var lod:LOD in info.lods)
            {
                var distance:Number = Math.abs(Math.log(lod.resolution / m_resolution));
                // the finer one when two are as near
                if (distance <= nearestDistance + 1e-9)
                {
                    nearestDistance = distance;
                    nearest = lod;
                }
            }
            for each (var level:* in levels)
            {
                if (Number(level) == nearest.level)
                {
                    return true;
                }
            }
            return false;
        }

        private function panStart(event:PanEvent):void
        {
            m_panning = true;
            if (m_content != null)
            {
                m_content.panStarted();
            }
        }

        private function panEnd(event:PanEvent):void
        {
            // the extent change that follows lays out the final view
            m_panning = false;
            m_panEndTime = Math.max(1, getTimer());
        }

        private function panUpdate(event:PanEvent):void
        {
            m_moveTime = getTimer();
            if (m_content == null || !m_content.ready || !m_hasView || !visible || m_hidden)
            {
                return;
            }
            var scrollRect:Rectangle = viewportScrollRect();
            if (scrollRect != null && scrollRect.width > 0)
            {
                // the view has not changed: only the tiles that appear are laid out
                updateTiles(scrollRect, false);
            }
            m_content.panMoved();
        }

        /** The visible rectangle of the map in layer pixels (it moves while the map is dragged). */
        tile_internal function viewportScrollRect():Rectangle
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

        /**
         * Makes sure the tiles covering the rectangle (layer pixels) exist. With layout the existing ones are laid
         * out for the view (a new view); without it (a drag, same view) only the ones that appear.
         */
        private function updateTiles(rect:Rectangle, layout:Boolean = true):void
        {
            var z:int = m_content.tileLevel(Math.floor(m_zoom + 0.0001));
            if (z != m_tileZoom)
            {
                m_tileZoom = z;
                m_content.levelChanged();
            }
            var span:Number = m_content.span(z);
            var range:Rectangle = m_content.tileRange(z);
            var originX:Number = m_content.originX;
            var originY:Number = m_content.originY;
            var mapLeft:Number = m_mapX + (rect.x - VIEW_MARGIN - m_viewX) * m_resolution;
            var mapRight:Number = m_mapX + (rect.right + VIEW_MARGIN - m_viewX) * m_resolution;
            var mapTop:Number = m_mapY - (rect.y - VIEW_MARGIN - m_viewY) * m_resolution;
            var mapBottom:Number = m_mapY - (rect.bottom + VIEW_MARGIN - m_viewY) * m_resolution;
            // with Map.wrapAround180 the extent goes on beyond the antimeridian: the columns of the view are
            // repeated every world, each copy is a tile of its own (shown at its place) with the data of the
            // column of the grid
            var columns:int = map != null && map.wrapAround180 ? m_content.worldColumns(z) : 0;
            var col0:int = Math.floor((mapLeft - originX) / span);
            var col1:int = Math.floor((mapRight - originX) / span);
            if (columns <= 0)
            {
                col0 = Math.max(range.x, col0);
                col1 = Math.min(range.right, col1);
            }
            var row0:int = Math.max(range.y, Math.floor((originY - mapTop) / span));
            var row1:int = Math.min(range.bottom, Math.floor((originY - mapBottom) / span));
            var size:int = Math.max(1, Math.round(span / m_resolution));
            var needed:Object = {};
            var key:String;
            var tile:Object;
            var reused:int = 0;
            if ((col1 - col0 + 1) * (row1 - row0 + 1) <= 400)
            {
                for (var row:int = row0; row <= row1; row++)
                {
                    for (var col:int = col0; col <= col1; col++)
                    {
                        var gridCol:int = columns > 0 ? ((col % columns) + columns) % columns : col;
                        if (gridCol < range.x || gridCol > range.right)
                        {
                            continue;
                        }
                        key = z + "/" + col + "/" + row + "@" + size;
                        needed[key] = true;
                        if (m_tiles[key] == null)
                        {
                            tile = m_cache.take(key);
                            if (tile != null)
                            {
                                m_statCacheHits++;
                                // seen before: shown again as it was
                                tile.needed = true;
                                m_tiles[key] = tile;
                                m_tileContainer.addChild(tile.display as DisplayObject);
                                positionTile(tile);
                                reused++;
                                continue;
                            }
                            tile = {key: key, z: z, x: gridCol, y: row, column: col, size: size, span: span, state: LOADING,
                                needed: true, mapX: originX + col * span, mapY: originY - row * span, zoom: m_zoom, display: null};
                            m_tiles[key] = tile;
                            m_content.createTile(tile);
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
                    // same level but out of view (kept in the cache), or an obsolete tile that never got drawn
                    removeTile(tile, true);
                }
                else if (layout)
                {
                    positionTile(tile);
                }
            }
            if (reused > 0)
            {
                // for the content they are drawn tiles that appear (the labels of the vector basemaps)
                m_content.tilesRendered();
            }
            startFrames();
        }

        /** Called by the content when a tile can be drawn. */
        tile_internal function tileReady(tile:Object):void
        {
            // a drawn tile whose data was asked again (tile.redraw) is drawn again in its place
            if ((tile.state == LOADING || tile.state == DONE && tile.redraw) && m_tiles[tile.key] == tile)
            {
                tile.state = QUEUED;
                m_renderQueue.push(tile);
                startFrames();
            }
        }

        private function positionTile(tile:Object):void
        {
            var display:DisplayObject = tile.display as DisplayObject;
            if (display == null)
            {
                return;
            }
            var x0:Number = Math.round(m_viewX + (tile.mapX - m_mapX) / m_resolution);
            var y0:Number = Math.round(m_viewY + (m_mapY - tile.mapY) / m_resolution);
            var x1:Number = Math.round(m_viewX + (tile.mapX + tile.span - m_mapX) / m_resolution);
            var y1:Number = Math.round(m_viewY + (m_mapY - tile.mapY + tile.span) / m_resolution);
            display.x = x0;
            display.y = y0;
            var native:Number = m_content.nativeSize(tile);
            // the slot of the tile, for overlapTiles
            tile.slotWidth = x1 - x0;
            tile.slotHeight = y1 - y0;
            tile.slotNative = native;
            if (native != x1 - x0 || native != y1 - y0)
            {
                // a tile of another level kept as placeholder until the new ones are drawn, or a raster tile
                // shown beyond the last level of its service
                display.scaleX = (x1 - x0) / native;
                display.scaleY = (y1 - y0) / native;
            }
            else
            {
                display.scaleX = 1;
                display.scaleY = 1;
            }
            // smoothing of TiledMapServiceLayer (true by default): bilinear filtering whenever the tile is scaled,
            // as placeholder, beyond the last level or during the zoom animations; at its size it changes nothing
            // (the bitmap is snapped to the pixels). An image that Flash cannot read (another domain, loaded by
            // Flash without proxy) is not a Bitmap here and cannot be smoothed
            var bitmap:Bitmap = display as Bitmap;
            var holder:Sprite = display as Sprite;
            if (bitmap == null && holder != null && holder.numChildren > 0)
            {
                // a part of a bitmap cut by a scrollRect (resampled raster tiles)
                bitmap = holder.getChildAt(0) as Bitmap;
            }
            if (bitmap != null && bitmap.smoothing != smoothing)
            {
                bitmap.smoothing = smoothing;
            }
        }

        /** Takes a tile out of the view: into the cache when keep is true and it is drawn, otherwise it is released. */
        private function removeTile(tile:Object, keep:Boolean = false):void
        {
            delete m_tiles[tile.key];
            var display:DisplayObject = tile.display as DisplayObject;
            if (display != null && display.parent != null)
            {
                display.parent.removeChild(display);
            }
            if (keep && cacheTile(tile))
            {
                return;
            }
            releaseTile(tile);
        }

        private function releaseTile(tile:Object):void
        {
            if (m_content != null)
            {
                m_content.releaseTile(tile);
            }
            tile.display = null;
            tile.state = -1;
        }

        /** Removes every tile; with clearData the cache and the data of the content are dropped as well. */
        private function clearTiles(clearData:Boolean):void
        {
            if (m_content != null)
            {
                m_content.clear();
            }
            for each (var tile:Object in m_tiles)
            {
                removeTile(tile, !clearData);
            }
            m_tiles = {};
            m_renderQueue = [];
            m_fading = [];
            m_tileZoom = -1;
            if (clearData)
            {
                m_cache.flush();
                if (m_content != null)
                {
                    m_content.clearData();
                }
            }
        }

        // ------------------------------------------------------------------
        // cache of the tiles that left the view (tileCacheSize)
        // ------------------------------------------------------------------

        private function cacheLimit():Number
        {
            var megabytes:Number = tileCacheSize;
            return megabytes > 0 ? megabytes * 1048576 : 0;
        }

        /** Keeps a drawn tile that left the view; false when it cannot be kept (then it is released). */
        private function cacheTile(tile:Object):Boolean
        {
            var display:DisplayObject = tile.display as DisplayObject;
            var limit:Number = cacheLimit();
            // an incomplete tile (its data failed for a temporary reason, or is being asked again) is asked again
            // when it comes back
            if (limit <= 0 || tile.state != DONE || tile.incomplete || tile.redraw || display == null || m_content == null)
            {
                return false;
            }
            var bytes:Number = tileBytes(tile);
            if (bytes > limit)
            {
                return false;
            }
            // a fade interrupted: shown whole when it comes back
            display.alpha = 1;
            m_content.tileCached(tile);
            return m_cache.put(tile.key, tile, bytes, limit);
        }

        /** Memory of a drawn tile: its bitmap, or the size of an image that cannot be read. */
        private function tileBytes(tile:Object):Number
        {
            var display:DisplayObject = tile.display as DisplayObject;
            var bitmap:Bitmap = display as Bitmap;
            var holder:Sprite = display as Sprite;
            if (bitmap == null && holder != null && holder.numChildren > 0)
            {
                bitmap = holder.getChildAt(0) as Bitmap;
            }
            try
            {
                if (bitmap != null && bitmap.bitmapData != null)
                {
                    return bitmap.bitmapData.width * bitmap.bitmapData.height * 4;
                }
            }
            catch (error:Error)
            {
                // disposed
            }
            var size:Number = Math.max(256, m_content.nativeSize(tile));
            return size * size * 4;
        }

        // ------------------------------------------------------------------
        // frame loop: drawing (and the work of the content) spread over frames
        // ------------------------------------------------------------------

        tile_internal function startFrames():void
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
            if (m_content == null || !m_content.ready || !m_hasView)
            {
                stopFrames();
                return;
            }
            var start:int = getTimer();
            if (m_fading.length > 0 && stepFades() && m_fading.length == 0)
            {
                // the placeholders stay until the last fade has ended
                checkComplete();
            }
            if (m_content.frameStart(start))
            {
                return;
            }
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
                m_content.tilesRendered();
                checkComplete();
            }
            else if (m_renderQueue.length == 0)
            {
                m_content.idle(start, hasLoadingTiles());
            }
            if (m_renderQueue.length == 0 && m_fading.length == 0 && !m_content.busy && !hasLoadingTiles())
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
            var renderStart:int = getTimer();
            var display:DisplayObject = null;
            // drawn again (tile.redraw): the new display replaces the old one, already shown, without a fade
            var previous:DisplayObject = tile.display as DisplayObject;
            tile.redraw = false;
            try
            {
                display = m_content.renderTile(tile);
            }
            catch (error:Error)
            {
                // a broken tile must not stop the others
            }
            m_statRenderMs += getTimer() - renderStart;
            m_statRenderCount++;
            if (previous != null && previous != display && previous.parent != null)
            {
                previous.parent.removeChild(previous);
            }
            tile.display = display;
            tile.state = DONE;
            if (display != null)
            {
                m_tileContainer.addChild(display);
                positionTile(tile);
                // fadeInFrameCount of TiledMapServiceLayer (4 by default), as Esri: 1/n at once, then 1/n a frame
                var frames:int = previous != null ? 1 : fadeInFrameCount;
                if (frames > 1)
                {
                    tile.fadeStep = 1 / frames;
                    tile.fadeAlpha = tile.fadeStep;
                    display.alpha = tile.fadeAlpha;
                    m_fading.push(tile);
                }
            }
        }

        /** One frame of the fades: true when one has ended. */
        private function stepFades():Boolean
        {
            var ended:Boolean = false;
            for (var i:int = m_fading.length - 1; i >= 0; i--)
            {
                var tile:Object = m_fading[i];
                var display:DisplayObject = tile.display as DisplayObject;
                if (display == null || m_tiles[tile.key] != tile)
                {
                    m_fading.splice(i, 1);
                    ended = true;
                    continue;
                }
                tile.fadeAlpha += tile.fadeStep;
                if (tile.fadeAlpha >= 0.999)
                {
                    display.alpha = 1;
                    m_fading.splice(i, 1);
                    ended = true;
                }
                else
                {
                    display.alpha = tile.fadeAlpha;
                }
            }
            return ended;
        }

        tile_internal function hasLoadingTiles():Boolean
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

        /** When every tile of the view is drawn: drops the placeholders and ends the update if the content is done. */
        private function checkComplete():void
        {
            if (hasLoadingTiles() || m_fading.length > 0)
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
                    // a placeholder: kept in the cache, for a zoom back to its level
                    removeTile(tile, true);
                }
            }
            if (m_content.settled)
            {
                finishUpdate();
            }
        }

        /**
         * Ends the update (once): updateTimings and the UPDATE_END event. While tiles fade in it waits for the end
         * of the fades (as Esri, whose images complete when their fade ends): checkComplete calls it again then.
         */
        tile_internal function finishUpdate():void
        {
            if (m_updatePending && m_fading.length == 0)
            {
                updateTimings = "tiles " + m_statTiles + " ms (drawing " + m_statRenderMs + " ms in " + m_statRenderCount +
                    " tiles" + (m_statCacheHits > 0 ? ", " + m_statCacheHits + " from the cache" : "") + "), " +
                    (m_content != null ? m_content.timings : "") + "total " + (getTimer() - m_statStart) + " ms";
                m_updatePending = false;
                dispatchEvent(new LayerEvent(LayerEvent.UPDATE_END, this, null, true));
            }
        }

        // ------------------------------------------------------------------
        // levels of detail of the map (updateMapLods)
        // ------------------------------------------------------------------

        private var m_mapLodsScheduled:Boolean = false;
        private var m_mapListener:Map;

        /**
         * Applies the levels after the current event: the map handles the load of its layers first (it takes
         * the levels of the first one when it loads), then they are replaced.
         */
        private function scheduleMapLods():void
        {
            if (!m_mapLodsScheduled)
            {
                m_mapLodsScheduled = true;
                callLater(applyMapLods);
            }
        }

        private function applyMapLods():void
        {
            m_mapLodsScheduled = false;
            var target:Map = map;
            if (!updateMapLods || target == null || !loaded || !visible || tileInfo == null)
            {
                return;
            }
            if (!target.loaded)
            {
                // the map sets its levels when it loads: do it after that
                if (m_mapListener != target)
                {
                    m_mapListener = target;
                    target.addEventListener(MapEvent.LOAD, mapLoadHandler, false, 0, true);
                }
                return;
            }
            var lods:Array = tileInfo.lods;
            if (lods == null || lods.length == 0 || sameLods(target.lods, lods))
            {
                return;
            }
            // beyond the last level of this basemap there is nothing to show: come back to it first
            if (target.lods != null && target.level > lods.length - 1)
            {
                target.level = lods.length - 1;
            }
            target.lods = lods;
        }

        private function mapLoadHandler(event:MapEvent):void
        {
            (event.target as Map).removeEventListener(MapEvent.LOAD, mapLoadHandler);
            m_mapListener = null;
            scheduleMapLods();
        }

        /** Same levels: same number and same resolution of the last one. */
        private static function sameLods(a:Array, b:Array):Boolean
        {
            return a != null && b != null && a.length == b.length && a.length > 0 &&
                Math.abs(LOD(a[a.length - 1]).resolution - LOD(b[b.length - 1]).resolution) < 1e-9;
        }
    }
}
