package org.falpi.ags.layers.vectorTiles.labels
{
    import org.falpi.ags.layers.vectorTiles.net.ResourceLoader;
    import org.falpi.ags.layers.vectorTiles.net.ResourceRequest;
    import org.falpi.ags.layers.vectorTiles.pbf.PbfReader;
    import org.falpi.ags.layers.vectorTiles.util.UrlUtil;

    import flash.display.BitmapData;
    import flash.geom.Matrix;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;

    /**
     * Loads glyph PBF ranges on demand and rasterizes the signed distance
     * fields on the CPU, for a given size and text / halo colors.
     */
    public final class GlyphManager
    {
        private static const EDGE:Number = 0.75;
        private static const EDGE_GAMMA:Number = 0.105;
        private static const SDF_PX:Number = 8;
        private static const MAX_RASTERS:int = 6000;

        private static const ZEROS:Array = buildZeros();
        private static const ORIGIN:Point = new Point(0, 0);

        /** URL template with {fontstack} and {range}. */
        public var glyphsURL:String;
        /** Called (without arguments) every time a new glyph range becomes available. */
        public var onGlyphsLoaded:Function;

        private var m_loader:ResourceLoader;
        private var m_stacks:Object = {};
        private var m_rasters:Object = {};
        private var m_rasterCount:int = 0;
        private var m_luts:Object = {};
        private var m_pending:int = 0;

        public function GlyphManager(loader:ResourceLoader)
        {
            m_loader = loader;
        }

        private static function buildZeros():Array
        {
            var zeros:Array = [];
            for (var i:int = 0; i < 256; i++)
            {
                zeros[i] = 0;
            }
            return zeros;
        }

        /** Number of glyph ranges still being downloaded. */
        public function get pending():int
        {
            return m_pending;
        }

        public function getStack(names:Array):FontStack
        {
            var key:String = names.join(",");
            var stack:FontStack = m_stacks[key] as FontStack;
            if (stack == null)
            {
                stack = new FontStack(names);
                m_stacks[key] = stack;
            }
            return stack;
        }

        /**
         * Makes sure the glyph ranges needed by the text are available.
         * Returns false while some of them are still loading.
         */
        public function ensure(stack:FontStack, text:String):Boolean
        {
            var complete:Boolean = true;
            var n:int = text.length;
            for (var i:int = 0; i < n; i++)
            {
                var start:int = text.charCodeAt(i) & 0xffff00;
                var state:* = stack.ranges[start];
                if (state === undefined)
                {
                    loadRange(stack, start);
                    complete = false;
                }
                else if (state == FontStack.LOADING)
                {
                    complete = false;
                }
            }
            return complete;
        }

        private function loadRange(stack:FontStack, start:int):void
        {
            stack.ranges[start] = FontStack.LOADING;
            if (glyphsURL == null)
            {
                stack.ranges[start] = FontStack.FAILED;
                return;
            }
            var names:Array = stack.firstOnly ? [stack.names[0]] : stack.names;
            var encoded:Array = [];
            for each (var name:String in names)
            {
                encoded.push(encodeURIComponent(name));
            }
            var url:String = UrlUtil.template(glyphsURL, {fontstack: encoded.join(","), range: start + "-" + (start + 255)});
            m_pending++;
            m_loader.load(url, true, function(bytes:ByteArray, request:ResourceRequest):void
            {
                m_pending--;
                var ok:Boolean = false;
                try
                {
                    // servers may answer errors as JSON with HTTP 200
                    ok = bytes != null && bytes.length > 0 && bytes[0] != 0x7b && parse(stack, bytes);
                }
                catch (error:Error)
                {
                    ok = false;
                }
                rangeDone(stack, start, ok);
            }, function(message:String, request:ResourceRequest):void
            {
                m_pending--;
                rangeDone(stack, start, false);
            });
        }

        private function rangeDone(stack:FontStack, start:int, ok:Boolean):void
        {
            if (!ok && !stack.firstOnly && stack.names.length > 1)
            {
                // some servers (ArcGIS) do not compose font stacks: fall back to the first font
                stack.firstOnly = true;
                loadRange(stack, start);
                return;
            }
            stack.ranges[start] = ok ? FontStack.LOADED : FontStack.FAILED;
            if (onGlyphsLoaded != null)
            {
                onGlyphsLoaded();
            }
        }

        private static function parse(stack:FontStack, bytes:ByteArray):Boolean
        {
            var found:Boolean = false;
            var pbf:PbfReader = new PbfReader(bytes);
            while (pbf.next())
            {
                if (pbf.tag != 1 || pbf.wireType != PbfReader.BYTES)
                {
                    pbf.skip();
                    continue;
                }
                var stackStart:uint = pbf.readRange();
                var sub:PbfReader = new PbfReader(bytes, stackStart, pbf.lastLength);
                while (sub.next())
                {
                    if (sub.tag != 3 || sub.wireType != PbfReader.BYTES)
                    {
                        sub.skip();
                        continue;
                    }
                    var glyphStart:uint = sub.readRange();
                    var g:PbfReader = new PbfReader(bytes, glyphStart, sub.lastLength);
                    var glyph:Glyph = new Glyph();
                    while (g.next())
                    {
                        switch (g.tag)
                        {
                            case 1: glyph.id = g.readVarint(); break;
                            case 2: glyph.bitmap = g.readBytes(); break;
                            case 3: glyph.width = g.readVarint(); break;
                            case 4: glyph.height = g.readVarint(); break;
                            case 5: glyph.left = g.readSVarint(); break;
                            case 6: glyph.top = g.readSVarint(); break;
                            case 7: glyph.advance = g.readVarint(); break;
                            default: g.skip();
                        }
                    }
                    stack.glyphs[glyph.id] = glyph;
                    found = true;
                }
            }
            return found;
        }

        // ------------------------------------------------------------------
        // rasterization
        // ------------------------------------------------------------------

        /**
         * Returns the glyph drawn at the given size.
         * @param fillARGB text color (alpha included)
         * @param haloARGB halo color (alpha included); ignored when haloWidth is 0
         */
        public function rasterize(stack:FontStack, glyph:Glyph, size:Number, fillARGB:uint, haloARGB:uint,
                                  haloWidth:Number, haloBlur:Number):GlyphRaster
        {
            var hasHalo:Boolean = haloWidth > 0 && (haloARGB >>> 24) > 0;
            var key:String = stack.key + "|" + glyph.id + "|" + size + "|" + fillARGB + "|" +
                (hasHalo ? haloARGB + "|" + haloWidth + "|" + haloBlur : "");
            var raster:GlyphRaster = m_rasters[key] as GlyphRaster;
            if (raster != null)
            {
                return raster;
            }
            if (m_rasterCount >= MAX_RASTERS)
            {
                clearRasters();
            }
            raster = new GlyphRaster();
            raster.scale = size / Glyph.BASE_SIZE;
            var sdf:BitmapData = glyph.sdf;
            if (sdf != null)
            {
                var w:int = Math.max(1, Math.ceil(sdf.width * raster.scale));
                var h:int = Math.max(1, Math.ceil(sdf.height * raster.scale));
                var scaled:BitmapData = new BitmapData(w, h, false, 0);
                scaled.draw(sdf, new Matrix(raster.scale, 0, 0, raster.scale), null, null, null, true);
                var rect:Rectangle = new Rectangle(0, 0, w, h);
                var gamma:Number = EDGE_GAMMA / raster.scale;
                raster.fill = new BitmapData(w, h, true, 0);
                raster.fill.paletteMap(scaled, rect, ORIGIN, ZEROS, ZEROS, lut(fillARGB, EDGE, gamma), ZEROS);
                if (hasHalo)
                {
                    var buffer:Number = Math.max(0, (6 - haloWidth / raster.scale) / SDF_PX);
                    var haloGamma:Number = (haloBlur * 1.19 / SDF_PX + EDGE_GAMMA) / raster.scale;
                    raster.halo = new BitmapData(w, h, true, 0);
                    raster.halo.paletteMap(scaled, rect, ORIGIN, ZEROS, ZEROS, lut(haloARGB, buffer, haloGamma), ZEROS);
                }
                scaled.dispose();
            }
            m_rasters[key] = raster;
            m_rasterCount++;
            return raster;
        }

        /** Lookup table mapping a distance value (0..255) to a color with the matching coverage. */
        private function lut(argb:uint, edge:Number, gamma:Number):Array
        {
            var key:String = argb + "|" + edge + "|" + gamma;
            var table:Array = m_luts[key] as Array;
            if (table != null)
            {
                return table;
            }
            table = new Array(256);
            var rgb:uint = argb & 0xffffff;
            var alpha:Number = (argb >>> 24) / 255;
            var e0:Number = edge - gamma;
            var e1:Number = edge + gamma;
            for (var i:int = 0; i < 256; i++)
            {
                var t:Number = (i / 255 - e0) / (e1 - e0);
                t = t < 0 ? 0 : (t > 1 ? 1 : t);
                var coverage:Number = t * t * (3 - 2 * t) * alpha;
                table[i] = (uint(coverage * 255 + 0.5) << 24) | rgb;
            }
            m_luts[key] = table;
            return table;
        }

        public function clearRasters():void
        {
            // bitmaps are not disposed: labels being drawn may still reference them
            m_rasters = {};
            m_rasterCount = 0;
        }
    }
}
