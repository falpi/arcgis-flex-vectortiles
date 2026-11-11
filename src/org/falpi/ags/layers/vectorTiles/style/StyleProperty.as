package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;

    /**
     * A paint or layout property value: a constant, a legacy "function"
     * ({stops: ...}) or an expression. Evaluated for a zoom and a feature.
     */
    public final class StyleProperty
    {
        public static const NUMBER:String = "number";
        public static const COLOR:String = "color";
        public static const STRING:String = "string";
        public static const BOOLEAN:String = "boolean";
        public static const ARRAY:String = "array";

        private static const CONSTANT:int = 0;
        private static const FUNCTION:int = 1;
        private static const EXPRESSION:int = 2;

        public var name:String;
        public var type:String;
        /** True when the value can differ from feature to feature. */
        public var featureDependent:Boolean = false;

        private var m_kind:int = CONSTANT;
        private var m_raw:*;
        private var m_constant:*;
        private var m_default:*;
        private var m_lastZoom:Number = NaN;
        private var m_lastValue:*;

        public function StyleProperty(name:String, raw:*, type:String, defaultValue:*)
        {
            this.name = name;
            this.type = type;
            m_raw = raw;
            m_default = defaultValue;
            if (raw is Array && Expression.isExpression(raw))
            {
                m_kind = EXPRESSION;
                featureDependent = Expression.usesFeature(raw);
            }
            else if (raw != null && !(raw is Array) && !(raw is String) && !(raw is Number) && !(raw is Boolean) && raw.hasOwnProperty("stops"))
            {
                m_kind = FUNCTION;
                featureDependent = raw.hasOwnProperty("property");
            }
            else if (raw != null && !(raw is Array) && !(raw is String) && !(raw is Number) && !(raw is Boolean) && raw.hasOwnProperty("property"))
            {
                // identity function without stops
                m_kind = FUNCTION;
                featureDependent = true;
            }
            else
            {
                m_constant = coerce(raw);
                if (raw is String && String(raw).indexOf("{") >= 0)
                {
                    // token strings ("{name}") are resolved per feature by the renderer
                    featureDependent = true;
                }
            }
        }

        public function evaluate(zoom:Number, feature:MvtFeature = null):*
        {
            if (m_kind == CONSTANT)
            {
                return m_constant;
            }
            if (!featureDependent)
            {
                if (zoom == m_lastZoom)
                {
                    return m_lastValue;
                }
                m_lastZoom = zoom;
                m_lastValue = compute(zoom, null);
                return m_lastValue;
            }
            return compute(zoom, feature);
        }

        private function compute(zoom:Number, feature:MvtFeature):*
        {
            var value:*;
            if (m_kind == EXPRESSION)
            {
                try
                {
                    value = Expression.evaluate(m_raw, zoom, feature);
                }
                catch (error:Error)
                {
                    value = null;
                }
            }
            else
            {
                value = evaluateFunction(m_raw, zoom, feature);
            }
            if (value == null)
            {
                return m_default;
            }
            return coerce(value);
        }

        private function coerce(value:*):*
        {
            if (value == null)
            {
                return m_default;
            }
            if (type == COLOR)
            {
                var color:StyleColor = Expression.toColor(value);
                return color != null ? color : m_default;
            }
            if (type == NUMBER)
            {
                var n:Number = Number(value);
                return isNaN(n) ? m_default : n;
            }
            if (type == BOOLEAN)
            {
                return value is String ? value == "true" : Boolean(value);
            }
            return value;
        }

        // ------------------------------------------------------------------
        // legacy functions
        // ------------------------------------------------------------------

        private function evaluateFunction(fn:Object, zoom:Number, feature:MvtFeature):*
        {
            var stops:Array = fn.stops as Array;
            var interpolatable:Boolean = (type == NUMBER || type == COLOR || type == ARRAY);
            var fnType:String = fn.hasOwnProperty("type") ? String(fn.type) : (interpolatable ? "exponential" : "interval");
            var base:Number = fn.hasOwnProperty("base") ? Number(fn.base) : 1;
            if (!fn.hasOwnProperty("property"))
            {
                return evaluateStops(stops, zoom, fnType, base);
            }
            var input:* = feature == null ? undefined : feature.properties[fn.property];
            var fallback:* = fn.hasOwnProperty("default") ? fn["default"] : null;
            if (stops == null || stops.length == 0)
            {
                // identity
                return input == null ? fallback : input;
            }
            if (!(stops[0][0] is Number) && !(stops[0][0] is String) && !(stops[0][0] is Boolean))
            {
                // zoom-and-property function: stops are [{zoom, value}, output]
                return evaluateZoomAndProperty(stops, zoom, input, fnType, base, fallback);
            }
            if (input == null)
            {
                return fallback;
            }
            var result:* = evaluatePropertyStops(stops, input, fnType, base);
            return result == null ? fallback : result;
        }

        private function evaluatePropertyStops(stops:Array, input:*, fnType:String, base:Number):*
        {
            if (fnType == "identity")
            {
                return input;
            }
            if (fnType == "categorical")
            {
                for each (var stop:Array in stops)
                {
                    if (stop[0] === input)
                    {
                        return stop[1];
                    }
                }
                return null;
            }
            var x:Number = Number(input);
            if (isNaN(x))
            {
                return null;
            }
            return evaluateStops(stops, x, fnType, base);
        }

        private function evaluateStops(stops:Array, x:Number, fnType:String, base:Number):*
        {
            if (stops == null || stops.length == 0)
            {
                return null;
            }
            var n:int = stops.length;
            if (n == 1 || x <= Number(stops[0][0]))
            {
                return stops[0][1];
            }
            if (x >= Number(stops[n - 1][0]))
            {
                return stops[n - 1][1];
            }
            var i:int = 0;
            while (i + 1 < n && x >= Number(stops[i + 1][0]))
            {
                i++;
            }
            if (fnType == "interval" || fnType == "categorical" || fnType == "identity")
            {
                return stops[i][1];
            }
            var t:Number = Expression.interpolationFactor(x, base, Number(stops[i][0]), Number(stops[i + 1][0]));
            return Expression.interpolateValues(stops[i][1], stops[i + 1][1], t);
        }

        private function evaluateZoomAndProperty(stops:Array, zoom:Number, input:*, fnType:String, base:Number, fallback:*):*
        {
            // group the stops by zoom level
            var zooms:Array = [];
            var groups:Object = {};
            for each (var stop:Array in stops)
            {
                var z:Number = Number(stop[0].zoom);
                var key:String = String(z);
                if (!groups.hasOwnProperty(key))
                {
                    groups[key] = [];
                    zooms.push(z);
                }
                (groups[key] as Array).push([stop[0].value, stop[1]]);
            }
            zooms.sort(Array.NUMERIC);
            var n:int = zooms.length;
            var i:int = 0;
            while (i + 1 < n && zoom >= zooms[i + 1])
            {
                i++;
            }
            var v0:* = input == null ? null : evaluatePropertyStops(groups[String(zooms[i])], input, fnType, 1);
            if (v0 == null)
            {
                v0 = fallback;
            }
            if (i + 1 >= n || zoom <= zooms[i] || !(type == NUMBER || type == COLOR || type == ARRAY))
            {
                return v0;
            }
            var v1:* = input == null ? null : evaluatePropertyStops(groups[String(zooms[i + 1])], input, fnType, 1);
            if (v1 == null)
            {
                v1 = fallback;
            }
            if (v0 == null || v1 == null)
            {
                return v0;
            }
            var t:Number = Expression.interpolationFactor(zoom, base, zooms[i], zooms[i + 1]);
            return Expression.interpolateValues(v0, v1, t);
        }
    }
}
