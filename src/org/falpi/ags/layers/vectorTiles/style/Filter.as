package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;

    /**
     * Style layer filter. Supports the legacy filter syntax
     * (["==", key, value], ["in", key, v1, v2], ["all", ...]) and expression filters.
     */
    public final class Filter
    {
        private static var s_nextId:int = 0;

        /** Unique id of the filter (key of the per-tile result cache). */
        public var id:int;
        /** True when the result may depend on the zoom (expression filters using ["zoom"]). */
        public var zoomDependent:Boolean;
        /**
         * Property that a matching feature must have with one of keyValues (as String),
         * or null when the filter has no such condition. Used only to preselect candidates:
         * the full test still decides.
         */
        public var keyProperty:String;
        /** String(value) -> true for the accepted values of keyProperty. */
        public var keyValues:Object;

        private var m_test:Function;

        public function Filter(json:*)
        {
            id = s_nextId++;
            m_test = compile(json);
            zoomDependent = json is Array && JSON.stringify(json).indexOf("\"zoom\"") >= 0;
            var key:Object = keyCondition(json);
            if (key != null)
            {
                keyProperty = key.property;
                keyValues = {};
                for each (var v:* in key.values)
                {
                    keyValues[String(v)] = true;
                }
            }
        }

        /**
         * Finds a condition "property is one of these values" that every matching feature must satisfy:
         * ==, in, match with boolean outputs, or one of those inside "all". Returns {property, values} or null.
         */
        private static function keyCondition(json:*):Object
        {
            var f:Array = json as Array;
            if (f == null || f.length < 2)
            {
                return null;
            }
            var i:int;
            var values:Array;
            switch (String(f[0]))
            {
                case "all":
                    for (i = 1; i < f.length; i++)
                    {
                        var sub:Object = keyCondition(f[i]);
                        if (sub != null)
                        {
                            return sub;
                        }
                    }
                    return null;
                case "==":
                    if (f.length != 3)
                    {
                        return null;
                    }
                    if (f[1] is String && !(f[2] is Array))
                    {
                        return plainKey(String(f[1]), [f[2]]);
                    }
                    if (getProperty(f[1]) != null && !(f[2] is Array))
                    {
                        return valuesKey(getProperty(f[1]), [f[2]]);
                    }
                    if (getProperty(f[2]) != null && !(f[1] is Array))
                    {
                        return valuesKey(getProperty(f[2]), [f[1]]);
                    }
                    return null;
                case "in":
                    if (f.length >= 3 && f[1] is String && !(f[2] is Array))
                    {
                        return plainKey(String(f[1]), f.slice(2)); // legacy ["in", key, v1, v2...]
                    }
                    if (f.length == 3 && getProperty(f[1]) != null)
                    {
                        var list:Array = f[2] as Array;
                        if (list != null && list.length == 2 && list[0] == "literal" && list[1] is Array)
                        {
                            return valuesKey(getProperty(f[1]), list[1] as Array);
                        }
                    }
                    return null;
                case "match":
                    // ["match", ["get", p], label, true|false, ..., fallback false]
                    if (getProperty(f[1]) == null || f.length < 5 || f.length % 2 != 1 || f[f.length - 1] !== false)
                    {
                        return null;
                    }
                    values = [];
                    for (i = 2; i < f.length - 1; i += 2)
                    {
                        if (!(f[i + 1] is Boolean))
                        {
                            return null;
                        }
                        if (f[i + 1] === true)
                        {
                            values = values.concat(f[i] is Array ? f[i] : [f[i]]);
                        }
                    }
                    return valuesKey(getProperty(f[1]), values);
                default:
                    return null;
            }
        }

        private static function plainKey(property:String, values:Array):Object
        {
            return property == "$type" || property == "$id" ? null : valuesKey(property, values);
        }

        private static function valuesKey(property:String, values:Array):Object
        {
            for each (var v:* in values)
            {
                if (v == null || v is Array || typeof(v) == "object")
                {
                    return null;
                }
            }
            return {property: property, values: values};
        }

        /** Property name of a ["get", name] expression, or null. */
        private static function getProperty(expression:*):String
        {
            var e:Array = expression as Array;
            return e != null && e.length == 2 && e[0] == "get" && e[1] is String ? String(e[1]) : null;
        }

        public function test(feature:MvtFeature, zoom:Number):Boolean
        {
            return m_test(feature, zoom);
        }

        private static function always(feature:MvtFeature, zoom:Number):Boolean
        {
            return true;
        }

        private static function never(feature:MvtFeature, zoom:Number):Boolean
        {
            return false;
        }

        private static function compile(json:*):Function
        {
            if (json == null)
            {
                return always;
            }
            if (json is Boolean)
            {
                return json ? always : never;
            }
            var filter:Array = json as Array;
            if (filter == null || filter.length == 0)
            {
                return always;
            }
            if (isExpressionFilter(filter))
            {
                return function(feature:MvtFeature, zoom:Number):Boolean
                {
                    try
                    {
                        return Expression.truthy(Expression.evaluate(filter, zoom, feature));
                    }
                    catch (error:Error)
                    {
                    }
                    return false;
                };
            }
            return compileLegacy(filter);
        }

        private static function isExpressionFilter(filter:Array):Boolean
        {
            switch (String(filter[0]))
            {
                case "has":
                    return filter.length >= 2 && filter[1] !== "$id" && filter[1] !== "$type" && filter[1] is Array;
                case "in":
                    return filter.length >= 3 && (!(filter[1] is String) || filter[2] is Array);
                case "!in":
                case "!has":
                case "none":
                    return false;
                case "==":
                case "!=":
                case ">":
                case ">=":
                case "<":
                case "<=":
                    return filter.length != 3 || filter[1] is Array || filter[2] is Array;
                case "any":
                case "all":
                    for (var i:int = 1; i < filter.length; i++)
                    {
                        var sub:* = filter[i];
                        if (sub is Array && isExpressionFilter(sub as Array))
                        {
                            return true;
                        }
                        if (!(sub is Array) && !(sub is Boolean))
                        {
                            return true;
                        }
                    }
                    return false;
                default:
                    return true;
            }
        }

        private static function compileLegacy(filter:Array):Function
        {
            var op:String = String(filter[0]);
            var key:String = filter.length > 1 ? String(filter[1]) : null;
            var value:* = filter.length > 2 ? filter[2] : null;
            var subs:Array;
            var i:int;
            switch (op)
            {
                case "==":
                    if (key == "$type")
                    {
                        return function(f:MvtFeature, z:Number):Boolean { return f.typeName == value; };
                    }
                    if (key == "$id")
                    {
                        return function(f:MvtFeature, z:Number):Boolean { return f.id === value; };
                    }
                    return function(f:MvtFeature, z:Number):Boolean { return f.properties[key] === value; };
                case "!=":
                    if (key == "$type")
                    {
                        return function(f:MvtFeature, z:Number):Boolean { return f.typeName != value; };
                    }
                    if (key == "$id")
                    {
                        return function(f:MvtFeature, z:Number):Boolean { return f.id !== value; };
                    }
                    return function(f:MvtFeature, z:Number):Boolean { return f.properties[key] !== value; };
                case "<":
                    return function(f:MvtFeature, z:Number):Boolean { var v:* = getValue(f, key); return v != null && typeof(v) == typeof(value) && v < value; };
                case "<=":
                    return function(f:MvtFeature, z:Number):Boolean { var v:* = getValue(f, key); return v != null && typeof(v) == typeof(value) && v <= value; };
                case ">":
                    return function(f:MvtFeature, z:Number):Boolean { var v:* = getValue(f, key); return v != null && typeof(v) == typeof(value) && v > value; };
                case ">=":
                    return function(f:MvtFeature, z:Number):Boolean { var v:* = getValue(f, key); return v != null && typeof(v) == typeof(value) && v >= value; };
                case "in":
                case "!in":
                    var values:Array = filter.slice(2);
                    var negate:Boolean = op == "!in";
                    if (values.length == 1)
                    {
                        var single:* = values[0];
                        return function(f:MvtFeature, z:Number):Boolean { return (getValue(f, key) === single) != negate; };
                    }
                    return function(f:MvtFeature, z:Number):Boolean { return (values.indexOf(getValue(f, key)) >= 0) != negate; };
                case "has":
                    return function(f:MvtFeature, z:Number):Boolean { return key == "$id" ? !isNaN(f.id) : (key == "$type" || f.properties.hasOwnProperty(key)); };
                case "!has":
                    return function(f:MvtFeature, z:Number):Boolean { return key == "$id" ? isNaN(f.id) : (key != "$type" && !f.properties.hasOwnProperty(key)); };
                case "all":
                case "any":
                case "none":
                    subs = [];
                    for (i = 1; i < filter.length; i++)
                    {
                        subs.push(compile(filter[i]));
                    }
                    if (op == "all")
                    {
                        if (subs.length == 2)
                        {
                            var a0:Function = subs[0];
                            var a1:Function = subs[1];
                            return function(f:MvtFeature, z:Number):Boolean { return a0(f, z) && a1(f, z); };
                        }
                        return function(f:MvtFeature, z:Number):Boolean
                        {
                            for each (var s:Function in subs)
                            {
                                if (!s(f, z)) return false;
                            }
                            return true;
                        };
                    }
                    var expected:Boolean = op == "any";
                    return function(f:MvtFeature, z:Number):Boolean
                    {
                        for each (var s:Function in subs)
                        {
                            if (s(f, z)) return expected;
                        }
                        return !expected;
                    };
                default:
                    return always;
            }
        }

        private static function getValue(f:MvtFeature, key:String):*
        {
            if (key == "$type")
            {
                return f.typeName;
            }
            if (key == "$id")
            {
                return isNaN(f.id) ? null : f.id;
            }
            return f.properties[key];
        }
    }
}
