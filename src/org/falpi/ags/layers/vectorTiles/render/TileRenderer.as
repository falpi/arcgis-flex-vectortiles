package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.mvt.MvtLayer;
    import org.falpi.ags.layers.vectorTiles.style.Filter;
    import org.falpi.ags.layers.vectorTiles.style.Style;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;
    import org.falpi.ags.layers.vectorTiles.style.StyleProperty;

    import flash.display.BitmapData;
    import flash.display.CapsStyle;
    import flash.display.Graphics;
    import flash.display.JointStyle;
    import flash.display.LineScaleMode;
    import flash.display.Shape;
    import flash.filters.BitmapFilterQuality;
    import flash.filters.BlurFilter;
    import flash.geom.ColorTransform;
    import flash.geom.Matrix;
    import flash.geom.Point;

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
        /** Parts of the current feature that touch the tile (see selectParts). */
        private var m_partVisible:Vector.<Boolean> = new Vector.<Boolean>();

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
                        drawFillLayer(layer, data, k, ox, oy, clip);
                        break;
                    case "line":
                        drawLineLayer(layer, data, k, ox, oy, clip);
                        break;
                    case "circle":
                        drawCircleLayer(layer, data, k, ox, oy);
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

        private static const ORIGIN:Point = new Point(0, 0);

        /**
         * line-blur fades a line from its edge inward over blur + 1 pixels, so the opacity across it is
         * min(1, (half width - distance from the middle) / (blur + 1)). A line of width w blurred by a box
         * of width B has a ramp of B centered on its edge and min(1, w / B) in the middle: blurredWidth and
         * blurBox choose w and B so that the two profiles end at the same edge with the same middle.
         */
        private static function blurredWidth(width:Number, blur:Number):Number
        {
            if (!(blur > 0))
            {
                return width;
            }
            var half:Number = width / 2;
            var ramp:Number = blur + 1;
            return half >= ramp ? width - ramp : 2 * half * half / (half + ramp);
        }

        private static function blurBox(width:Number, blur:Number):Number
        {
            var half:Number = width / 2;
            var ramp:Number = blur + 1;
            return half >= ramp ? ramp : 2 * half * ramp / (half + ramp);
        }

        /**
         * line-blur: the lines drawn so far are blurred by a box of blur pixels and then
         * blended. They are drawn with a margin, so that the blur does not fade at the tile borders.
         */
        private function flushBlurred(alpha:Number, blur:Number):void
        {
            if (m_vertices > 0)
            {
                var margin:int = Math.ceil(blur) + 2;
                var side:int = Math.ceil(m_size) + margin * 2;
                var layer:BitmapData = new BitmapData(side, side, true, 0);
                layer.draw(m_shape, new Matrix(1, 0, 0, 1, margin, margin), null, null, null, true);
                layer.applyFilter(layer, layer.rect, ORIGIN, new BlurFilter(blur, blur, BitmapFilterQuality.LOW));
                m_target.draw(layer, new Matrix(1, 0, 0, 1, -margin, -margin),
                    alpha < 1 ? new ColorTransform(1, 1, 1, alpha) : null, null, null, true);
                layer.dispose();
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

        private function drawFillLayer(layer:StyleLayer, data:MvtLayer, k:Number, ox:Number, oy:Number, clip:Boolean):void
        {
            var extrusion:Boolean = layer.type == "fill-extrusion";
            var pColor:StyleProperty = layer.property(extrusion ? "fill-extrusion-color" : "fill-color");
            var pOpacity:StyleProperty = layer.property(extrusion ? "fill-extrusion-opacity" : "fill-opacity");
            var pOutline:StyleProperty = layer.property("fill-outline-color");
            var pPattern:StyleProperty = layer.property("fill-pattern");
            var hasOutline:Boolean = !extrusion && layer.has("fill-outline-color");
            var hasPattern:Boolean = !extrusion && layer.has("fill-pattern");
            var antialias:Boolean = extrusion || layer.value("fill-antialias", m_zoom);
            var perFeature:Boolean = pColor.featureDependent || pOpacity.featureDependent || pOutline.featureDependent || pPattern.featureDependent;
            var translate:Array = layer.value(extrusion ? "fill-extrusion-translate" : "fill-translate", m_zoom) as Array;
            if (translate != null)
            {
                ox += Number(translate[0]);
                oy += Number(translate[1]);
            }

            var color:StyleColor;
            var opacity:Number = 1;
            var outline:StyleColor;
            var pattern:BitmapData;
            var matrix:Matrix;
            var groupAlpha:Number = 1;
            if (!perFeature)
            {
                color = pColor.evaluate(m_zoom) as StyleColor;
                opacity = pOpacity.evaluate(m_zoom);
                outline = hasOutline ? pOutline.evaluate(m_zoom) as StyleColor : null;
                pattern = hasPattern ? patternOf(layer, "fill-pattern", null) : null;
                if (opacity <= 0 || (pattern == null && (color == null || color.a <= 0) && outline == null))
                {
                    return;
                }
                if (opacity < 1)
                {
                    // draw the layer opaque on its own and blend it once: overlapping
                    // features of the same layer must not add up
                    flush(1);
                    groupAlpha = opacity;
                    opacity = 1;
                }
                if (pattern != null)
                {
                    matrix = patternMatrix(pattern);
                }
            }

            var features:Vector.<MvtFeature> = filteredFeatures(layer, data);
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type != MvtFeature.POLYGON)
                {
                    continue;
                }
                if (perFeature)
                {
                    color = pColor.evaluate(m_zoom, feature) as StyleColor;
                    opacity = pOpacity.evaluate(m_zoom, feature);
                    outline = hasOutline ? pOutline.evaluate(m_zoom, feature) as StyleColor : null;
                    pattern = hasPattern ? patternOf(layer, "fill-pattern", feature) : null;
                    if (opacity <= 0)
                    {
                        continue;
                    }
                    matrix = pattern != null ? patternMatrix(pattern) : null;
                }
                var parts:Array = feature.loadGeometry();
                if (clip && (outsideTile(feature, k, ox, oy, 2) || !selectParts(feature, parts, k, ox, oy, 2)))
                {
                    continue;
                }
                var fillAlpha:Number = color != null ? color.a * opacity : 0;
                if (outline != null && outline.a > 0)
                {
                    m_g.lineStyle(0, outline.rgb, outline.a * opacity);
                }
                else if (antialias && pattern == null && fillAlpha >= 1)
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
                drawParts(parts, k, ox, oy, clip);
                m_g.endFill();
            }
            m_g.lineStyle();
            if (groupAlpha < 1)
            {
                flush(groupAlpha);
            }
        }

        /**
         * Features of the source layer that pass the filter of the style layer, in tile order.
         * When the filter requires a property value, only the features with that value are tested
         * (index on the source layer). The result is cached on the source layer, so overzoomed
         * tiles drawn from the same data tile do not filter it again.
         */
        private function filteredFeatures(layer:StyleLayer, data:MvtLayer):Vector.<MvtFeature>
        {
            var filter:Filter = layer.filter;
            var cacheKey:String = filter.zoomDependent ? filter.id + "@" + m_zoom : String(filter.id);
            var result:Vector.<MvtFeature> = data.filterCache[cacheKey] as Vector.<MvtFeature>;
            if (result != null)
            {
                return result;
            }
            result = new Vector.<MvtFeature>();
            var all:Vector.<MvtFeature> = data.features;
            var feature:MvtFeature;
            var i:int;
            if (filter.keyProperty != null)
            {
                var index:Object = data.indexBy(filter.keyProperty);
                var positions:Vector.<int> = new Vector.<int>();
                var buckets:int = 0;
                for (var value:String in filter.keyValues)
                {
                    var bucket:Vector.<int> = index[value] as Vector.<int>;
                    if (bucket != null)
                    {
                        positions = positions.concat(bucket);
                        buckets++;
                    }
                }
                if (buckets > 1)
                {
                    positions.sort(compareInt); // keep the drawing order of the tile
                }
                for (i = 0; i < positions.length; i++)
                {
                    feature = all[positions[i]];
                    if (filter.test(feature, m_zoom))
                    {
                        result.push(feature);
                    }
                }
            }
            else
            {
                for (i = 0; i < all.length; i++)
                {
                    feature = all[i];
                    if (filter.test(feature, m_zoom))
                    {
                        result.push(feature);
                    }
                }
            }
            data.filterCache[cacheKey] = result;
            return result;
        }

        private static function compareInt(a:int, b:int):Number
        {
            return a - b;
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

        private function drawLineLayer(layer:StyleLayer, data:MvtLayer, k:Number, ox:Number, oy:Number, clip:Boolean):void
        {
            if (layer.has("line-pattern"))
            {
                drawLinePatternLayer(layer, data, k, ox, oy, clip);
                return;
            }
            var pColor:StyleProperty = layer.property("line-color");
            var pOpacity:StyleProperty = layer.property("line-opacity");
            var pWidth:StyleProperty = layer.property("line-width");
            var pGap:StyleProperty = layer.property("line-gap-width");
            var pOffset:StyleProperty = layer.property("line-offset");
            var hasOffset:Boolean = layer.has("line-offset");
            var perFeature:Boolean = pColor.featureDependent || pOpacity.featureDependent || pWidth.featureDependent ||
                pGap.featureDependent || (hasOffset && pOffset.featureDependent);
            var cap:String = String(layer.value("line-cap", m_zoom));
            var join:String = String(layer.value("line-join", m_zoom));
            var caps:String = cap == "round" ? CapsStyle.ROUND : (cap == "square" ? CapsStyle.SQUARE : CapsStyle.NONE);
            var joints:String = join == "round" ? JointStyle.ROUND : (join == "bevel" ? JointStyle.BEVEL : JointStyle.MITER);
            var miterLimit:Number = Math.max(1, Number(layer.value("line-miter-limit", m_zoom)));
            var dashes:Array = layer.has("line-dasharray") ? layer.value("line-dasharray", m_zoom) as Array : null;
            var translate:Array = layer.value("line-translate", m_zoom) as Array;
            if (translate != null)
            {
                ox += Number(translate[0]);
                oy += Number(translate[1]);
            }

            var blur:Number = layer.has("line-blur") ? Number(layer.property("line-blur").evaluate(m_zoom)) : 0;
            if (!(blur >= 0.5))
            {
                blur = 0;
            }
            if (blur > 0)
            {
                // the layer is blurred on its own
                flush(1); // before the line style is set: flush clears it
            }

            var color:StyleColor;
            var opacity:Number = 1;
            var width:Number = 1;
            var offset:Number = 0;
            var groupAlpha:Number = 1;
            if (!perFeature)
            {
                color = pColor.evaluate(m_zoom) as StyleColor;
                opacity = pOpacity.evaluate(m_zoom);
                width = lineWidth(pWidth.evaluate(m_zoom), pGap.evaluate(m_zoom));
                offset = hasOffset ? Number(pOffset.evaluate(m_zoom)) : 0;
                if (color == null || opacity <= 0 || color.a <= 0 || width <= 0)
                {
                    return;
                }
                if (opacity < 1)
                {
                    flush(1);
                    groupAlpha = opacity;
                    opacity = 1;
                }
                m_g.lineStyle(blurredWidth(width, blur), color.rgb, color.a * opacity, false, LineScaleMode.NORMAL, caps, joints, miterLimit);
            }

            var pad:Number = 2 + blur;
            var features:Vector.<MvtFeature> = filteredFeatures(layer, data);
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type == MvtFeature.POINT)
                {
                    continue;
                }
                if (perFeature)
                {
                    color = pColor.evaluate(m_zoom, feature) as StyleColor;
                    opacity = pOpacity.evaluate(m_zoom, feature);
                    width = lineWidth(pWidth.evaluate(m_zoom, feature), pGap.evaluate(m_zoom, feature));
                    offset = hasOffset ? Number(pOffset.evaluate(m_zoom, feature)) : 0;
                    if (color == null || opacity <= 0 || color.a <= 0 || width <= 0)
                    {
                        continue;
                    }
                    m_g.lineStyle(blurredWidth(width, blur), color.rgb, color.a * opacity, false, LineScaleMode.NORMAL, caps, joints, miterLimit);
                }
                var parts:Array = feature.loadGeometry();
                if (!(offset == offset))
                {
                    offset = 0;
                }
                var reach:Number = width + pad + (offset < 0 ? -offset : offset);
                if (clip && (outsideTile(feature, k, ox, oy, reach) || !selectParts(feature, parts, k, ox, oy, reach)))
                {
                    continue;
                }
                var dk:Number = k;
                var dox:Number = ox;
                var doy:Number = oy;
                if (offset != 0)
                {
                    // line-offset: the geometry is moved in pixels, then drawn as it is
                    parts = offsetParts(parts, k, ox, oy, offset, clip);
                    dk = 1;
                    dox = 0;
                    doy = 0;
                }
                if (dashes != null && dashes.length >= 2 && width * (Number(dashes[0]) + Number(dashes[1])) >= 1.5)
                {
                    drawDashedParts(parts, dk, dox, doy, dashes, width, clip);
                }
                else
                {
                    drawParts(parts, dk, dox, doy, clip);
                }
            }
            m_g.lineStyle();
            if (blur > 0)
            {
                flushBlurred(groupAlpha, blurBox(width, blur));
            }
            else if (groupAlpha < 1)
            {
                flush(groupAlpha);
            }
        }

        /**
         * Lines drawn with an image repeated along them (line-pattern): the image is scaled so that its
         * height is the line width and laid segment by segment, rotated to follow the line. Joins are not
         * rounded. Without the image (sprite missing) nothing is drawn: a line of the full width in the
         * default color would be a blot, the pattern being usually a thin drawing on a transparent ground.
         */
        private function drawLinePatternLayer(layer:StyleLayer, data:MvtLayer, k:Number, ox:Number, oy:Number, clip:Boolean):void
        {
            if (sprites == null)
            {
                return;
            }
            var pWidth:StyleProperty = layer.property("line-width");
            var pOpacity:StyleProperty = layer.property("line-opacity");
            var translate:Array = layer.value("line-translate", m_zoom) as Array;
            if (translate != null)
            {
                ox += Number(translate[0]);
                oy += Number(translate[1]);
            }
            // bitmap fills have no alpha: the layer is drawn on its own and blended once
            var groupAlpha:Number = pOpacity.featureDependent ? 1 : Number(pOpacity.evaluate(m_zoom));
            if (!(groupAlpha > 0))
            {
                return;
            }
            if (groupAlpha < 1)
            {
                flush(1);
            }
            var g:Graphics = m_g;
            var matrix:Matrix = new Matrix();
            var limit:Number = m_size;
            g.lineStyle();
            var features:Vector.<MvtFeature> = filteredFeatures(layer, data);
            var count:int = features.length;
            for (var i:int = 0; i < count; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type == MvtFeature.POINT)
                {
                    continue;
                }
                var pattern:BitmapData = patternOf(layer, "line-pattern", feature);
                var width:Number = Number(pWidth.evaluate(m_zoom, feature));
                if (pattern == null || !(width > 0) || pattern.height == 0)
                {
                    continue;
                }
                var parts:Array = feature.loadGeometry();
                if (clip && (outsideTile(feature, k, ox, oy, width) || !selectParts(feature, parts, k, ox, oy, width)))
                {
                    continue;
                }
                var scale:Number = width / pattern.height;
                var period:Number = pattern.width * scale;
                var half:Number = width / 2;
                var pad:Number = half + 2;
                for (var p:int = 0; p < parts.length; p++)
                {
                    var part:Vector.<Number> = parts[p];
                    var n:int = part.length;
                    if (n < 4 || (clip && !m_partVisible[p]))
                    {
                        continue;
                    }
                    var distance:Number = 0;
                    var previousAngle:Number = NaN;
                    var x0:Number = part[0] * k + ox;
                    var y0:Number = part[1] * k + oy;
                    for (var j:int = 2; j < n; j += 2)
                    {
                        var x1:Number = part[j] * k + ox;
                        var y1:Number = part[int(j + 1)] * k + oy;
                        var dx:Number = x1 - x0;
                        var dy:Number = y1 - y0;
                        var length:Number = Math.sqrt(dx * dx + dy * dy);
                        if (length > 0)
                        {
                            var angle:Number = Math.atan2(dy, dx);
                            var outside:Boolean = (x0 < -pad && x1 < -pad) || (y0 < -pad && y1 < -pad) ||
                                (x0 > limit + pad && x1 > limit + pad) || (y0 > limit + pad && y1 > limit + pad);
                            if (!outside)
                            {
                                var nx:Number = -dy / length * half;
                                var ny:Number = dx / length * half;
                                // image space -> tile: the image point (distance along, middle) goes to the start
                                matrix.identity();
                                matrix.translate(-(distance % period) / scale, -pattern.height / 2);
                                matrix.scale(scale, scale);
                                matrix.rotate(angle);
                                matrix.translate(x0, y0);
                                if (previousAngle == previousAngle)
                                {
                                    // join: only the wedge left open on the outside of the turn is filled,
                                    // with the pattern as it continues on the next segment (a whole disc
                                    // would draw the pattern twice where the segments already cover)
                                    var turn:Number = angle - previousAngle;
                                    if (turn > Math.PI) turn -= Math.PI * 2;
                                    if (turn < -Math.PI) turn += Math.PI * 2;
                                    if (turn > 0.05 || turn < -0.05)
                                    {
                                        // turning clockwise on screen (y down) opens the left side
                                        var from:Number = previousAngle + (turn > 0 ? -Math.PI / 2 : Math.PI / 2);
                                        var steps:int = Math.max(1, Math.ceil(Math.abs(turn) / 0.35));
                                        g.beginBitmapFill(pattern, matrix, true, true);
                                        g.moveTo(x0, y0);
                                        for (var step:int = 0; step <= steps; step++)
                                        {
                                            var a:Number = from + turn * step / steps;
                                            g.lineTo(x0 + Math.cos(a) * half, y0 + Math.sin(a) * half);
                                        }
                                        g.lineTo(x0, y0);
                                        g.endFill();
                                        m_vertices += steps + 3;
                                    }
                                }
                                g.beginBitmapFill(pattern, matrix, true, true);
                                g.moveTo(x0 + nx, y0 + ny);
                                g.lineTo(x1 + nx, y1 + ny);
                                g.lineTo(x1 - nx, y1 - ny);
                                g.lineTo(x0 - nx, y0 - ny);
                                g.endFill();
                                m_vertices += 4;
                            }
                            distance += length;
                            previousAngle = angle;
                        }
                        x0 = x1;
                        y0 = y1;
                    }
                }
            }
            if (groupAlpha < 1)
            {
                flush(groupAlpha);
            }
        }

        private static const NO_PART:Vector.<Number> = new Vector.<Number>(0, true);

        /**
         * The parts in pixels, moved sideways by offset pixels (line-offset). With selected, the parts
         * not chosen by the last selectParts are left empty, so that the indexes still match.
         */
        private function offsetParts(parts:Array, k:Number, ox:Number, oy:Number, offset:Number, selected:Boolean):Array
        {
            var result:Array = new Array(parts.length);
            for (var p:int = 0; p < parts.length; p++)
            {
                var part:Vector.<Number> = parts[p];
                var n:int = part.length;
                if (n < 4 || (selected && !m_partVisible[p]))
                {
                    result[p] = NO_PART;
                    continue;
                }
                var pixels:Vector.<Number> = new Vector.<Number>(n, true);
                for (var i:int = 0; i < n; i += 2)
                {
                    pixels[i] = part[i] * k + ox;
                    pixels[int(i + 1)] = part[int(i + 1)] * k + oy;
                }
                result[p] = offsetLine(pixels, offset);
            }
            return result;
        }

        /**
         * The line moved sideways by distance pixels: positive to the right of its direction (y down), so
         * inside the exterior rings of polygons, which are clockwise on screen. Corners are mitered, with
         * the miter limited where the line folds back; a closed ring stays closed.
         */
        public static function offsetLine(line:Vector.<Number>, distance:Number):Vector.<Number>
        {
            var n:int = line.length;
            var result:Vector.<Number> = new Vector.<Number>(n, true);
            var previousX:Number = 0;
            var previousY:Number = 0;
            var hasPrevious:Boolean = false;
            var dx:Number;
            var dy:Number;
            var length:Number;
            var closed:Boolean = n >= 8 && line[0] == line[n - 2] && line[1] == line[n - 1];
            if (closed)
            {
                // the first corner joins the last segment
                for (var j:int = n - 2; j >= 2 && !hasPrevious; j -= 2)
                {
                    dx = line[j] - line[j - 2];
                    dy = line[j + 1] - line[j - 1];
                    length = Math.sqrt(dx * dx + dy * dy);
                    if (length > 0)
                    {
                        previousX = -dy / length;
                        previousY = dx / length;
                        hasPrevious = true;
                    }
                }
            }
            for (var i:int = 0; i < n; i += 2)
            {
                var nx:Number = 0;
                var ny:Number = 0;
                var hasNext:Boolean = false;
                if (i + 3 < n)
                {
                    dx = line[i + 2] - line[i];
                    dy = line[i + 3] - line[i + 1];
                    length = Math.sqrt(dx * dx + dy * dy);
                    if (length > 0)
                    {
                        nx = -dy / length;
                        ny = dx / length;
                        hasNext = true;
                    }
                }
                var mx:Number = hasNext ? nx : previousX;
                var my:Number = hasNext ? ny : previousY;
                if (hasNext && hasPrevious)
                {
                    mx = nx + previousX;
                    my = ny + previousY;
                    var m:Number = Math.sqrt(mx * mx + my * my);
                    if (m > 0.001)
                    {
                        mx /= m;
                        my /= m;
                        var cosine:Number = Math.max(0.5, mx * nx + my * ny);
                        mx /= cosine;
                        my /= cosine;
                    }
                    else
                    {
                        mx = nx;
                        my = ny;
                    }
                }
                result[i] = line[i] + mx * distance;
                result[i + 1] = line[i + 1] + my * distance;
                if (hasNext)
                {
                    previousX = nx;
                    previousY = ny;
                    hasPrevious = true;
                }
            }
            if (closed)
            {
                result[n - 2] = result[0];
                result[n - 1] = result[1];
            }
            return result;
        }

        private static function lineWidth(width:Number, gap:Number):Number
        {
            // line-gap-width (a line drawn as two parallel casings) is approximated by a single line
            return gap > 0 ? gap + width * 2 : width;
        }

        /** @param selected draw only the parts chosen by the last selectParts (overzoomed tiles) */
        private function drawParts(parts:Array, k:Number, ox:Number, oy:Number, selected:Boolean = false):void
        {
            var g:Graphics = m_g;
            var numParts:int = parts.length;
            var visible:Vector.<Boolean> = m_partVisible;
            for (var p:int = 0; p < numParts; p++)
            {
                var part:Vector.<Number> = parts[p];
                var n:int = part.length;
                if (n < 4 || (selected && !visible[p]))
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

        private function drawDashedParts(parts:Array, k:Number, ox:Number, oy:Number, dashes:Array, width:Number,
                                         selected:Boolean = false):void
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
                if (n < 4 || (selected && !m_partVisible[p]))
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

        /**
         * True when the bounding box of the whole feature misses the tile (pad in pixels): one comparison
         * instead of a walk through the geometry. Overzoomed tiles discard most features this way.
         */
        private function outsideTile(feature:MvtFeature, k:Number, ox:Number, oy:Number, pad:Number):Boolean
        {
            return feature.maxX * k + ox < -pad || feature.minX * k + ox > m_size + pad ||
                   feature.maxY * k + oy < -pad || feature.minY * k + oy > m_size + pad;
        }

        /**
         * Overzoomed tiles: marks in m_partVisible the parts (rings, line strings) whose bounding box touches
         * the tile and returns false when none does. Some sources merge thousands of polygons in one feature
         * (the buildings of OpenStreetMap Shortbread): drawing all of them in every tile cut from the same
         * data is most of the cost. A ring that does not touch the tile cannot change its pixels.
         */
        private function selectParts(feature:MvtFeature, parts:Array, k:Number, ox:Number, oy:Number, pad:Number):Boolean
        {
            var count:int = parts.length;
            var visible:Vector.<Boolean> = m_partVisible;
            if (visible.length < count)
            {
                visible.length = count;
            }
            if (count == 1)
            {
                // the box of the feature, already tested, is the box of its only part
                visible[0] = true;
                return true;
            }
            var minX:Number = (-pad - ox) / k;
            var minY:Number = (-pad - oy) / k;
            var maxX:Number = (m_size + pad - ox) / k;
            var maxY:Number = (m_size + pad - oy) / k;
            var bounds:Vector.<Number> = feature.partBounds;
            var any:Boolean = false;
            for (var p:int = 0; p < count; p++)
            {
                var b:int = p << 2;
                var inside:Boolean = !(bounds[int(b + 2)] < minX || bounds[b] > maxX ||
                                       bounds[int(b + 3)] < minY || bounds[int(b + 1)] > maxY);
                visible[p] = inside;
                if (inside)
                {
                    any = true;
                }
            }
            return any;
        }

        // ------------------------------------------------------------------
        // circle
        // ------------------------------------------------------------------

        private function drawCircleLayer(layer:StyleLayer, data:MvtLayer, k:Number, ox:Number, oy:Number):void
        {
            var features:Vector.<MvtFeature> = filteredFeatures(layer, data);
            for (var i:int = 0; i < features.length; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type != MvtFeature.POINT)
                {
                    continue;
                }
                var radius:Number = layer.value("circle-radius", m_zoom, feature);
                var color:StyleColor = layer.value("circle-color", m_zoom, feature) as StyleColor;
                var opacity:Number = layer.value("circle-opacity", m_zoom, feature);
                var strokeWidth:Number = layer.value("circle-stroke-width", m_zoom, feature);
                if (strokeWidth > 0)
                {
                    var stroke:StyleColor = layer.value("circle-stroke-color", m_zoom, feature) as StyleColor;
                    m_g.lineStyle(strokeWidth, stroke.rgb, stroke.a * Number(layer.value("circle-stroke-opacity", m_zoom, feature)));
                }
                else
                {
                    m_g.lineStyle();
                }
                var parts:Array = feature.loadGeometry();
                for (var p:int = 0; p < parts.length; p++)
                {
                    var x:Number = parts[p][0] * k + ox;
                    var y:Number = parts[p][1] * k + oy;
                    if (x < -radius - 2 || y < -radius - 2 || x > m_size + radius + 2 || y > m_size + radius + 2)
                    {
                        continue;
                    }
                    m_g.beginFill(color.rgb, color.a * opacity);
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
            var features:Vector.<MvtFeature> = filteredFeatures(layer, data);
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
                    if (outsideTile(feature, k, ox, oy, 0))
                    {
                        continue;
                    }
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
