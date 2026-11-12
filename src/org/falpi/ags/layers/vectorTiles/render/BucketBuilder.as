package org.falpi.ags.layers.vectorTiles.render
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;
    import org.falpi.ags.layers.vectorTiles.mvt.MvtLayer;
    import org.falpi.ags.layers.vectorTiles.style.Filter;
    import org.falpi.ags.layers.vectorTiles.style.StyleColor;
    import org.falpi.ags.layers.vectorTiles.style.StyleLayer;
    import org.falpi.ags.layers.vectorTiles.style.StyleProperty;

    import flash.display.CapsStyle;
    import flash.display.JointStyle;

    /**
     * Prepares LayerBuckets: filter, geometry type and paint evaluation of a style layer on a data tile.
     * Results are cached on the data layer (MvtLayer.filterCache), keyed by style layer and zoom.
     */
    public final class BucketBuilder
    {
        /** The bucket of a fill, fill-extrusion, line or circle layer (null for other types). */
        public static function bucket(layer:StyleLayer, data:MvtLayer, zoom:Number, sprites:SpriteAtlas):LayerBucket
        {
            var key:String = "b" + layer.filter.id + "@" + zoom;
            var result:LayerBucket = data.filterCache[key] as LayerBucket;
            if (result != null)
            {
                return result;
            }
            switch (layer.type)
            {
                case "fill":
                case "fill-extrusion":
                    result = buildFill(layer, data, zoom, sprites);
                    break;
                case "line":
                    result = buildLine(layer, data, zoom);
                    break;
                case "circle":
                    result = buildCircle(layer, data, zoom);
                    break;
                default:
                    return null;
            }
            data.filterCache[key] = result;
            return result;
        }

        // ------------------------------------------------------------------
        // fill
        // ------------------------------------------------------------------

        private static function buildFill(layer:StyleLayer, data:MvtLayer, zoom:Number, sprites:SpriteAtlas):LayerBucket
        {
            var b:LayerBucket = new LayerBucket(LayerBucket.FILL, layer, zoom);
            var extrusion:Boolean = layer.type == "fill-extrusion";
            var pColor:StyleProperty = layer.property(extrusion ? "fill-extrusion-color" : "fill-color");
            var pOpacity:StyleProperty = layer.property(extrusion ? "fill-extrusion-opacity" : "fill-opacity");
            var pOutline:StyleProperty = layer.property("fill-outline-color");
            var pPattern:StyleProperty = layer.property("fill-pattern");
            var hasOutline:Boolean = !extrusion && layer.has("fill-outline-color");
            var hasPattern:Boolean = !extrusion && layer.has("fill-pattern");
            b.antialias = extrusion || layer.value("fill-antialias", zoom);
            b.perFeature = pColor.featureDependent || pOpacity.featureDependent || pOutline.featureDependent || pPattern.featureDependent;
            setTranslate(b, layer.value(extrusion ? "fill-extrusion-translate" : "fill-translate", zoom) as Array);

            if (!b.perFeature)
            {
                b.fillColor = pColor.evaluate(zoom) as StyleColor;
                var opacity:Number = pOpacity.evaluate(zoom);
                b.outlineColor = hasOutline ? pOutline.evaluate(zoom) as StyleColor : null;
                b.patternName = hasPattern ? patternName(layer, "fill-pattern", zoom, null, sprites) : null;
                if (opacity <= 0 || (b.patternName == null && (b.fillColor == null || b.fillColor.a <= 0) && b.outlineColor == null))
                {
                    b.empty = true;
                    return b;
                }
                if (opacity < 1)
                {
                    b.groupAlpha = opacity;
                    opacity = 1;
                }
                b.fillOpacity = opacity;
            }
            else
            {
                b.fillColors = new Vector.<StyleColor>();
                b.fillOpacities = new Vector.<Number>();
                b.outlineColors = new Vector.<StyleColor>();
                b.patternNames = new Vector.<String>();
            }

            var features:Vector.<MvtFeature> = filteredFeatures(layer, data, zoom);
            for (var i:int = 0; i < features.length; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type != MvtFeature.POLYGON)
                {
                    continue;
                }
                if (b.perFeature)
                {
                    var featureOpacity:Number = pOpacity.evaluate(zoom, feature);
                    if (featureOpacity <= 0)
                    {
                        continue;
                    }
                    b.fillColors.push(pColor.evaluate(zoom, feature) as StyleColor);
                    b.fillOpacities.push(featureOpacity);
                    b.outlineColors.push(hasOutline ? pOutline.evaluate(zoom, feature) as StyleColor : null);
                    b.patternNames.push(hasPattern ? patternName(layer, "fill-pattern", zoom, feature, sprites) : null);
                }
                b.features.push(feature);
            }
            return b;
        }

        /** Sprite name of a pattern property, or null when unset or not in the sprite atlas. */
        private static function patternName(layer:StyleLayer, property:String, zoom:Number, feature:MvtFeature,
                                            sprites:SpriteAtlas):String
        {
            if (sprites == null || !layer.has(property))
            {
                return null;
            }
            var name:* = layer.value(property, zoom, feature);
            if (name == null)
            {
                return null;
            }
            var resolved:String = TileRenderer.resolveTokens(String(name), feature);
            return sprites.getImage(resolved) != null ? resolved : null;
        }

        // ------------------------------------------------------------------
        // line
        // ------------------------------------------------------------------

        private static function buildLine(layer:StyleLayer, data:MvtLayer, zoom:Number):LayerBucket
        {
            var b:LayerBucket = new LayerBucket(LayerBucket.LINE, layer, zoom);
            var pColor:StyleProperty = layer.property("line-color");
            var pOpacity:StyleProperty = layer.property("line-opacity");
            var pWidth:StyleProperty = layer.property("line-width");
            var pGap:StyleProperty = layer.property("line-gap-width");
            b.perFeature = pColor.featureDependent || pOpacity.featureDependent || pWidth.featureDependent || pGap.featureDependent;
            var cap:String = String(layer.value("line-cap", zoom));
            var join:String = String(layer.value("line-join", zoom));
            b.caps = cap == "round" ? CapsStyle.ROUND : (cap == "square" ? CapsStyle.SQUARE : CapsStyle.NONE);
            b.joints = join == "round" ? JointStyle.ROUND : (join == "bevel" ? JointStyle.BEVEL : JointStyle.MITER);
            b.miterLimit = Math.max(1, Number(layer.value("line-miter-limit", zoom)));
            b.dashes = layer.has("line-dasharray") ? layer.value("line-dasharray", zoom) as Array : null;
            setTranslate(b, layer.value("line-translate", zoom) as Array);

            var color:StyleColor;
            var opacity:Number;
            var width:Number;
            if (!b.perFeature)
            {
                color = pColor.evaluate(zoom) as StyleColor;
                opacity = pOpacity.evaluate(zoom);
                width = lineWidth(pWidth.evaluate(zoom), pGap.evaluate(zoom));
                if (color == null || opacity <= 0 || color.a <= 0 || width <= 0)
                {
                    b.empty = true;
                    return b;
                }
                if (opacity < 1)
                {
                    b.groupAlpha = opacity;
                    opacity = 1;
                }
                b.lineRgb = color.rgb;
                b.lineAlpha = color.a * opacity;
                b.lineWidth = width;
            }
            else
            {
                b.lineRgbs = new Vector.<uint>();
                b.lineAlphas = new Vector.<Number>();
                b.lineWidths = new Vector.<Number>();
            }

            var features:Vector.<MvtFeature> = filteredFeatures(layer, data, zoom);
            for (var i:int = 0; i < features.length; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type == MvtFeature.POINT)
                {
                    continue;
                }
                if (b.perFeature)
                {
                    color = pColor.evaluate(zoom, feature) as StyleColor;
                    opacity = pOpacity.evaluate(zoom, feature);
                    width = lineWidth(pWidth.evaluate(zoom, feature), pGap.evaluate(zoom, feature));
                    if (color == null || opacity <= 0 || color.a <= 0 || width <= 0)
                    {
                        continue;
                    }
                    b.lineRgbs.push(color.rgb);
                    b.lineAlphas.push(color.a * opacity);
                    b.lineWidths.push(width);
                }
                b.features.push(feature);
            }
            return b;
        }

        private static function lineWidth(width:Number, gap:Number):Number
        {
            // line-gap-width (a line drawn as two parallel casings) is approximated by a single line
            return gap > 0 ? gap + width * 2 : width;
        }

        // ------------------------------------------------------------------
        // circle
        // ------------------------------------------------------------------

        private static function buildCircle(layer:StyleLayer, data:MvtLayer, zoom:Number):LayerBucket
        {
            var b:LayerBucket = new LayerBucket(LayerBucket.CIRCLE, layer, zoom);
            b.perFeature = true;
            b.radii = new Vector.<Number>();
            b.circleRgbs = new Vector.<uint>();
            b.circleAlphas = new Vector.<Number>();
            b.strokeWidths = new Vector.<Number>();
            b.strokeRgbs = new Vector.<uint>();
            b.strokeAlphas = new Vector.<Number>();
            var features:Vector.<MvtFeature> = filteredFeatures(layer, data, zoom);
            for (var i:int = 0; i < features.length; i++)
            {
                var feature:MvtFeature = features[i];
                if (feature.type != MvtFeature.POINT)
                {
                    continue;
                }
                var color:StyleColor = layer.value("circle-color", zoom, feature) as StyleColor;
                var opacity:Number = layer.value("circle-opacity", zoom, feature);
                var strokeWidth:Number = layer.value("circle-stroke-width", zoom, feature);
                var stroke:StyleColor = strokeWidth > 0 ? layer.value("circle-stroke-color", zoom, feature) as StyleColor : null;
                b.features.push(feature);
                b.radii.push(Number(layer.value("circle-radius", zoom, feature)));
                b.circleRgbs.push(color != null ? color.rgb : 0);
                b.circleAlphas.push(color != null ? color.a * opacity : 0);
                b.strokeWidths.push(stroke != null ? strokeWidth : 0);
                b.strokeRgbs.push(stroke != null ? stroke.rgb : 0);
                b.strokeAlphas.push(stroke != null ? stroke.a * Number(layer.value("circle-stroke-opacity", zoom, feature)) : 0);
            }
            return b;
        }

        // ------------------------------------------------------------------
        // filter
        // ------------------------------------------------------------------

        private static function setTranslate(b:LayerBucket, translate:Array):void
        {
            if (translate != null)
            {
                b.translateX = Number(translate[0]);
                b.translateY = Number(translate[1]);
            }
        }

        /**
         * Features of the source layer that pass the filter of the style layer, in tile order.
         * When the filter requires a property value, only the features with that value are tested
         * (index on the source layer). The result is cached on the source layer, so overzoomed
         * tiles drawn from the same data tile do not filter it again.
         */
        public static function filteredFeatures(layer:StyleLayer, data:MvtLayer, zoom:Number):Vector.<MvtFeature>
        {
            var filter:Filter = layer.filter;
            var cacheKey:String = filter.zoomDependent ? filter.id + "@" + zoom : String(filter.id);
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
                    if (filter.test(feature, zoom))
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
                    if (filter.test(feature, zoom))
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
    }
}
