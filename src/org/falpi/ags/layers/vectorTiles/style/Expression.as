package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;

    /**
     * Interpreter for a practical subset of Mapbox GL style expressions.
     * Expressions are evaluated directly on their JSON array form.
     */
    public final class Expression
    {
        private static const OPERATORS:Object = buildOperators();

        private static function buildOperators():Object
        {
            var names:Array = ["literal", "get", "has", "at", "in", "index-of", "slice", "length", "!", "==", "!=", "<", "<=", ">", ">=",
                "all", "any", "case", "match", "coalesce", "step", "interpolate", "interpolate-hcl", "interpolate-lab",
                "zoom", "geometry-type", "id", "properties", "to-string", "to-number", "to-boolean", "to-color",
                "string", "number", "boolean", "array", "object", "typeof", "concat", "upcase", "downcase",
                "+", "-", "*", "/", "%", "^", "min", "max", "round", "floor", "ceil", "abs", "sqrt",
                "ln", "log10", "log2", "sin", "cos", "tan", "asin", "acos", "atan", "pi", "e", "ln2",
                "rgb", "rgba", "let", "var", "format", "image", "number-format", "feature-state",
                "line-progress", "heatmap-density", "is-supported-script", "resolved-locale", "collator", "within",
                "accumulated", "config", "measure-light", "pitch", "distance-from-center", "sky-radial-progress", "hsl", "hsla", "random"];
            var map:Object = {};
            for each (var name:String in names)
            {
                map[name] = true;
            }
            return map;
        }

        /** True when the JSON value is an expression (an array starting with a known operator). */
        public static function isExpression(value:*):Boolean
        {
            if (!(value is Array))
            {
                return false;
            }
            var arr:Array = value as Array;
            return arr.length > 0 && arr[0] is String && OPERATORS.hasOwnProperty(arr[0]);
        }

        /** True when the expression result depends on the feature being rendered. */
        public static function usesFeature(e:*):Boolean
        {
            if (!(e is Array))
            {
                return false;
            }
            var arr:Array = e as Array;
            if (arr.length == 0)
            {
                return false;
            }
            var op:* = arr[0];
            if (op === "literal")
            {
                return false;
            }
            if (op === "get" || op === "has" || op === "properties" || op === "id" || op === "geometry-type" || op === "feature-state")
            {
                if ((op === "get" || op === "has") && arr.length > 2)
                {
                    return usesFeature(arr[1]) || usesFeature(arr[2]);
                }
                return true;
            }
            for (var i:int = 1; i < arr.length; i++)
            {
                if (usesFeature(arr[i]))
                {
                    return true;
                }
            }
            return false;
        }

        private static var s_bindings:Array = [];

        public static function evaluate(e:*, zoom:Number, feature:MvtFeature):*
        {
            if (!(e is Array))
            {
                return e;
            }
            var a:Array = e as Array;
            var n:int = a.length;
            if (n == 0)
            {
                return null;
            }
            var op:String = String(a[0]);
            var i:int;
            var v:*;
            var w:*;
            switch (op)
            {
                case "literal":
                    return a[1];
                case "get":
                    if (n > 2)
                    {
                        w = evaluate(a[2], zoom, feature);
                        v = (w == null) ? null : w[String(evaluate(a[1], zoom, feature))];
                    }
                    else
                    {
                        v = (feature == null) ? null : feature.properties[String(evaluate(a[1], zoom, feature))];
                    }
                    return v === undefined ? null : v;
                case "has":
                    if (n > 2)
                    {
                        w = evaluate(a[2], zoom, feature);
                        return w != null && w.hasOwnProperty(String(evaluate(a[1], zoom, feature)));
                    }
                    return feature != null && feature.properties.hasOwnProperty(String(evaluate(a[1], zoom, feature)));
                case "properties":
                    return feature == null ? {} : feature.properties;
                case "id":
                    return (feature == null || isNaN(feature.id)) ? null : feature.id;
                case "geometry-type":
                    return feature == null ? null : feature.typeName;
                case "zoom":
                    return zoom;
                case "at":
                    w = evaluate(a[2], zoom, feature);
                    return w is Array ? (w as Array)[int(evaluate(a[1], zoom, feature))] : null;
                case "in":
                    v = evaluate(a[1], zoom, feature);
                    w = evaluate(a[2], zoom, feature);
                    if (w is Array)
                    {
                        return (w as Array).indexOf(v) >= 0;
                    }
                    return w is String && String(w).indexOf(String(v)) >= 0;
                case "index-of":
                    v = evaluate(a[1], zoom, feature);
                    w = evaluate(a[2], zoom, feature);
                    if (w is Array)
                    {
                        return (w as Array).indexOf(v, n > 3 ? int(evaluate(a[3], zoom, feature)) : 0);
                    }
                    return w is String ? String(w).indexOf(String(v), n > 3 ? int(evaluate(a[3], zoom, feature)) : 0) : -1;
                case "slice":
                    w = evaluate(a[1], zoom, feature);
                    i = int(evaluate(a[2], zoom, feature));
                    if (w is Array)
                    {
                        return n > 3 ? (w as Array).slice(i, int(evaluate(a[3], zoom, feature))) : (w as Array).slice(i);
                    }
                    return n > 3 ? String(w).slice(i, int(evaluate(a[3], zoom, feature))) : String(w).slice(i);
                case "length":
                    w = evaluate(a[1], zoom, feature);
                    return w is Array ? (w as Array).length : (w == null ? 0 : String(w).length);
                case "!":
                    return !truthy(evaluate(a[1], zoom, feature));
                case "==":
                    return evaluate(a[1], zoom, feature) === evaluate(a[2], zoom, feature);
                case "!=":
                    return evaluate(a[1], zoom, feature) !== evaluate(a[2], zoom, feature);
                case "<":
                    return evaluate(a[1], zoom, feature) < evaluate(a[2], zoom, feature);
                case "<=":
                    return evaluate(a[1], zoom, feature) <= evaluate(a[2], zoom, feature);
                case ">":
                    return evaluate(a[1], zoom, feature) > evaluate(a[2], zoom, feature);
                case ">=":
                    return evaluate(a[1], zoom, feature) >= evaluate(a[2], zoom, feature);
                case "all":
                    for (i = 1; i < n; i++)
                    {
                        if (!truthy(evaluate(a[i], zoom, feature)))
                        {
                            return false;
                        }
                    }
                    return true;
                case "any":
                    for (i = 1; i < n; i++)
                    {
                        if (truthy(evaluate(a[i], zoom, feature)))
                        {
                            return true;
                        }
                    }
                    return false;
                case "case":
                    for (i = 1; i + 1 < n; i += 2)
                    {
                        if (truthy(evaluate(a[i], zoom, feature)))
                        {
                            return evaluate(a[i + 1], zoom, feature);
                        }
                    }
                    return evaluate(a[n - 1], zoom, feature);
                case "match":
                    v = evaluate(a[1], zoom, feature);
                    for (i = 2; i + 1 < n; i += 2)
                    {
                        w = a[i];
                        if (w is Array ? (w as Array).indexOf(v) >= 0 : w === v)
                        {
                            return evaluate(a[i + 1], zoom, feature);
                        }
                    }
                    return evaluate(a[n - 1], zoom, feature);
                case "coalesce":
                    for (i = 1; i < n; i++)
                    {
                        v = evaluate(a[i], zoom, feature);
                        if (v != null)
                        {
                            return v;
                        }
                    }
                    return null;
                case "step":
                    v = Number(evaluate(a[1], zoom, feature));
                    w = a[2];
                    for (i = 3; i + 1 < n; i += 2)
                    {
                        if (v >= Number(a[i]))
                        {
                            w = a[i + 1];
                        }
                        else
                        {
                            break;
                        }
                    }
                    return evaluate(w, zoom, feature);
                case "interpolate":
                case "interpolate-hcl":
                case "interpolate-lab":
                    return interpolateExpr(a, zoom, feature);
                case "to-string":
                case "string":
                    v = evaluate(a[1], zoom, feature);
                    if (v == null)
                    {
                        return op == "string" && n > 2 ? evaluate(a[2], zoom, feature) : "";
                    }
                    return v is StyleColor ? (v as StyleColor).toString() : String(v);
                case "to-number":
                case "number":
                    for (i = 1; i < n; i++)
                    {
                        v = evaluate(a[i], zoom, feature);
                        if (v != null && v !== "" && !isNaN(Number(v)))
                        {
                            return Number(v);
                        }
                    }
                    return 0;
                case "to-boolean":
                case "boolean":
                    return truthy(evaluate(a[1], zoom, feature));
                case "to-color":
                    for (i = 1; i < n; i++)
                    {
                        v = toColor(evaluate(a[i], zoom, feature));
                        if (v != null)
                        {
                            return v;
                        }
                    }
                    return null;
                case "array":
                case "object":
                    return evaluate(a[n - 1], zoom, feature);
                case "typeof":
                    v = evaluate(a[1], zoom, feature);
                    if (v == null) return "null";
                    if (v is String) return "string";
                    if (v is Number) return "number";
                    if (v is Boolean) return "boolean";
                    if (v is Array) return "array";
                    if (v is StyleColor) return "color";
                    return "object";
                case "concat":
                    w = "";
                    for (i = 1; i < n; i++)
                    {
                        v = evaluate(a[i], zoom, feature);
                        if (v != null)
                        {
                            w += String(v);
                        }
                    }
                    return w;
                case "upcase":
                    v = evaluate(a[1], zoom, feature);
                    return v == null ? "" : String(v).toUpperCase();
                case "downcase":
                    v = evaluate(a[1], zoom, feature);
                    return v == null ? "" : String(v).toLowerCase();
                case "+":
                    w = 0;
                    for (i = 1; i < n; i++)
                    {
                        w += Number(evaluate(a[i], zoom, feature));
                    }
                    return w;
                case "*":
                    w = 1;
                    for (i = 1; i < n; i++)
                    {
                        w *= Number(evaluate(a[i], zoom, feature));
                    }
                    return w;
                case "-":
                    if (n == 2)
                    {
                        return -Number(evaluate(a[1], zoom, feature));
                    }
                    return Number(evaluate(a[1], zoom, feature)) - Number(evaluate(a[2], zoom, feature));
                case "/":
                    return Number(evaluate(a[1], zoom, feature)) / Number(evaluate(a[2], zoom, feature));
                case "%":
                    return Number(evaluate(a[1], zoom, feature)) % Number(evaluate(a[2], zoom, feature));
                case "^":
                    return Math.pow(Number(evaluate(a[1], zoom, feature)), Number(evaluate(a[2], zoom, feature)));
                case "min":
                    w = Number.POSITIVE_INFINITY;
                    for (i = 1; i < n; i++)
                    {
                        w = Math.min(w, Number(evaluate(a[i], zoom, feature)));
                    }
                    return w;
                case "max":
                    w = Number.NEGATIVE_INFINITY;
                    for (i = 1; i < n; i++)
                    {
                        w = Math.max(w, Number(evaluate(a[i], zoom, feature)));
                    }
                    return w;
                case "round":
                    return Math.round(Number(evaluate(a[1], zoom, feature)));
                case "floor":
                    return Math.floor(Number(evaluate(a[1], zoom, feature)));
                case "ceil":
                    return Math.ceil(Number(evaluate(a[1], zoom, feature)));
                case "abs":
                    return Math.abs(Number(evaluate(a[1], zoom, feature)));
                case "sqrt":
                    return Math.sqrt(Number(evaluate(a[1], zoom, feature)));
                case "ln":
                    return Math.log(Number(evaluate(a[1], zoom, feature)));
                case "log10":
                    return Math.log(Number(evaluate(a[1], zoom, feature))) / Math.LN10;
                case "log2":
                    return Math.log(Number(evaluate(a[1], zoom, feature))) / Math.LN2;
                case "sin":
                    return Math.sin(Number(evaluate(a[1], zoom, feature)));
                case "cos":
                    return Math.cos(Number(evaluate(a[1], zoom, feature)));
                case "tan":
                    return Math.tan(Number(evaluate(a[1], zoom, feature)));
                case "asin":
                    return Math.asin(Number(evaluate(a[1], zoom, feature)));
                case "acos":
                    return Math.acos(Number(evaluate(a[1], zoom, feature)));
                case "atan":
                    return Math.atan(Number(evaluate(a[1], zoom, feature)));
                case "pi":
                    return Math.PI;
                case "e":
                    return Math.E;
                case "ln2":
                    return Math.LN2;
                case "rgb":
                case "rgba":
                    return new StyleColor(Number(evaluate(a[1], zoom, feature)), Number(evaluate(a[2], zoom, feature)),
                        Number(evaluate(a[3], zoom, feature)), n > 4 ? Number(evaluate(a[4], zoom, feature)) : 1);
                case "hsl":
                case "hsla":
                    return StyleColor.fromHsl(Number(evaluate(a[1], zoom, feature)), Number(evaluate(a[2], zoom, feature)) / 100,
                        Number(evaluate(a[3], zoom, feature)) / 100, n > 4 ? Number(evaluate(a[4], zoom, feature)) : 1);
                case "let":
                    var frame:Object = {};
                    for (i = 1; i + 1 < n; i += 2)
                    {
                        frame[String(a[i])] = evaluate(a[i + 1], zoom, feature);
                    }
                    s_bindings.push(frame);
                    try
                    {
                        v = evaluate(a[n - 1], zoom, feature);
                    }
                    finally
                    {
                        s_bindings.pop();
                    }
                    return v;
                case "var":
                    for (i = s_bindings.length - 1; i >= 0; i--)
                    {
                        if (s_bindings[i].hasOwnProperty(a[1]))
                        {
                            return s_bindings[i][a[1]];
                        }
                    }
                    return null;
                case "format":
                    w = "";
                    for (i = 1; i < n; i++)
                    {
                        if (a[i] is Array || !(a[i] is Object) || a[i] is String)
                        {
                            v = evaluate(a[i], zoom, feature);
                            if (v != null)
                            {
                                w += String(v);
                            }
                        }
                    }
                    return w;
                case "image":
                    return evaluate(a[1], zoom, feature);
                case "number-format":
                    v = Number(evaluate(a[1], zoom, feature));
                    var options:Object = n > 2 ? a[2] : null;
                    if (options != null && options.hasOwnProperty("max-fraction-digits"))
                    {
                        var digits:int = int(evaluate(options["max-fraction-digits"], zoom, feature));
                        var factor:Number = Math.pow(10, digits);
                        v = Math.round(v * factor) / factor;
                    }
                    return String(v);
                case "feature-state":
                case "config":
                case "accumulated":
                    return null;
                case "is-supported-script":
                    return true;
                default:
                    return null;
            }
        }

        private static function interpolateExpr(a:Array, zoom:Number, feature:MvtFeature):*
        {
            var n:int = a.length;
            var mode:Array = a[1] as Array;
            var base:Number = 1;
            if (mode != null && mode[0] == "exponential")
            {
                base = Number(mode[1]);
            }
            var x:Number = Number(evaluate(a[2], zoom, feature));
            if (n < 5)
            {
                return null;
            }
            if (isNaN(x) || x <= Number(a[3]))
            {
                return colorIfString(evaluate(a[4], zoom, feature));
            }
            if (x >= Number(a[n - 2]))
            {
                return colorIfString(evaluate(a[n - 1], zoom, feature));
            }
            var i:int = 3;
            while (i + 2 < n && x >= Number(a[i + 2]))
            {
                i += 2;
            }
            var x0:Number = Number(a[i]);
            var x1:Number = Number(a[i + 2]);
            var t:Number = interpolationFactor(x, base, x0, x1);
            return interpolateValues(evaluate(a[i + 1], zoom, feature), evaluate(a[i + 3], zoom, feature), t);
        }

        public static function interpolationFactor(x:Number, base:Number, x0:Number, x1:Number):Number
        {
            var range:Number = x1 - x0;
            var progress:Number = x - x0;
            if (range == 0)
            {
                return 0;
            }
            if (base == 1 || isNaN(base))
            {
                return progress / range;
            }
            return (Math.pow(base, progress) - 1) / (Math.pow(base, range) - 1);
        }

        /** Interpolates numbers, colors (also given as strings) and numeric arrays. */
        public static function interpolateValues(v0:*, v1:*, t:Number):*
        {
            if (v0 is Number && v1 is Number)
            {
                return Number(v0) + (Number(v1) - Number(v0)) * t;
            }
            if (v0 is Array && v1 is Array)
            {
                var out:Array = [];
                var a0:Array = v0 as Array;
                var a1:Array = v1 as Array;
                for (var i:int = 0; i < a0.length; i++)
                {
                    out[i] = interpolateValues(a0[i], i < a1.length ? a1[i] : a0[i], t);
                }
                return out;
            }
            var c0:StyleColor = toColor(v0);
            var c1:StyleColor = toColor(v1);
            if (c0 != null && c1 != null)
            {
                return StyleColor.interpolate(c0, c1, t);
            }
            return t < 1 ? v0 : v1;
        }

        public static function toColor(v:*):StyleColor
        {
            if (v is StyleColor)
            {
                return v as StyleColor;
            }
            if (v is String)
            {
                return StyleColor.parse(String(v));
            }
            if (v is Array && (v as Array).length >= 3 && (v as Array)[0] is Number)
            {
                var arr:Array = v as Array;
                return new StyleColor(Number(arr[0]), Number(arr[1]), Number(arr[2]), arr.length > 3 ? Number(arr[3]) : 1);
            }
            return null;
        }

        private static function colorIfString(v:*):*
        {
            if (v is String)
            {
                var c:StyleColor = StyleColor.parse(String(v));
                return c != null ? c : v;
            }
            return v;
        }

        public static function truthy(v:*):Boolean
        {
            if (v == null) return false;
            if (v is Boolean) return Boolean(v);
            if (v is Number) return Number(v) != 0 && !isNaN(Number(v));
            if (v is String) return String(v).length > 0;
            return true;
        }
    }
}
