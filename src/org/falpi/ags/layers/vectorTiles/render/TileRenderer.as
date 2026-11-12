package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.mvt.MvtLayer;
    import org.falpi.ags.layers.vectorTiles.style.Style;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;

    import flash.display.BitmapData;
    import flash.display.Graphics;
    import flash.display.LineScaleMode;
    import flash.display.Shape;
    import flash.geom.ColorTransform;
    import flash.geom.Matrix;

    /**
     * CPU renderer: draws the fill, line, circle and background layers of a
     * style for one tile into a BitmapData using the Flash drawing API, and
     * collects the symbol (label / icon) candidates of the tile.
     */
    public final class TileRenderer
    {
        private static const FLUSH_VERTICES:int = 40000;

        public var style:Style;
        public var sprites:SpriteAtlas;

        private var m_shape:Shape = new Shape();
        private var m_g:Graphics;
        private var m_target:BitmapData;
        private var m_vertices:int = 0;
        private var m_size:Number;
        private var m_zoom:Number;
        private var m_worldX:Number;
        private var m_worldY:Number;

        public function TileRenderer(style:Style, sprites:SpriteAtlas)
        {
            this.style = style;
            this.sprites = sprites;
            m_g = m_shape.graphics;
        }

        /**
         * Renders one tile.
         * @param target destination bitmap (size x size pixels)
         * @param size tile size in pixels
         * @param zoom style zoom the tile is drawn for
         * @param tiles source name -> SourceTile
         * @param worldX, worldY pixel position of the tile in the world (keeps patterns continuous)
         * @param symbols receives the symbol candidates of the tile (may be null)
         */
        public function render(target:BitmapData, size:Number, zoom:Number, tiles:Object, worldX:Number, worldY:Number,
                               symbols:Vector.<SymbolCandidate>, drawBackground:Boolean = true):void
        {
            m_target = target;
            m_size = size;
            m_zoom = zoom;
            m_worldX = worldX;
            m_worldY = worldY;
            m_vertices = 0;
            m_g.clear();
            var layers:Vector.<StyleLayer> = style.layers;
            var n:int = layers.length;
            for (var i:int = 0; i < n; i++)
            {
                var layer:StyleLayer = layers[i];
                if (!layer.visible || zoom < layer.minzoom || zoom >= layer.maxzoom)
                {
                    continue;
                }
                if (layer.type == "background")
                {
                    if (drawBackground)
                    {
                        drawBackgroundLayer(layer);
                    }
                    continue;
                }
                var source:SourceTile = tiles[layer.source] as SourceTile;
                if (source == null || source.tile == null)
                {
                    continue;
                }
                var data:MvtLayer = source.tile.layers[layer.sourceLayer] as MvtLayer;
                if (data == null || data.length == 0)
                {
                    continue;
                }
                var k:Number = size * source.scale / data.extent;
                var ox:Number = -source.offsetX * size;
                var oy:Number = -source.offsetY * size;
                var clip:Boolean = source.scale > 1;
                switch (layer.type)
                {
                    case "fill":
                    case "fill-extrusion":
                        drawFillLayer(BucketBuilder.bucket(layer, data, zoom, sprites), k, ox, oy, clip);
                        break;
                    case "line":
                        drawLineLayer(BucketBuilder.bucket(layer, data, zoom, sprites), k, ox, oy, clip);
                        break;
                    case "circle":
                        drawCircleLayer(BucketBuilder.bucket(layer, data, zoom, sprites), k, ox, oy);
                        break;
                    case "symbol":
                        if (symbols != null)
                        {
                            collectSymbols(layer, data, k, ox, oy, symbols);
                        }
                        break;
                }
                if (m_vertices > FLUSH_VERTICES)
                {
                    flush(1);
                }
            }
            flush(1);
            m_target = null;
        }

        /** Background color of the style at the given zoom (null when the style has no background layer). */
        public function backgroundColor(zoom:Number):StyleColor
        {
            for (var i:int = 0; i < style.layers.length; i++)
            {
                var layer:StyleLayer = style.layers[i];
                if (layer.type == "background" && layer.visible)
                {
                    return layer.value("background-color", zoom) as StyleColor;
                }
            }
            return null;
        }

        private function flush(alpha:Number):void
        {
            if (m_vertices > 0)
            {
                if (alpha < 1)
                {
                    m_target.draw(m_shape, null, new ColorTransform(1, 1, 1, alpha), null, null, true);
                }
                else
                {
                    m_target.draw(m_shape, null, null, null, null, true);
                }
            }
            m_g.clear();
            m_vertices = 0;
        }

        // ------------------------------------------------------------------
        // background
        // ------------------------------------------------------------------

        private function drawBackgroundLayer(layer:StyleLayer):void
        {
            var color:StyleColor = layer.value("background-color", m_zoom) as StyleColor;
            var opacity:Number = layer.value("background-opacity", m_zoom);
            var pattern:BitmapData = patternOf(layer, "background-pattern", null);
            if (pattern != null)
            {
                m_g.beginBitmapFill(pattern, patternMatrix(pattern), true, false);
            }
            else if (color != null && color.a * opacity > 0)
            {
                m_g.beginFill(color.rgb, color.a * opacity);
            }
            else
            {
                return;
            }
            m_g.drawRect(0, 0, m_size, m_size);
            m_g.endFill();
            m_vertices += 4;
        }

        // ------------------------------------------------------------------
        // fill
        // ------------------------------------------------------------------

        private function drawFillLayer(b:LayerBucket, k:Number, ox:Number, oy:Number, clip:Boolean):void
        {
            if (b.empty)
            {
                return;
            }
            ox += b.translateX;
            oy += b.translateY;
            var color:StyleColor = b.fillColor;
            var opacity:Number = b.fillOpacity;
            var outline:StyleColor = b.outlineColor;
            var pattern:BitmapData;
            var matrix:Matrix;
            if (!b.perFeature)
            {
                if (b.groupAlpha < 1)
                {
                    // draw the layer opaque on its own and blend it once: overlapping
                    // features of the same layer must not add up
                    flush(1);
                }
                pattern = b.patternName != null ? sprites.getImage(b.patternName) : null;
                if (pattern != null)
                {
                    matrix = patternMatrix(pattern);
                }
            }

            var features:Vector.<MvtFeature> = b.features;
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                if (b.perFeature)
                {
                    color = b.fillColors[i];
                    opacity = b.fillOpacities[i];
                    outline = b.outlineColors[i];
                    pattern = b.patternNames[i] != null ? sprites.getImage(b.patternNames[i]) : null;
                    matrix = pattern != null ? patternMatrix(pattern) : null;
                }
                var parts:Array = feature.loadGeometry();
                if (clip && !intersectsTile(parts, k, ox, oy, 2))
                {
                    continue;
                }
                var fillAlpha:Number = color != null ? color.a * opacity : 0;
                if (outline != null && outline.a > 0)
                {
                    m_g.lineStyle(0, outline.rgb, outline.a * opacity);
                }
                else if (b.antialias && pattern == null && fillAlpha >= 1)
                {
                    // hairline in the fill color hides the seams between adjacent polygons
                    m_g.lineStyle(0, color.rgb, 1);
                }
                else
                {
                    m_g.lineStyle();
                }
                if (pattern != null)
                {
                    m_g.beginBitmapFill(pattern, matrix, true, false);
                }
                else if (fillAlpha > 0)
                {
                    m_g.beginFill(color.rgb, fillAlpha);
                }
                else if (outline == null)
                {
                    continue;
                }
                drawParts(parts, k, ox, oy);
                m_g.endFill();
            }
            m_g.lineStyle();
            if (b.groupAlpha < 1)
            {
                flush(b.groupAlpha);
            }
        }

        private function patternOf(layer:StyleLayer, property:String, feature:MvtFeature):BitmapData
        {
            if (sprites == null || !layer.has(property))
            {
                return null;
            }
            var name:* = layer.value(property, m_zoom, feature);
            if (name == null)
            {
                return null;
            }
            return sprites.getImage(resolveTokens(String(name), feature));
        }

        private function patternMatrix(pattern:BitmapData):Matrix
        {
            var matrix:Matrix = new Matrix();
            matrix.translate(-(m_worldX % pattern.width), -(m_worldY % pattern.height));
            return matrix;
        }

        // ------------------------------------------------------------------
        // line
        // ------------------------------------------------------------------

        private function drawLineLayer(b:LayerBucket, k:Number, ox:Number, oy:Number, clip:Boolean):void
        {
            if (b.empty)
            {
                return;
            }
            ox += b.translateX;
            oy += b.translateY;
            var width:Number = b.lineWidth;
            if (!b.perFeature)
            {
                if (b.groupAlpha < 1)
                {
                    flush(1);
                }
                m_g.lineStyle(width, b.lineRgb, b.lineAlpha, false, LineScaleMode.NORMAL, b.caps, b.joints, b.miterLimit);
            }

            var dashes:Array = b.dashes;
            var pad:Number = 2;
            var features:Vector.<MvtFeature> = b.features;
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                if (b.perFeature)
                {
                    width = b.lineWidths[i];
                    m_g.lineStyle(width, b.lineRgbs[i], b.lineAlphas[i], false, LineScaleMode.NORMAL, b.caps, b.joints, b.miterLimit);
                }
                var parts:Array = feature.loadGeometry();
                if (clip && !intersectsTile(parts, k, ox, oy, width + pad))
                {
                    continue;
                }
                if (dashes != null && dashes.length >= 2 && width * (Number(dashes[0]) + Number(dashes[1])) >= 1.5)
                {
                    drawDashedParts(parts, k, ox, oy, dashes, width);
                }
                else
                {
                    drawParts(parts, k, ox, oy);
                }
            }
            m_g.lineStyle();
            if (b.groupAlpha < 1)
            {
                flush(b.groupAlpha);
            }
        }

        private function drawParts(parts:Array, k:Number, ox:Number, oy:Number):void
        {
            var g:Graphics = m_g;
            var numParts:int = parts.length;
            for (var p:int = 0; p < numParts; p++)
            {
                var part:Vector.<Number> = parts[p];
                var n:int = part.length;
                if (n < 4)
                {
                    continue;
                }
                g.moveTo(part[0] * k + ox, part[1] * k + oy);
                for (var i:int = 2; i < n; i += 2)
                {
                    g.lineTo(part[i] * k + ox, part[int(i + 1)] * k + oy);
                }
                m_vertices += n >> 1;
            }
        }

        private function drawDashedParts(parts:Array, k:Number, ox:Number, oy:Number, dashes:Array, width:Number):void
        {
            var g:Graphics = m_g;
            var numDashes:int = dashes.length;
            var pattern:Vector.<Number> = new Vector.<Number>(numDashes, true);
            var d:int;
            for (d = 0; d < numDashes; d++)
            {
                pattern[d] = Math.max(0.01, Number(dashes[d]) * width);
            }
            for (var p:int = 0; p < parts.length; p++)
            {
                var part:Vector.<Number> = parts[p];
                var n:int = part.length;
                if (n < 4)
                {
                    continue;
                }
                var index:int = 0;
                var remaining:Number = pattern[0];
                var on:Boolean = true;
                var x0:Number = part[0] * k + ox;
                var y0:Number = part[1] * k + oy;
                g.moveTo(x0, y0);
                for (var i:int = 2; i < n; i += 2)
                {
                    var x1:Number = part[i] * k + ox;
                    var y1:Number = part[int(i + 1)] * k + oy;
                    var dx:Number = x1 - x0;
                    var dy:Number = y1 - y0;
                    var length:Number = Math.sqrt(dx * dx + dy * dy);
                    // segments entirely outside the tile only advance the pattern
                    var outside:Boolean = (x0 < -64 && x1 < -64) || (y0 < -64 && y1 < -64) ||
                        (x0 > m_size + 64 && x1 > m_size + 64) || (y0 > m_size + 64 && y1 > m_size + 64);
                    if (length > 0 && outside)
                    {
                        var total:Number = length;
                        while (total >= remaining)
                        {
                            total -= remaining;
                            index = (index + 1) % numDashes;
                            remaining = pattern[index];
                            on = !on;
                        }
                        remaining -= total;
                        g.moveTo(x1, y1);
                    }
                    else if (length > 0)
                    {
                        var ux:Number = dx / length;
                        var uy:Number = dy / length;
                        var pos:Number = 0;
                        while (length - pos >= remaining)
                        {
                            pos += remaining;
                            var px:Number = x0 + ux * pos;
                            var py:Number = y0 + uy * pos;
                            if (on)
                            {
                                g.lineTo(px, py);
                            }
                            else
                            {
                                g.moveTo(px, py);
                            }
                            m_vertices++;
                            index = (index + 1) % numDashes;
                            remaining = pattern[index];
                            on = !on;
                        }
                        remaining -= length - pos;
                        if (on)
                        {
                            g.lineTo(x1, y1);
                        }
                        else
                        {
                            g.moveTo(x1, y1);
                        }
                        m_vertices++;
                    }
                    x0 = x1;
                    y0 = y1;
                }
            }
        }

        /** Cheap bounding box test used when overzooming (most of the data tile is off screen). */
        private function intersectsTile(parts:Array, k:Number, ox:Number, oy:Number, pad:Number):Boolean
        {
            var minX:Number = (-pad - ox) / k;
            var minY:Number = (-pad - oy) / k;
            var maxX:Number = (m_size + pad - ox) / k;
            var maxY:Number = (m_size + pad - oy) / k;
            for (var p:int = 0; p < parts.length; p++)
            {
                var part:Vector.<Number> = parts[p];
                var n:int = part.length;
                var left:Boolean = true;
                var right:Boolean = true;
                var above:Boolean = true;
                var below:Boolean = true;
                for (var i:int = 0; i < n; i += 2)
                {
                    var x:Number = part[i];
                    var y:Number = part[int(i + 1)];
                    if (x >= minX) left = false;
                    if (x <= maxX) right = false;
                    if (y >= minY) above = false;
                    if (y <= maxY) below = false;
                }
                if (!(left || right || above || below))
                {
                    return true;
                }
            }
            return false;
        }

        // ------------------------------------------------------------------
        // circle
        // ------------------------------------------------------------------

        private function drawCircleLayer(b:LayerBucket, k:Number, ox:Number, oy:Number):void
        {
            var features:Vector.<MvtFeature> = b.features;
            for (var i:int = 0; i < features.length; i++)
            {
                var radius:Number = b.radii[i];
                if (b.strokeWidths[i] > 0)
                {
                    m_g.lineStyle(b.strokeWidths[i], b.strokeRgbs[i], b.strokeAlphas[i]);
                }
                else
                {
                    m_g.lineStyle();
                }
                var parts:Array = features[i].loadGeometry();
                for (var p:int = 0; p < parts.length; p++)
                {
                    var x:Number = parts[p][0] * k + ox;
                    var y:Number = parts[p][1] * k + oy;
                    if (x < -radius - 2 || y < -radius - 2 || x > m_size + radius + 2 || y > m_size + radius + 2)
                    {
                        continue;
                    }
                    m_g.beginFill(b.circleRgbs[i], b.circleAlphas[i]);
                    m_g.drawCircle(x, y, radius);
                    m_g.endFill();
                    m_vertices += 8;
                }
            }
            m_g.lineStyle();
        }

        // ------------------------------------------------------------------
        // symbols
        // ------------------------------------------------------------------

        private function collectSymbols(layer:StyleLayer, data:MvtLayer, k:Number, ox:Number, oy:Number,
                                        symbols:Vector.<SymbolCandidate>):void
        {
            if (!layer.has("text-field") && !layer.has("icon-image"))
            {
                return;
            }
            var placement:String = String(layer.value("symbol-placement", m_zoom));
            var alongLine:Boolean = placement == "line" || placement == "line-center";
            var size:Number = m_size;
            var features:Vector.<MvtFeature> = BucketBuilder.filteredFeatures(layer, data, m_zoom);
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                var parts:Array = feature.loadGeometry();
                var candidate:SymbolCandidate = null;
                var p:int;
                var x:Number;
                var y:Number;
                if (alongLine && feature.type != MvtFeature.POINT)
                {
                    var lines:Array = null;
                    for (p = 0; p < parts.length; p++)
                    {
                        var part:Vector.<Number> = parts[p];
                        var n:int = part.length;
                        if (n < 4)
                        {
                            continue;
                        }
                        var line:Vector.<Number> = new Vector.<Number>(n, true);
                        var inside:Boolean = false;
                        for (var j:int = 0; j < n; j += 2)
                        {
                            x = part[j] * k + ox;
                            y = part[int(j + 1)] * k + oy;
                            line[j] = x;
                            line[int(j + 1)] = y;
                            if (x >= 0 && y >= 0 && x < size && y < size)
                            {
                                inside = true;
                            }
                        }
                        if (inside || crossesTile(line, size))
                        {
                            if (lines == null)
                            {
                                lines = [];
                            }
                            lines.push(line);
                        }
                    }
                    if (lines != null)
                    {
                        candidate = new SymbolCandidate();
                        candidate.alongLine = true;
                        candidate.lines = lines;
                    }
                }
                else
                {
                    var points:Vector.<Number> = null;
                    if (feature.type == MvtFeature.POLYGON)
                    {
                        var center:Array = polygonCenter(parts);
                        if (center != null)
                        {
                            points = addPoint(points, center[0] * k + ox, center[1] * k + oy, size);
                        }
                    }
                    else
                    {
                        for (p = 0; p < parts.length; p++)
                        {
                            if (parts[p].length >= 2)
                            {
                                points = addPoint(points, parts[p][0] * k + ox, parts[p][1] * k + oy, size);
                            }
                        }
                    }
                    if (points != null)
                    {
                        candidate = new SymbolCandidate();
                        candidate.alongLine = false;
                        candidate.points = points;
                    }
                }
                if (candidate != null)
                {
                    candidate.layer = layer;
                    candidate.feature = feature;
                    symbols.push(candidate);
                }
            }
        }

        /** Keeps only the points owned by this tile, so that neighbours do not repeat them. */
        private static function addPoint(points:Vector.<Number>, x:Number, y:Number, size:Number):Vector.<Number>
        {
            if (x < 0 || y < 0 || x >= size || y >= size)
            {
                return points;
            }
            if (points == null)
            {
                points = new Vector.<Number>();
            }
            points.push(x, y);
            return points;
        }

        private static function crossesTile(line:Vector.<Number>, size:Number):Boolean
        {
            var n:int = line.length;
            var left:Boolean = true;
            var right:Boolean = true;
            var above:Boolean = true;
            var below:Boolean = true;
            for (var i:int = 0; i < n; i += 2)
            {
                if (line[i] >= 0) left = false;
                if (line[i] <= size) right = false;
                if (line[int(i + 1)] >= 0) above = false;
                if (line[int(i + 1)] <= size) below = false;
            }
            return !(left || right || above || below);
        }

        /** Area weighted centroid of the largest ring. */
        private static function polygonCenter(parts:Array):Array
        {
            var best:Array = null;
            var bestArea:Number = -1;
            for (var p:int = 0; p < parts.length; p++)
            {
                var ring:Vector.<Number> = parts[p];
                var n:int = ring.length;
                if (n < 6)
                {
                    continue;
                }
                var area:Number = 0;
                var cx:Number = 0;
                var cy:Number = 0;
                for (var i:int = 0; i + 3 < n; i += 2)
                {
                    var cross:Number = ring[i] * ring[int(i + 3)] - ring[int(i + 2)] * ring[int(i + 1)];
                    area += cross;
                    cx += (ring[i] + ring[int(i + 2)]) * cross;
                    cy += (ring[int(i + 1)] + ring[int(i + 3)]) * cross;
                }
                var absArea:Number = Math.abs(area);
                if (absArea > bestArea && absArea > 0)
                {
                    bestArea = absArea;
                    best = [cx / (3 * area), cy / (3 * area)];
                }
            }
            return best;
        }

        /** Replaces {property} tokens with the feature attribute values. */
        public static function resolveTokens(text:String, feature:MvtFeature):String
        {
            if (text == null || text.indexOf("{") < 0)
            {
                return text;
            }
            return text.replace(/\{([^{}]+)\}/g, function(...args):String
            {
                if (feature == null)
                {
                    return "";
                }
                var value:* = feature.properties[args[1]];
                return value == null ? "" : String(value);
            });
        }
    }
}
