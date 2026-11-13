package org.falpi.ags.layers.vectorTiles.labels
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.render.SpriteAtlas;
    import org.falpi.ags.layers.vectorTiles.render.SymbolCandidate;
    import org.falpi.ags.layers.vectorTiles.render.TileRenderer;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;

    import flash.display.BitmapData;
    import flash.geom.ColorTransform;
    import flash.geom.Matrix;
    import flash.geom.Point;

    /**
     * Places the symbols (labels and icons) of the visible tiles: evaluates
     * their layout, resolves collisions by style priority and draws the
     * survivors into a bitmap overlay.
     */
    public final class SymbolPlacer
    {
        private static const DEG:Number = Math.PI / 180;

        /** True after place() when some labels were skipped because their glyphs are still loading. */
        public var incomplete:Boolean = false;
        /** Number of symbols drawn by the last place() call. */
        public var placedCount:int = 0;

        private var m_glyphs:GlyphManager;
        private var m_sprites:SpriteAtlas;
        private var m_index:CollisionIndex = new CollisionIndex();
        private var m_placedTexts:Object;
        private var m_ops:Array;
        private var m_zoom:Number;
        private var m_width:Number;
        private var m_height:Number;
        private var m_point:Point = new Point();
        private var m_matrix:Matrix = new Matrix();

        public function SymbolPlacer(glyphs:GlyphManager, sprites:SpriteAtlas)
        {
            m_glyphs = glyphs;
            m_sprites = sprites;
        }

        /**
         * @param target overlay bitmap (cleared by the caller)
         * @param zoom style zoom of the view
         * @param tiles Array of Objects {x, y, size, symbols}: tile position in target pixels and its candidates
         */
        public function place(target:BitmapData, zoom:Number, tiles:Array):void
        {
            incomplete = false;
            placedCount = 0;
            m_zoom = zoom;
            m_width = target.width;
            m_height = target.height;
            m_index.clear();
            m_placedTexts = {};
            m_ops = [];

            // bucket the candidates by style layer
            var buckets:Object = {};
            var indices:Array = [];
            var t:int;
            var i:int;
            for (t = 0; t < tiles.length; t++)
            {
                var tile:Object = tiles[t];
                var symbols:Vector.<SymbolCandidate> = tile.symbols;
                if (symbols == null)
                {
                    continue;
                }
                for (i = 0; i < symbols.length; i++)
                {
                    var layerIndex:int = symbols[i].layer.index;
                    var bucket:Array = buckets[layerIndex] as Array;
                    if (bucket == null)
                    {
                        bucket = [];
                        buckets[layerIndex] = bucket;
                        indices.push(layerIndex);
                    }
                    bucket.push(symbols[i], tile);
                }
            }
            // later style layers have priority in collisions
            indices.sort(Array.NUMERIC | Array.DESCENDING);
            for each (var index:int in indices)
            {
                var entries:Array = buckets[index];
                for (i = 0; i < entries.length; i += 2)
                {
                    placeCandidate(entries[i] as SymbolCandidate, entries[i + 1]);
                }
            }
            // draw in style order: earlier layers below
            m_ops.sortOn("order", Array.NUMERIC);
            for each (var op:Object in m_ops)
            {
                drawOp(target, op);
            }
            placedCount = m_ops.length;
            m_ops = null;
            m_placedTexts = null;
        }

        // ------------------------------------------------------------------
        // layout
        // ------------------------------------------------------------------

        private function layoutOf(c:SymbolCandidate):Object
        {
            var L:Object = c.layout;
            if (L != null && L.zoom == m_zoom && !L.pendingGlyphs)
            {
                return L;
            }
            var layer:StyleLayer = c.layer;
            var f:MvtFeature = c.feature;
            var z:Number = m_zoom;
            L = {zoom: z, pendingGlyphs: false};
            c.layout = L;

            // ---- text
            if (layer.has("text-field"))
            {
                var raw:* = layer.value("text-field", z, f);
                var text:String = raw == null ? "" : TileRenderer.resolveTokens(String(raw), f);
                var transform:String = String(layer.value("text-transform", z, f));
                if (transform == "uppercase") text = text.toUpperCase();
                else if (transform == "lowercase") text = text.toLowerCase();
                text = text.replace(/^\s+|\s+$/g, "");
                if (text.length > 0)
                {
                    var fonts:Array = layer.value("text-font", z, f) as Array;
                    var stack:FontStack = m_glyphs.getStack(fonts != null && fonts.length > 0 ? fonts : ["Arial Regular"]);
                    if (!m_glyphs.ensure(stack, text))
                    {
                        L.pendingGlyphs = true;
                    }
                    else
                    {
                        var size:Number = layer.value("text-size", z, f);
                        var offset:Array = layer.value("text-offset", z, f) as Array;
                        var maxWidth:Number = c.alongLine && !isViewportText(layer) ? 0 : Number(layer.value("text-max-width", z, f)) * Glyph.BASE_SIZE;
                        var follows:Boolean = c.alongLine && !isViewportText(layer);
                        var anchor:String = follows ? "center" : String(layer.value("text-anchor", z, f));
                        var shaping:Shaping = TextShaper.shape(text, stack, maxWidth,
                            Number(layer.value("text-line-height", z, f)) * Glyph.BASE_SIZE,
                            Number(layer.value("text-letter-spacing", z, f)) * Glyph.BASE_SIZE,
                            anchor, String(layer.value("text-justify", z, f)),
                            offset != null ? Number(offset[0]) * Glyph.BASE_SIZE : 0,
                            offset != null && !follows ? Number(offset[1]) * Glyph.BASE_SIZE : 0);
                        if (shaping != null && size > 0)
                        {
                            var opacity:Number = layer.value("text-opacity", z, f);
                            var color:StyleColor = layer.value("text-color", z, f) as StyleColor;
                            var halo:StyleColor = layer.value("text-halo-color", z, f) as StyleColor;
                            L.text = text;
                            L.stack = stack;
                            L.shaping = shaping;
                            L.textSize = Math.round(size * 4) / 4;
                            // text along a line: text-offset moves the text to one side of the line (see placeOnLine)
                            L.lineOffset = follows && offset != null ? Number(offset[1]) * Number(L.textSize) : 0;
                            L.textColor = color != null ? color.argb(opacity) : 0xff000000;
                            L.haloColor = halo != null ? halo.argb(opacity) : 0;
                            L.haloWidth = Math.round(Number(layer.value("text-halo-width", z, f)) * 4) / 4;
                            L.haloBlur = Number(layer.value("text-halo-blur", z, f));
                            L.textPadding = Number(layer.value("text-padding", z, f));
                            L.textAllowOverlap = Boolean(layer.value("text-allow-overlap", z, f));
                            L.textIgnore = Boolean(layer.value("text-ignore-placement", z, f));
                            L.textOptional = Boolean(layer.value("text-optional", z, f));
                            L.textVisible = opacity > 0;
                        }
                    }
                }
            }

            // ---- icon
            if (layer.has("icon-image") && m_sprites != null)
            {
                var imageName:* = layer.value("icon-image", z, f);
                var name:String = imageName == null ? null : TileRenderer.resolveTokens(String(imageName), f);
                var image:BitmapData = m_sprites.getImage(name);
                if (image != null)
                {
                    var iconScale:Number = Number(layer.value("icon-size", z, f)) / m_sprites.getPixelRatio(name);
                    var drawnImage:BitmapData = image;
                    var drawnScale:Number = iconScale;
                    if (m_sprites.isSdf(name))
                    {
                        // the alpha of an SDF icon is a distance field: drawn in icon-color at its final size
                        var iconColor:StyleColor = layer.value("icon-color", z, f) as StyleColor;
                        drawnImage = m_sprites.getSdfImage(name, iconColor != null ? iconColor.argb(1) : 0xff000000,
                            Math.round(iconScale * 100) / 100);
                        drawnScale = 1;
                    }
                    var iconOffset:Array = layer.value("icon-offset", z, f) as Array;
                    var iconAnchor:String = String(layer.value("icon-anchor", z, f));
                    var w:Number = image.width * iconScale;
                    var h:Number = image.height * iconScale;
                    var ax:Number = iconAnchor.indexOf("left") >= 0 ? w / 2 : (iconAnchor.indexOf("right") >= 0 ? -w / 2 : 0);
                    var ay:Number = iconAnchor.indexOf("top") >= 0 ? h / 2 : (iconAnchor.indexOf("bottom") >= 0 ? -h / 2 : 0);
                    L.icon = drawnImage;
                    L.iconScale = drawnScale;
                    L.iconWidth = w;
                    L.iconHeight = h;
                    // center of the icon relative to the anchor
                    L.iconDx = ax + (iconOffset != null ? Number(iconOffset[0]) * iconScale : 0);
                    L.iconDy = ay + (iconOffset != null ? Number(iconOffset[1]) * iconScale : 0);
                    L.iconRotate = Number(layer.value("icon-rotate", z, f)) * DEG;
                    L.iconOpacity = Number(layer.value("icon-opacity", z, f));
                    L.iconPadding = Number(layer.value("icon-padding", z, f));
                    L.iconAllowOverlap = Boolean(layer.value("icon-allow-overlap", z, f));
                    L.iconIgnore = Boolean(layer.value("icon-ignore-placement", z, f));
                    L.iconOptional = Boolean(layer.value("icon-optional", z, f));
                    var iconAlign:String = String(layer.value("icon-rotation-alignment", z, f));
                    L.iconFollowsLine = c.alongLine && iconAlign != "viewport";
                }
            }
            if (c.alongLine)
            {
                L.spacing = Math.max(20, Number(layer.value("symbol-spacing", z, f)));
                L.maxAngle = Number(layer.value("text-max-angle", z, f)) * DEG;
                L.keepUpright = Boolean(layer.value("text-keep-upright", z, f));
                L.textFollowsLine = !isViewportText(layer);
            }
            return L;
        }

        private function isViewportText(layer:StyleLayer):Boolean
        {
            return String(layer.value("text-rotation-alignment", m_zoom)) == "viewport";
        }

        // ------------------------------------------------------------------
        // placement
        // ------------------------------------------------------------------

        private function placeCandidate(c:SymbolCandidate, tile:Object):void
        {
            var L:Object = layoutOf(c);
            if (L.pendingGlyphs)
            {
                incomplete = true;
                return;
            }
            if (L.shaping == null && L.icon == null)
            {
                return;
            }
            var tx:Number = tile.x;
            var ty:Number = tile.y;
            var size:Number = tile.size;
            var i:int;
            if (!c.alongLine)
            {
                var points:Vector.<Number> = c.points;
                for (i = 0; i < points.length; i += 2)
                {
                    placePoint(c, L, tx + points[i], ty + points[i + 1], 0);
                }
                return;
            }
            var labelLength:Number = 0;
            if (L.shaping != null && L.textFollowsLine)
            {
                labelLength = (L.shaping as Shaping).width * Number(L.textSize) / Glyph.BASE_SIZE;
            }
            else if (L.icon != null)
            {
                labelLength = L.iconWidth;
            }
            var spacing:Number = Math.max(Number(L.spacing), labelLength * 1.25);
            var lines:Array = c.lines;
            if (L.shaping != null && L.textFollowsLine)
            {
                // text follows the line without its small wiggles: on a jagged line (a ridge, a stream) the
                // letters would be turned one by one and, moved to the side by text-offset, bunch and spread
                if (L.lines == null)
                {
                    L.lines = [];
                    for each (var raw:Vector.<Number> in lines)
                    {
                        L.lines.push(simplify(raw, Number(L.textSize) * 0.35));
                    }
                    L.sideLines = {};
                }
                lines = L.lines;
            }
            for (var lineIndex:int = 0; lineIndex < lines.length; lineIndex++)
            {
                var line:Vector.<Number> = lines[lineIndex];
                var n:int = line.length;
                var total:Number = 0;
                for (i = 2; i < n; i += 2)
                {
                    var sx:Number = line[i] - line[i - 2];
                    var sy:Number = line[i + 1] - line[i - 1];
                    total += Math.sqrt(sx * sx + sy * sy);
                }
                if (total < labelLength || total <= 0)
                {
                    continue;
                }
                var first:Number = (labelLength / 2 + spacing / 2) % spacing;
                var placedAny:Boolean = false;
                var d:Number;
                for (d = first; d <= total - labelLength / 2; d += spacing)
                {
                    if (d >= labelLength / 2 && placeOnLine(c, L, line, d, tx, ty, size, lineIndex, total))
                    {
                        placedAny = true;
                    }
                }
                if (!placedAny && first > total - labelLength / 2)
                {
                    placeOnLine(c, L, line, total / 2, tx, ty, size, lineIndex, total);
                }
            }
        }

        /** Point at distance d along the polyline: fills m_point and returns the segment angle. */
        private function pointAt(line:Vector.<Number>, d:Number):Number
        {
            var n:int = line.length;
            var x0:Number = line[0];
            var y0:Number = line[1];
            var dx:Number = 0;
            var dy:Number = 0;
            for (var i:int = 2; i < n; i += 2)
            {
                dx = line[i] - x0;
                dy = line[i + 1] - y0;
                var length:Number = Math.sqrt(dx * dx + dy * dy);
                if (d <= length && length > 0)
                {
                    m_point.x = x0 + dx * d / length;
                    m_point.y = y0 + dy * d / length;
                    return Math.atan2(dy, dx);
                }
                d -= length;
                x0 = line[i];
                y0 = line[i + 1];
            }
            m_point.x = x0;
            m_point.y = y0;
            return Math.atan2(dy, dx);
        }

        private static function lengthOf(line:Vector.<Number>):Number
        {
            var total:Number = 0;
            for (var i:int = 2; i < line.length; i += 2)
            {
                var dx:Number = line[i] - line[i - 2];
                var dy:Number = line[i + 1] - line[i - 1];
                total += Math.sqrt(dx * dx + dy * dy);
            }
            return total;
        }

        /** Douglas-Peucker: the line without the vertices closer than tolerance to the simplified line. */
        private static function simplify(line:Vector.<Number>, tolerance:Number):Vector.<Number>
        {
            var count:int = line.length >> 1;
            if (count < 3)
            {
                return line;
            }
            var keep:Vector.<Boolean> = new Vector.<Boolean>(count, true);
            keep[0] = true;
            keep[count - 1] = true;
            var stack:Vector.<int> = new Vector.<int>();
            stack.push(0, count - 1);
            var limit:Number = tolerance * tolerance;
            var kept:int = 2;
            while (stack.length > 0)
            {
                var last:int = stack.pop();
                var first:int = stack.pop();
                var x0:Number = line[first << 1];
                var y0:Number = line[(first << 1) + 1];
                var dx:Number = line[last << 1] - x0;
                var dy:Number = line[(last << 1) + 1] - y0;
                var length2:Number = dx * dx + dy * dy;
                var worst:Number = limit;
                var index:int = -1;
                for (var i:int = first + 1; i < last; i++)
                {
                    var px:Number = line[i << 1] - x0;
                    var py:Number = line[(i << 1) + 1] - y0;
                    var distance2:Number;
                    if (length2 > 0)
                    {
                        var t:Number = (px * dx + py * dy) / length2;
                        t = t < 0 ? 0 : (t > 1 ? 1 : t);
                        px -= dx * t;
                        py -= dy * t;
                    }
                    distance2 = px * px + py * py;
                    if (distance2 > worst)
                    {
                        worst = distance2;
                        index = i;
                    }
                }
                if (index >= 0)
                {
                    keep[index] = true;
                    kept++;
                    stack.push(first, index, index, last);
                }
            }
            if (kept == count)
            {
                return line;
            }
            var result:Vector.<Number> = new Vector.<Number>(kept << 1, true);
            var n:int = 0;
            for (var k:int = 0; k < count; k++)
            {
                if (keep[k])
                {
                    result[n++] = line[k << 1];
                    result[n++] = line[(k << 1) + 1];
                }
            }
            return result;
        }

        /**
         * @param lineIndex position of the line in L.lines
         * @param total length of the line
         */
        private function placeOnLine(c:SymbolCandidate, L:Object, line:Vector.<Number>, d:Number,
                                     tx:Number, ty:Number, size:Number, lineIndex:int, total:Number):Boolean
        {
            var angle:Number = pointAt(line, d);
            var ax:Number = m_point.x;
            var ay:Number = m_point.y;
            // the anchor must belong to this tile, otherwise the neighbour tile places it
            if (ax < 0 || ay < 0 || ax >= size || ay >= size)
            {
                return false;
            }
            if (L.shaping == null || !L.textFollowsLine)
            {
                return placePoint(c, L, tx + ax, ty + ay, angle);
            }
            var x:Number = tx + ax;
            var y:Number = ty + ay;
            if (x < -50 || y < -50 || x > m_width + 50 || y > m_height + 50)
            {
                return false;
            }
            var key:String = c.layer.index + "|" + L.text;
            if (isRepeated(key, x, y, Math.max(150, Number(L.spacing) * 0.6)))
            {
                return false;
            }
            var shaping:Shaping = L.shaping as Shaping;
            var scale:Number = Number(L.textSize) / Glyph.BASE_SIZE;
            var flip:Boolean = Boolean(L.keepUpright) && (angle > Math.PI / 2 || angle < -Math.PI / 2);
            var lineOffset:Number = L.lineOffset;
            if (lineOffset != 0)
            {
                // text beside the line: the glyphs are laid on a parallel line, at their own distances along
                // it. Moving every glyph sideways from the line itself opens gaps on the outside of the bends
                // and piles the letters up on the inside. Text turned upright reads the other way, so its
                // "below" is the other side of the line.
                var side:Number = flip ? -lineOffset : lineOffset;
                var sideKey:String = lineIndex + (flip ? "-" : "+");
                var parallel:Vector.<Number> = L.sideLines[sideKey] as Vector.<Number>;
                if (parallel == null)
                {
                    parallel = L.sideLines[sideKey] = TileRenderer.offsetLine(line, side);
                }
                var parallelLength:Number = lengthOf(parallel);
                if (!(total > 0) || !(parallelLength > 0))
                {
                    return false;
                }
                d = d * parallelLength / total;
                line = parallel;
            }
            var count:int = shaping.glyphs.length;
            var xs:Vector.<Number> = new Vector.<Number>(count, true);
            var ys:Vector.<Number> = new Vector.<Number>(count, true);
            var angles:Vector.<Number> = new Vector.<Number>(count, true);
            var maxAngle:Number = L.maxAngle;
            var previous:Number = NaN;
            var half:Number = Number(L.textSize) * 0.55 + Number(L.textPadding);
            var i:int;
            for (i = 0; i < count; i++)
            {
                var glyph:Glyph = shaping.glyphs[i];
                // the glyph lies on the chord between the points where it starts and ends on the line
                var before:Number = shaping.xs[i] * scale;
                var after:Number = (shaping.xs[i] + glyph.advance) * scale;
                var a:Number = pointAt(line, flip ? d - before : d + before);
                var startX:Number = m_point.x;
                var startY:Number = m_point.y;
                var endAngle:Number = pointAt(line, flip ? d - after : d + after);
                if (m_point.x != startX || m_point.y != startY)
                {
                    a = Math.atan2(m_point.y - startY, m_point.x - startX);
                }
                else
                {
                    a = flip ? endAngle + Math.PI : endAngle;
                }
                m_point.x = (m_point.x + startX) / 2;
                m_point.y = (m_point.y + startY) / 2;
                if (!isNaN(previous))
                {
                    var delta:Number = Math.abs(a - previous);
                    if (delta > Math.PI)
                    {
                        delta = Math.PI * 2 - delta;
                    }
                    if (delta > maxAngle)
                    {
                        return false;
                    }
                }
                previous = a;
                xs[i] = tx + m_point.x;
                ys[i] = ty + m_point.y;
                angles[i] = a;
            }
            if (!L.textAllowOverlap)
            {
                for (i = 0; i < count; i++)
                {
                    if (m_index.collides(xs[i] - half, ys[i] - half, xs[i] + half, ys[i] + half))
                    {
                        return false;
                    }
                }
            }
            if (!L.textIgnore)
            {
                for (i = 0; i < count; i++)
                {
                    m_index.insert(xs[i] - half, ys[i] - half, xs[i] + half, ys[i] + half);
                }
            }
            remember(key, x, y);
            if (L.textVisible)
            {
                m_ops.push({order: c.layer.index * 2 + 1, kind: 2, L: L, xs: xs, ys: ys, angles: angles});
            }
            return true;
        }

        private function placePoint(c:SymbolCandidate, L:Object, x:Number, y:Number, lineAngle:Number):Boolean
        {
            if (x < -100 || y < -100 || x > m_width + 100 || y > m_height + 100)
            {
                return false;
            }
            var shaping:Shaping = L.shaping as Shaping;
            var hasText:Boolean = shaping != null;
            var hasIcon:Boolean = L.icon != null;
            var key:String = null;
            if (hasText)
            {
                key = c.layer.index + "|" + L.text;
                if (isRepeated(key, x, y, c.alongLine ? Math.max(150, Number(L.spacing) * 0.6) : 60))
                {
                    return false;
                }
            }
            var scale:Number = hasText ? Number(L.textSize) / Glyph.BASE_SIZE : 1;
            var pad:Number;
            var tx1:Number, ty1:Number, tx2:Number, ty2:Number;
            var ix1:Number, iy1:Number, ix2:Number, iy2:Number;
            var placeText:Boolean = hasText;
            var placeIcon:Boolean = hasIcon;
            if (hasText)
            {
                pad = L.textPadding;
                tx1 = x + shaping.left * scale - pad;
                ty1 = y + shaping.top * scale - pad;
                tx2 = x + shaping.right * scale + pad;
                ty2 = y + shaping.bottom * scale + pad;
                if (tx2 < 0 || ty2 < 0 || tx1 > m_width || ty1 > m_height)
                {
                    placeText = false;
                }
                else if (!L.textAllowOverlap && m_index.collides(tx1, ty1, tx2, ty2))
                {
                    placeText = false;
                }
            }
            var iconAngle:Number = 0;
            if (hasIcon)
            {
                iconAngle = Number(L.iconRotate) + (L.iconFollowsLine ? lineAngle : 0);
                pad = L.iconPadding;
                var hw:Number = Number(L.iconWidth) / 2;
                var hh:Number = Number(L.iconHeight) / 2;
                if (iconAngle != 0)
                {
                    // bounding box of the rotated icon
                    var r:Number = Math.sqrt(hw * hw + hh * hh);
                    hw = r;
                    hh = r;
                }
                ix1 = x + Number(L.iconDx) - hw - pad;
                iy1 = y + Number(L.iconDy) - hh - pad;
                ix2 = x + Number(L.iconDx) + hw + pad;
                iy2 = y + Number(L.iconDy) + hh + pad;
                if (ix2 < 0 || iy2 < 0 || ix1 > m_width || iy1 > m_height)
                {
                    placeIcon = false;
                }
                else if (!L.iconAllowOverlap && m_index.collides(ix1, iy1, ix2, iy2))
                {
                    placeIcon = false;
                }
            }
            if (hasText && hasIcon)
            {
                var iconWithoutText:Boolean = L.textOptional;
                var textWithoutIcon:Boolean = L.iconOptional;
                if (!iconWithoutText && !textWithoutIcon)
                {
                    placeIcon = placeText = placeIcon && placeText;
                }
                else if (!textWithoutIcon)
                {
                    placeText = placeIcon && placeText;
                }
                else if (!iconWithoutText)
                {
                    placeIcon = placeIcon && placeText;
                }
            }
            if (!placeText && !placeIcon)
            {
                return false;
            }
            if (placeIcon)
            {
                if (!L.iconIgnore)
                {
                    m_index.insert(ix1, iy1, ix2, iy2);
                }
                if (L.iconOpacity > 0)
                {
                    m_ops.push({order: c.layer.index * 2, kind: 0, L: L, x: x + Number(L.iconDx), y: y + Number(L.iconDy), angle: iconAngle});
                }
            }
            if (placeText)
            {
                if (!L.textIgnore)
                {
                    m_index.insert(tx1, ty1, tx2, ty2);
                }
                remember(key, x, y);
                if (L.textVisible)
                {
                    m_ops.push({order: c.layer.index * 2 + 1, kind: 1, L: L, x: x, y: y});
                }
            }
            return true;
        }

        private function isRepeated(key:String, x:Number, y:Number, distance:Number):Boolean
        {
            var placed:Array = m_placedTexts[key] as Array;
            if (placed == null)
            {
                return false;
            }
            var limit:Number = distance * distance;
            for (var i:int = 0; i < placed.length; i += 2)
            {
                var dx:Number = placed[i] - x;
                var dy:Number = placed[i + 1] - y;
                if (dx * dx + dy * dy < limit)
                {
                    return true;
                }
            }
            return false;
        }

        private function remember(key:String, x:Number, y:Number):void
        {
            if (key == null)
            {
                return;
            }
            var placed:Array = m_placedTexts[key] as Array;
            if (placed == null)
            {
                placed = [];
                m_placedTexts[key] = placed;
            }
            placed.push(x, y);
        }

        // ------------------------------------------------------------------
        // drawing
        // ------------------------------------------------------------------

        private function drawOp(target:BitmapData, op:Object):void
        {
            var L:Object = op.L;
            if (op.kind == 0)
            {
                drawIcon(target, L, op.x, op.y, op.angle);
                return;
            }
            var shaping:Shaping = L.shaping as Shaping;
            var stack:FontStack = L.stack as FontStack;
            var size:Number = L.textSize;
            var scale:Number = size / Glyph.BASE_SIZE;
            var count:int = shaping.glyphs.length;
            var rasters:Vector.<GlyphRaster> = new Vector.<GlyphRaster>(count, true);
            var columns:Vector.<int> = new Vector.<int>(count, true);
            var phases:int = GlyphManager.PHASES;
            var i:int;
            var glyph:Glyph;
            var hasHalo:Boolean = false;
            for (i = 0; i < count; i++)
            {
                glyph = shaping.glyphs[i];
                var phase:int = 0;
                if (op.kind == 1)
                {
                    // horizontal text: the glyph is drawn at its place inside the pixel, to the nearest quarter
                    var quarters:int = Math.round((op.x + (shaping.xs[i] + glyph.left - Glyph.BORDER) * scale) * phases);
                    columns[i] = Math.floor(quarters / phases);
                    phase = quarters - columns[i] * phases;
                    rasters[i] = m_glyphs.rasterize(stack, glyph, size, phase, L.textColor, L.haloColor, L.haloWidth, L.haloBlur);
                }
                else
                {
                    // text along a line: every glyph is drawn at its own angle and place
                    m_matrix.identity();
                    m_matrix.scale(scale, scale);
                    m_matrix.translate((glyph.left - Glyph.BORDER - glyph.advance / 2) * scale,
                        (shaping.ys[i] - glyph.top - Glyph.BORDER) * scale);
                    m_matrix.rotate(op.angles[i]);
                    m_matrix.translate(op.xs[i], op.ys[i]);
                    rasters[i] = m_glyphs.rasterizeAt(glyph, size, m_matrix, L.textColor, L.haloColor, L.haloWidth, L.haloBlur);
                }
                if (rasters[i].halo != null)
                {
                    hasHalo = true;
                }
            }
            // all the halos first, then the glyph bodies, so that halos never cover neighbouring letters
            for (var pass:int = hasHalo ? 0 : 1; pass < 2; pass++)
            {
                for (i = 0; i < count; i++)
                {
                    var bitmap:BitmapData = pass == 0 ? rasters[i].halo : rasters[i].fill;
                    if (bitmap == null)
                    {
                        continue;
                    }
                    glyph = shaping.glyphs[i];
                    if (op.kind == 1)
                    {
                        // one baseline for the whole line, on a pixel row
                        m_point.x = columns[i];
                        m_point.y = Math.round(op.y + shaping.ys[i] * scale) + rasters[i].offsetY;
                        target.copyPixels(bitmap, bitmap.rect, m_point, null, null, true);
                    }
                    else
                    {
                        m_point.x = rasters[i].offsetX;
                        m_point.y = rasters[i].offsetY;
                        target.copyPixels(bitmap, bitmap.rect, m_point, null, null, true);
                    }
                }
            }
            if (op.kind != 1)
            {
                // drawn for this label only
                for (i = 0; i < count; i++)
                {
                    if (rasters[i].fill != null) rasters[i].fill.dispose();
                    if (rasters[i].halo != null) rasters[i].halo.dispose();
                }
            }
        }

        private function drawIcon(target:BitmapData, L:Object, x:Number, y:Number, angle:Number):void
        {
            var image:BitmapData = L.icon as BitmapData;
            var scale:Number = L.iconScale;
            var opacity:Number = L.iconOpacity;
            if (angle == 0 && scale == 1 && opacity >= 1)
            {
                m_point.x = Math.round(x - image.width / 2);
                m_point.y = Math.round(y - image.height / 2);
                target.copyPixels(image, image.rect, m_point, null, null, true);
                return;
            }
            m_matrix.identity();
            m_matrix.translate(-image.width / 2, -image.height / 2);
            m_matrix.scale(scale, scale);
            if (angle != 0)
            {
                m_matrix.rotate(angle);
            }
            m_matrix.translate(x, y);
            target.draw(image, m_matrix, opacity < 1 ? new ColorTransform(1, 1, 1, opacity) : null, null, null, true);
        }
    }
}
