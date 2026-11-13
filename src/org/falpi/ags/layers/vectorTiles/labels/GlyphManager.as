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
        /**
         * Half width of the antialiased edge, in distance field units at 24 px. One screen pixel is 1/8 of a
         * unit, so 0.0625 would be an edge exactly one pixel wide: Mapbox GL uses 0.105, which is smooth on
         * high density screens and blurred on ordinary ones at the sizes of map labels.
         */
        private static const EDGE_GAMMA:Number = 0.055;
        /**
         * The same for text that is not horizontal: there the edges cross the pixel grid at every angle and
         * one as sharp as on horizontal text comes out jagged.
         */
        private static const TURNED_GAMMA:Number = 0.09;
        /** Part of the widening of small text kept on text that is not horizontal. */
        private static const TURNED_BOLD:Number = 0.8;
        /** Horizontal positions of a glyph inside a pixel (see rasterize). */
        public static const PHASES:int = 4;
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
         * @param phase horizontal position inside the pixel, in 1/PHASES of a pixel: the glyph is drawn there,
         *        so that letters keep their spacing instead of jumping to whole pixels. The vertical fraction
         *        of the distance from the baseline is always drawn in, see GlyphRaster.offsetY
         * @param fillARGB text color (alpha included)
         * @param haloARGB halo color (alpha included); ignored when haloWidth is 0
         */
        public function rasterize(stack:FontStack, glyph:Glyph, size:Number, phase:int, fillARGB:uint, haloARGB:uint,
                                  haloWidth:Number, haloBlur:Number):GlyphRaster
        {
            var hasHalo:Boolean = haloWidth > 0 && (haloARGB >>> 24) > 0;
            var key:String = stack.key + "|" + glyph.id + "|" + size + "|" + phase + "|" + fillARGB + "|" +
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
            var top:Number = -(glyph.top + Glyph.BORDER) * raster.scale;
            raster.offsetY = Math.floor(top);
            var sdf:BitmapData = glyph.sdf;
            if (sdf != null)
            {
                var fx:Number = phase / PHASES;
                var fy:Number = top - raster.offsetY;
                var w:int = Math.max(1, Math.ceil(sdf.width * raster.scale + fx));
                var h:int = Math.max(1, Math.ceil(sdf.height * raster.scale + fy));
                var scaled:BitmapData = new BitmapData(w, h, false, 0);
                scaled.draw(sdf, new Matrix(raster.scale, 0, 0, raster.scale, fx, fy), null, null, null, true);
                colorize(raster, scaled, size, fillARGB, hasHalo, haloARGB, haloWidth, haloBlur, EDGE_GAMMA, 1);
                scaled.dispose();
            }
            m_rasters[key] = raster;
            m_rasterCount++;
            return raster;
        }

        /**
         * Draws a glyph in place for text that is not horizontal: the distance field is scaled, turned and
         * moved in one step, and only then converted to coverage. Turning a glyph already drawn would
         * blur its edges a second time. The result is not cached: the caller disposes the bitmaps.
         * @param matrix distance field pixels -> target pixels (not modified)
         * @return bitmaps to copy at (offsetX, offsetY) of the target
         */
        public function rasterizeAt(glyph:Glyph, size:Number, matrix:Matrix, fillARGB:uint, haloARGB:uint,
                                    haloWidth:Number, haloBlur:Number):GlyphRaster
        {
            var raster:GlyphRaster = new GlyphRaster();
            raster.scale = size / Glyph.BASE_SIZE;
            var sdf:BitmapData = glyph.sdf;
            if (sdf == null)
            {
                return raster;
            }
            // bounding box of the turned distance field
            var minX:Number = Number.MAX_VALUE;
            var minY:Number = Number.MAX_VALUE;
            var maxX:Number = -Number.MAX_VALUE;
            var maxY:Number = -Number.MAX_VALUE;
            for (var corner:int = 0; corner < 4; corner++)
            {
                var cx:Number = (corner & 1) != 0 ? sdf.width : 0;
                var cy:Number = (corner & 2) != 0 ? sdf.height : 0;
                var x:Number = matrix.a * cx + matrix.c * cy + matrix.tx;
                var y:Number = matrix.b * cx + matrix.d * cy + matrix.ty;
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
            raster.offsetX = Math.floor(minX);
            raster.offsetY = Math.floor(minY);
            var w:int = Math.max(1, Math.ceil(maxX) - raster.offsetX);
            var h:int = Math.max(1, Math.ceil(maxY) - raster.offsetY);
            var local:Matrix = matrix.clone();
            local.translate(-raster.offsetX, -raster.offsetY);
            var scaled:BitmapData = new BitmapData(w, h, false, 0);
            scaled.draw(sdf, local, null, null, null, true);
            colorize(raster, scaled, size, fillARGB, haloWidth > 0 && (haloARGB >>> 24) > 0, haloARGB, haloWidth, haloBlur,
                TURNED_GAMMA, TURNED_BOLD);
            scaled.dispose();
            return raster;
        }

        /** Distance field at its final size and place -> glyph body and halo in their colors. */
        private function colorize(raster:GlyphRaster, scaled:BitmapData, size:Number, fillARGB:uint, hasHalo:Boolean,
                                  haloARGB:uint, haloWidth:Number, haloBlur:Number, edgeGamma:Number, widening:Number):void
        {
            var rect:Rectangle = scaled.rect;
            var gamma:Number = edgeGamma / raster.scale;
            // small text: strokes thinner than a pixel never reach the full color, so they are widened a little
            var bold:Number = size < 20 ? Math.min(0.035, (20 - size) * 0.005) * widening : 0;
            raster.fill = new BitmapData(rect.width, rect.height, true, 0);
            raster.fill.paletteMap(scaled, rect, ORIGIN, ZEROS, ZEROS, lut(fillARGB, EDGE - bold, gamma), ZEROS);
            if (hasHalo)
            {
                var buffer:Number = Math.max(0, (6 - haloWidth / raster.scale) / SDF_PX);
                var haloGamma:Number = (haloBlur * 1.19 / SDF_PX + edgeGamma) / raster.scale;
                raster.halo = new BitmapData(rect.width, rect.height, true, 0);
                raster.halo.paletteMap(scaled, rect, ORIGIN, ZEROS, ZEROS, lut(haloARGB, buffer, haloGamma), ZEROS);
            }
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
