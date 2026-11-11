package org.falpi.ags.layers.vectorTiles.style
{
    import org.falpi.ags.layers.vectorTiles.mvt.MvtFeature;

    /**
     * Style layer filter. Supports the legacy filter syntax
     * (["==", key, value], ["in", key, v1, v2], ["all", ...]) and expression filters.
     */
    public final class Filter
    {
        private var m_test:Function;

        public function Filter(json:*)
        {
            m_test = compile(json);
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
